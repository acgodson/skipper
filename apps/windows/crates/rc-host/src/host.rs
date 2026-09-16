//! The host runtime: one session at a time (strict 1:1, PLAN.md §2.3), driven
//! by the shared session state machine.
//!
//! Wiring, in one place so the data flow is legible:
//!   signaling pushes  ─▶ SessionStateMachine ─▶ SessionActions ─▶ effects
//!   transport events  ─▶ SessionStateMachine (ICE) + input injection
//!   frame pump        ─▶ encoder ─▶ transport video track
//!
//! The state machine owns every decision about resume/flutter/teardown; this
//! file only performs the effects it returns and relays SDP/ICE.

use std::sync::Arc;
use std::time::Duration;

use rc_identity::{DeviceKey, IdentityRecord};
use rc_proto::consts::{ctrl as ctrl_msg, msg, role};
use rc_proto::{ctrl as ctrlp, signaling as sig};
use rc_session::{
    IceLinkState, ResumeOk, Role, SessionAction, SessionGrant, SessionStateMachine,
};
use rc_signal_client::{Config, Push, SignalConnection};
use rc_transport::{IceState, PeerConfig, PeerSession, TransportEvent};
use tokio::sync::mpsc;

use crate::inject::{InputDispatcher, Injector};
use crate::keepawake::KeepAwake;
use crate::media::{FrameSource, H264Encoder};

pub struct HostConfig {
    pub server_url: String,
    pub cert_pin: Option<String>,
    pub label: String,
    pub unattended: bool,
    pub force_relay: bool,
    pub bitrate_bps: u32,
    pub fps: f32,
}

fn ice_from_transport(s: IceState) -> IceLinkState {
    match s {
        IceState::New => IceLinkState::New,
        IceState::Checking => IceLinkState::Checking,
        IceState::Connected => IceLinkState::Connected,
        IceState::Completed => IceLinkState::Completed,
        IceState::Disconnected => IceLinkState::Disconnected,
        IceState::Failed => IceLinkState::Failed,
        IceState::Closed => IceLinkState::Closed,
    }
}

fn now_ms() -> i64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_millis() as i64)
        .unwrap_or(0)
}

/// The running host. Generic over the [`Injector`] and [`FrameSource`] so the
/// interop harness can drive the real runtime with a recording injector and a
/// synthetic screen, while Windows plugs in `SendInput` and Desktop Duplication.
pub struct Host<I: Injector + Send + 'static, F: FrameSource + 'static> {
    config: HostConfig,
    identity: IdentityRecord,
    key: DeviceKey,
    machine: SessionStateMachine,
    dispatcher: InputDispatcher,
    injector: I,
    frame_source: Option<F>,
    identity_path: Option<std::path::PathBuf>,
    _keep_awake: KeepAwake,
}

impl<I: Injector + Send, F: FrameSource + Send> Host<I, F> {
    pub fn new(
        config: HostConfig,
        identity: IdentityRecord,
        key: DeviceKey,
        injector: I,
        frame_source: F,
    ) -> Self {
        Self::with_identity_path(config, identity, key, injector, frame_source, None)
    }

    pub fn with_identity_path(
        config: HostConfig,
        identity: IdentityRecord,
        key: DeviceKey,
        injector: I,
        frame_source: F,
        identity_path: Option<std::path::PathBuf>,
    ) -> Self {
        let keep = KeepAwake::enabled(config.unattended);
        Self {
            machine: SessionStateMachine::new(Role::Host),
            dispatcher: InputDispatcher::default(),
            injector,
            frame_source: Some(frame_source),
            identity_path,
            config,
            identity,
            key,
            _keep_awake: keep,
        }
    }

    /// Connect, authenticate, and run until the process is told to stop. The
    /// backoff/reconnect loop lives here; per PROTOCOL.md §4 the state machine
    /// decides what each reconnect *means*.
    pub async fn run(mut self) -> Result<(), String> {
        let mut backoff = Duration::from_millis(500);
        loop {
            match self.run_one_connection().await {
                Ok(ConnLoopExit::Shutdown) => return Ok(()),
                Ok(ConnLoopExit::Reconnect) | Err(_) => {
                    tokio::time::sleep(backoff).await;
                    backoff = (backoff * 2).min(Duration::from_secs(15));
                }
            }
        }
    }

    async fn run_one_connection(&mut self) -> Result<ConnLoopExit, String> {
        let cfg = Config::new(&self.config.server_url, self.config.cert_pin.as_deref());
        let (conn, mut pushes) = SignalConnection::connect(&cfg).await.map_err(|e| e.to_string())?;
        let conn = Arc::new(conn);

        // First run registers; afterwards hello authenticates.
        if self.identity.device_id.is_empty() || !self.identity.server_registered {
            let verifier = rc_identity::build_verifier(&self.identity.access_code);
            let reg = conn
                .register(&self.key, &self.config.label, &verifier)
                .await
                .map_err(|e| e.to_string())?;
            self.identity.device_id = reg.device_id;
            self.identity.server_registered = true;
            if let Some(path) = &self.identity_path {
                let _ = self.identity.save(path);
            }
            eprintln!("rc-host: registered as device {}", self.identity.device_id);
        }
        let hello = conn
            .hello(&self.identity.device_id, &self.key, role::HOST)
            .await
            .map_err(|e| e.to_string())?;
        eprintln!(
            "rc-host: authenticated as {} — online and waiting for a controller",
            self.identity.device_id
        );

        let actions = self.machine.signaling_authenticated(
            (!hello.active_session_id.is_empty()).then_some(hello.active_session_id.as_str()),
        );
        self.apply(&actions, &conn, &None).await;

        let ice_servers = hello.ice_servers.clone();
        let mut peer: Option<Arc<PeerSession>> = None;
        let (te_tx, mut te_rx) = mpsc::channel::<TransportEvent>(256);
        let mut frame_pump: Option<tokio::task::JoinHandle<()>> = None;
        let mut heartbeat = tokio::time::interval(Duration::from_secs(hello.heartbeat_sec.max(1) as u64));
        let mut ticker = tokio::time::interval(Duration::from_millis(500));

        loop {
            tokio::select! {
                _ = heartbeat.tick() => {
                    let _: Result<sig::HeartbeatOk, _> =
                        conn.request(msg::HEARTBEAT, &(), msg::HEARTBEAT_OK).await;
                }
                _ = ticker.tick() => {
                    let actions = self.machine.tick(now_ms());
                    self.apply(&actions, &conn, &peer).await;
                }
                push = pushes.0.recv() => {
                    let Some(push) = push else {
                        // Socket died: tell the machine, then reconnect.
                        let actions = self.machine.signaling_lost();
                        self.apply(&actions, &conn, &peer).await;
                        return Ok(ConnLoopExit::Reconnect);
                    };
                    if let Some(exit) = self
                        .on_push(push, &conn, &mut peer, &ice_servers, &te_tx, &mut frame_pump)
                        .await
                    {
                        return Ok(exit);
                    }
                }
                event = te_rx.recv() => {
                    if let Some(event) = event {
                        self.on_transport(event, &conn, &peer).await;
                    }
                }
            }
        }
    }

    async fn on_push(
        &mut self,
        push: Push,
        conn: &Arc<SignalConnection>,
        peer: &mut Option<Arc<PeerSession>>,
        ice_servers: &[sig::IceServer],
        te_tx: &mpsc::Sender<TransportEvent>,
        frame_pump: &mut Option<tokio::task::JoinHandle<()>>,
    ) -> Option<ConnLoopExit> {
        match push {
            Push::SessionStart(grant) => {
                let actions = self.machine.session_granted(
                    &SessionGrant {
                        session_id: grant.session_id,
                        session_token: grant.session_token,
                        host_device_id: grant.host_device_id,
                        controller_device_id: grant.controller_device_id,
                    },
                    now_ms(),
                );
                // Stand up a fresh peer for this session (host answers).
                let (new_peer, mut events) = PeerSession::new(PeerConfig {
                    ice_servers: ice_servers.to_vec(),
                    force_relay: self.config.force_relay,
                })
                .await
                .ok()?;
                let new_peer = Arc::new(new_peer);
                *peer = Some(new_peer.clone());
                let fwd = te_tx.clone();
                tokio::spawn(async move {
                    while let Some(ev) = events.recv().await {
                        if fwd.send(ev).await.is_err() {
                            break;
                        }
                    }
                });
                // Start pushing frames.
                if let Some(src) = self.frame_source.take() {
                    *frame_pump = Some(self.spawn_frame_pump(new_peer.clone(), src));
                }
                self.apply(&actions, conn, peer).await;
            }
            Push::Sdp(sdp) => {
                if let Some(p) = peer {
                    if let Ok(answer) = p.handle_offer(&sdp.sdp).await {
                        let _ = conn
                            .send(
                                msg::SDP,
                                // TODO: sign the fingerprints (PROTOCOL.md §2.12)
                                // when the parked Windows host resumes; a peer
                                // that enforces §2.12 refuses this unsigned answer.
                                &sig::Sdp {
                                    session_id: sdp.session_id,
                                    sdp_type: "answer".into(),
                                    sdp: answer,
                                    restart: false,
                                    fp: String::new(),
                                    pubkey: String::new(),
                                    sig: String::new(),
                                },
                            )
                            .await;
                    }
                }
            }
            Push::Ice(ice) => {
                if let Some(p) = peer {
                    let _ = p.add_remote_candidate(&ice).await;
                }
            }
            Push::Bye(bye) => {
                let actions = self.machine.close_locally(&bye.reason);
                self.teardown(peer, frame_pump).await;
                self.apply(&actions, conn, peer).await;
            }
            Push::ServerError(e) if e.code == rc_proto::consts::err::DISPLACED => {
                // Another socket authenticated as this device. Terminal for
                // this process's connection; do not fight it in a loop.
                return Some(ConnLoopExit::Shutdown);
            }
            _ => {}
        }
        None
    }

    async fn on_transport(
        &mut self,
        event: TransportEvent,
        conn: &Arc<SignalConnection>,
        peer: &Option<Arc<PeerSession>>,
    ) {
        match event {
            TransportEvent::IceState(s) => {
                let actions = self.machine.ice_state_changed(ice_from_transport(s), now_ms());
                self.apply(&actions, conn, peer).await;
            }
            TransportEvent::LocalCandidate(init) => {
                if let Some(id) = self.machine.session_id() {
                    let ice = match init {
                        Some(c) => sig::Ice {
                            session_id: id.to_string(),
                            candidate: c.candidate,
                            sdp_mid: c.sdp_mid.unwrap_or_default(),
                            sdp_mline_index: i32::from(c.sdp_mline_index.unwrap_or(0)),
                        },
                        None => sig::Ice {
                            session_id: id.to_string(),
                            candidate: String::new(),
                            sdp_mid: String::new(),
                            sdp_mline_index: 0,
                        },
                    };
                    let _ = conn.send(msg::ICE, &ice).await;
                }
            }
            TransportEvent::ChannelsReady => {
                // Announce our display so the controller sizes its window and
                // labels its gesture palette in Windows terms.
                if let Some(p) = peer {
                    if let Some(src_dims) = self.dispatcher.display_geometry() {
                        let _ = p.send_ctrl(ctrl_msg::DISPLAY_INFO, &src_dims).await;
                    }
                }
            }
            TransportEvent::Ctrl(env) => self.on_ctrl(env),
            TransportEvent::Hi(env) => self.on_hi(env),
        }
    }

    fn on_ctrl(&mut self, env: rc_proto::envelope::Envelope) {
        let inj = &mut self.injector;
        let d = &mut self.dispatcher;
        match env.msg_type.as_str() {
            ctrl_msg::MOUSE_DOWN => {
                if let Ok(e) = env.payload_as::<ctrlp::MouseEvent>() { d.mouse_down(&e, inj) }
            }
            ctrl_msg::MOUSE_UP => {
                if let Ok(e) = env.payload_as::<ctrlp::MouseEvent>() { d.mouse_up(&e, inj) }
            }
            ctrl_msg::MOUSE_DRAG => {
                if let Ok(e) = env.payload_as::<ctrlp::MouseEvent>() { d.mouse_drag(&e, inj) }
            }
            ctrl_msg::CLICK => {
                if let Ok(e) = env.payload_as::<ctrlp::Click>() { d.click(&e, inj) }
            }
            ctrl_msg::KEY_DOWN => {
                if let Ok(e) = env.payload_as::<ctrlp::KeyEvent>() { d.key_down(&e, inj) }
            }
            ctrl_msg::KEY_UP => {
                if let Ok(e) = env.payload_as::<ctrlp::KeyEvent>() { d.key_up(&e, inj) }
            }
            ctrl_msg::SCROLL => {
                if let Ok(e) = env.payload_as::<ctrlp::Scroll>() { d.scroll(&e, inj) }
            }
            ctrl_msg::GESTURE => {
                if let Ok(g) = env.payload_as::<ctrlp::Gesture>() {
                    if let Some(name) = ctrlp::GestureName::from_wire(&g.name) {
                        d.gesture(name, inj)
                    }
                }
            }
            ctrl_msg::INPUT_RESET => d.input_reset(inj),
            // clipboard, quality, ping handled elsewhere / later.
            _ => {}
        }
    }

    fn on_hi(&mut self, env: rc_proto::envelope::Envelope) {
        if env.msg_type == rc_proto::consts::hi::MOUSE_MOVE {
            if let Ok(m) = env.payload_as::<ctrlp::MouseMove>() {
                self.dispatcher.mouse_move(&m, &mut self.injector);
            }
        }
    }

    fn spawn_frame_pump(&self, peer: Arc<PeerSession>, mut src: F) -> tokio::task::JoinHandle<()>
    where
        F: Send + 'static,
    {
        let (bitrate, fps) = (self.config.bitrate_bps, self.config.fps);
        tokio::task::spawn_blocking(move || {
            let rt = tokio::runtime::Handle::current();
            let mut encoder = match H264Encoder::new(bitrate, fps) {
                Ok(e) => e,
                Err(_) => return,
            };
            let frame_time = Duration::from_secs_f32(1.0 / fps.max(1.0));
            loop {
                let Some(frame) = src.next_frame() else {
                    std::thread::sleep(frame_time);
                    continue;
                };
                if let Ok(sample) = encoder.encode(&frame) {
                    if !sample.is_empty() {
                        let peer = peer.clone();
                        let _ = rt.block_on(peer.write_video_sample(sample, frame_time));
                    }
                }
                std::thread::sleep(frame_time);
            }
        })
    }

    async fn teardown(
        &mut self,
        peer: &mut Option<Arc<PeerSession>>,
        frame_pump: &mut Option<tokio::task::JoinHandle<()>>,
    ) {
        if let Some(p) = frame_pump.take() {
            p.abort();
        }
        if let Some(p) = peer.take() {
            p.close().await;
        }
    }

    /// Perform the effects the state machine asked for. SDP/ICE relay and peer
    /// lifecycle are handled at the call sites above; here we handle the rest.
    async fn apply(
        &mut self,
        actions: &[SessionAction],
        conn: &Arc<SignalConnection>,
        peer: &Option<Arc<PeerSession>>,
    ) {
        for action in actions {
            match action {
                SessionAction::SendBye { session_id, reason } => {
                    let _ = conn
                        .send(msg::BYE, &sig::Bye { session_id: session_id.clone(), reason: reason.clone() })
                        .await;
                }
                SessionAction::SendResume { session_id, session_token } => {
                    let result = conn
                        .request::<_, sig::ResumeOk>(
                            msg::RESUME,
                            &sig::Resume {
                                session_id: session_id.clone(),
                                session_token: session_token.clone(),
                            },
                            msg::RESUME_OK,
                        )
                        .await;
                    let follow_up = match result {
                        Ok(ok) => self.machine.resume_succeeded(
                            &ResumeOk { session_id: ok.session_id, session_token: ok.session_token },
                            now_ms(),
                        ),
                        Err(e) => {
                            let retry = e.retry_after_sec();
                            self.machine.resume_failed(e.code().unwrap_or("internal"), retry)
                        }
                    };
                    Box::pin(self.apply(&follow_up, conn, peer)).await;
                }
                SessionAction::SendRenew { session_id, session_token } => {
                    if let Ok(ok) = conn
                        .request::<_, sig::RenewOk>(
                            msg::RENEW,
                            &sig::Resume {
                                session_id: session_id.clone(),
                                session_token: session_token.clone(),
                            },
                            msg::RENEW_OK,
                        )
                        .await
                    {
                        self.machine.renew_succeeded(
                            &ResumeOk { session_id: ok.session_id, session_token: ok.session_token },
                            now_ms(),
                        );
                    }
                }
                SessionAction::SendInputReset => {
                    self.dispatcher.input_reset(&mut self.injector);
                    if let Some(p) = peer {
                        let _ = p.send_ctrl(ctrl_msg::INPUT_RESET, &ctrlp::DisplayInfo::default()).await;
                    }
                }
                // Peer lifecycle and prompts are handled by the host UI /
                // call sites; the host binary logs the rest.
                _ => {}
            }
        }
    }
}

enum ConnLoopExit {
    Reconnect,
    Shutdown,
}
