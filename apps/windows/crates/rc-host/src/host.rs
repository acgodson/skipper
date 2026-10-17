//! The host runtime: one session at a time (strict 1:1, PLAN.md §2.3), driven
//! by the shared session state machine.
//!
//! Wiring, in one place so the data flow is legible:
//!   signaling pushes  ─▶ SessionStateMachine ─▶ SessionActions ─▶ effects
//!   transport events  ─▶ SessionStateMachine (ICE) + input injection
//!   capture backend   ─▶ CapturePump ─▶ encoder ─▶ transport video track
//!   pump events       ─▶ input suspension + display_info
//!
//! The state machine owns every decision about resume/flutter/teardown; this
//! file only performs the effects it returns and relays SDP/ICE.
//!
//! Capture is owned here as a *backend*, not as a single source taken once: a
//! session takes a source, hands it back when it ends, and the next session
//! reuses it or opens a fresh one. When no source can be opened the host still
//! comes online — pairing works, the failure is visible — but remote input is
//! suspended, because a click aimed at a screen nobody can see is the one
//! failure that can damage the host's machine.

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

use crate::inject::{InputDispatcher, InputState, Injector};
use crate::keepawake::KeepAwake;
use crate::media::{CaptureBackend, CaptureStatus, Pacing, SoftwareEncoder, VideoEncoder};
use crate::pump::{CapturePump, EncoderFactory, PumpConfig, PumpEvent, VideoSink};

/// How long teardown waits for the blocking pump to notice the stop flag. Two
/// frame budgets plus slack: the loop checks the flag every few milliseconds and
/// the longest single blocking call in it is one `AcquireNextFrame` timeout.
const PUMP_STOP_GRACE: Duration = Duration::from_secs(2);

pub struct HostConfig {
    pub server_url: String,
    pub cert_pin: Option<String>,
    pub label: String,
    pub unattended: bool,
    pub force_relay: bool,
    pub bitrate_bps: u32,
    pub fps: f32,
    /// Longest edge the encoder is allowed. See [`Pacing`].
    pub max_dimension: u32,
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

/// Feeds encoded samples to the peer's video track from the blocking pump.
struct PeerVideoSink {
    peer: Arc<PeerSession>,
    runtime: tokio::runtime::Handle,
}

impl VideoSink for PeerVideoSink {
    fn write(&self, sample: bytes::Bytes, duration: Duration) -> Result<(), String> {
        self.runtime
            .block_on(self.peer.write_video_sample(sample, duration))
            .map_err(|e| e.to_string())
    }
}

/// The running host. Generic over the [`Injector`] and the [`CaptureBackend`] so
/// the interop harness can drive the real runtime with a recording injector and
/// a synthetic screen, while Windows plugs in `SendInput` and Desktop
/// Duplication.
pub struct Host<I: Injector + Send + 'static, B: CaptureBackend> {
    config: HostConfig,
    identity: IdentityRecord,
    key: DeviceKey,
    machine: SessionStateMachine,
    dispatcher: InputDispatcher,
    injector: I,
    backend: B,
    frame_source: Option<B::Source>,
    pump: Option<CapturePump<B::Source>>,
    pump_tx: mpsc::Sender<PumpEvent>,
    encoders: EncoderFactory,
    identity_path: Option<std::path::PathBuf>,
    published_cursor: Option<ctrlp::CursorShapeName>,
    _keep_awake: KeepAwake,
}

impl<I: Injector + Send, B: CaptureBackend> Host<I, B>
where
    B::Source: Send,
{
    pub fn new(
        config: HostConfig,
        identity: IdentityRecord,
        key: DeviceKey,
        injector: I,
        backend: B,
    ) -> (Self, mpsc::Receiver<PumpEvent>) {
        Self::with_identity_path(config, identity, key, injector, backend, None)
    }

    pub fn with_identity_path(
        config: HostConfig,
        identity: IdentityRecord,
        key: DeviceKey,
        injector: I,
        backend: B,
        identity_path: Option<std::path::PathBuf>,
    ) -> (Self, mpsc::Receiver<PumpEvent>) {
        let keep = KeepAwake::enabled(config.unattended);
        let (pump_tx, pump_rx) = mpsc::channel::<PumpEvent>(32);
        let host = Self {
            machine: SessionStateMachine::new(Role::Host),
            dispatcher: InputDispatcher::default(),
            injector,
            backend,
            frame_source: None,
            pump: None,
            pump_tx,
            encoders: Arc::new(|bitrate, fps| {
                SoftwareEncoder::new(bitrate, fps).map(|e| Box::new(e) as Box<dyn VideoEncoder>)
            }),
            identity_path,
            published_cursor: None,
            config,
            identity,
            key,
            _keep_awake: keep,
        };
        (host, pump_rx)
    }

    /// Connect, authenticate, and run until the process is told to stop. The
    /// backoff/reconnect loop lives here; per PROTOCOL.md §4 the state machine
    /// decides what each reconnect *means*.
    pub async fn run(mut self, mut pump_rx: mpsc::Receiver<PumpEvent>) -> Result<(), String> {
        let mut shutdown_rx = spawn_shutdown_watch();
        let mut backoff = Duration::from_millis(500);
        loop {
            match self.run_one_connection(&mut pump_rx, &mut shutdown_rx).await {
                Ok(ConnLoopExit::Shutdown) => {
                    // Releases every held key and button on the way out.
                    self.stop_capture().await;
                    return Ok(());
                }
                Ok(ConnLoopExit::Reconnect) | Err(_) => {
                    // The backoff is interruptible: asking the host to stop
                    // must not wait out a 15-second sleep with a modifier still
                    // held down on the machine.
                    tokio::select! {
                        _ = tokio::time::sleep(backoff) => {}
                        _ = shutdown_rx.recv() => {
                            self.stop_capture().await;
                            return Ok(());
                        }
                    }
                    backoff = (backoff * 2).min(Duration::from_secs(15));
                }
            }
        }
    }

    async fn run_one_connection(
        &mut self,
        pump_rx: &mut mpsc::Receiver<PumpEvent>,
        shutdown_rx: &mut mpsc::Receiver<()>,
    ) -> Result<ConnLoopExit, String> {
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
        let mut heartbeat = tokio::time::interval(Duration::from_secs(hello.heartbeat_sec.max(1) as u64));
        let mut ticker = tokio::time::interval(Duration::from_millis(500));

        let exit = loop {
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
                        break ConnLoopExit::Reconnect;
                    };
                    if let Some(exit) = self.on_push(push, &conn, &mut peer, &ice_servers, &te_tx).await {
                        break exit;
                    }
                }
                event = te_rx.recv() => {
                    if let Some(event) = event {
                        self.on_transport(event, &conn, &mut peer).await;
                    }
                }
                event = pump_rx.recv() => {
                    if let Some(event) = event {
                        self.on_pump_event(event, &peer).await;
                    }
                }
                _ = shutdown_rx.recv() => {
                    eprintln!("rc-host: stopping - releasing all remote input");
                    break ConnLoopExit::Shutdown;
                }
            }
        };

        // A connection that ends takes its session's capture with it. Leaving
        // the pump running would hold the capture device against the next
        // session and keep encoding for a peer that is gone.
        self.teardown(&mut peer).await;
        Ok(exit)
    }

    async fn on_push(
        &mut self,
        push: Push,
        conn: &Arc<SignalConnection>,
        peer: &mut Option<Arc<PeerSession>>,
        ice_servers: &[sig::IceServer],
        te_tx: &mpsc::Sender<TransportEvent>,
    ) -> Option<ConnLoopExit> {
        match push {
            Push::SessionStart(grant) => {
                let actions = self.machine.session_granted(
                    &SessionGrant {
                        session_id: grant.session.session_id,
                        session_token: grant.session.session_token,
                        host_device_id: grant.session.host_device_id,
                        controller_device_id: grant.session.controller_device_id,
                    },
                    now_ms(),
                );
                // A previous session's peer and pump must be gone before a new
                // one starts; this is what makes a second and third session
                // work rather than silently reuse a dead track.
                self.teardown(peer).await;

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
                self.start_capture(new_peer).await;
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
                                    mac: String::new(),
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
                self.teardown(peer).await;
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
        peer: &mut Option<Arc<PeerSession>>,
    ) {
        match event {
            TransportEvent::IceState(s) => {
                let closed = matches!(s, IceState::Closed | IceState::Failed);
                let actions = self.machine.ice_state_changed(ice_from_transport(s), now_ms());
                if closed {
                    // The track is gone. Stop capturing for it rather than
                    // encoding into a closed peer until something else notices.
                    self.stop_capture().await;
                }
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
                // labels its gesture palette in Windows terms, and tell it
                // straight away if it must not click.
                self.publish_display(peer).await;
                self.publish_cursor(peer).await;
            }
            TransportEvent::KeyframeRequested => {
                if let Some(pump) = &self.pump {
                    pump.request_keyframe();
                }
            }
            TransportEvent::Ctrl(env) => self.on_ctrl(env),
            TransportEvent::Hi(env) => self.on_hi(env),
        }
    }

    /// Capture state changes drive two things: whether remote input is applied,
    /// and what the controller is told about the screen.
    async fn on_pump_event(&mut self, event: PumpEvent, peer: &Option<Arc<PeerSession>>) {
        match event {
            PumpEvent::Status(CaptureStatus::Live) => {
                self.dispatcher.resume();
            }
            PumpEvent::Status(CaptureStatus::DesktopUnavailable) => {
                eprintln!("rc-host: the desktop is locked or protected — remote input suspended");
                self.dispatcher.suspend(InputState::DesktopUnavailable, &mut self.injector);
            }
            PumpEvent::Status(CaptureStatus::Unavailable(detail)) => {
                eprintln!("rc-host: capture unavailable ({detail}) — remote input suspended");
                self.dispatcher.suspend(InputState::NoPicture, &mut self.injector);
            }
            PumpEvent::Geometry(geometry) => {
                self.dispatcher.set_geometry(geometry, &mut self.injector);
                self.publish_display(peer).await;
            }
            PumpEvent::SteppedDown { fps, max_dimension, measured_encode } => {
                let measured = measured_encode
                    .map(|d| format!("{:.1} ms/frame", d.as_secs_f64() * 1000.0))
                    .unwrap_or_else(|| "unmeasured".into());
                eprintln!(
                    "rc-host: encode cost {measured} did not fit the budget — now {fps} fps, \
                     longest edge {max_dimension}"
                );
            }
        }
        self.publish_cursor(peer).await;
        self.log_injection_failure();
    }

    async fn publish_display(&self, peer: &Option<Arc<PeerSession>>) {
        if let (Some(p), Some(info)) = (peer, self.dispatcher.display_geometry()) {
            let _ = p.send_ctrl(ctrl_msg::DISPLAY_INFO, &info).await;
        }
    }

    /// The only in-contract way to tell the controller "do not click here".
    ///
    /// A suspended host keeps whatever frame the controller last decoded, and
    /// nothing in §5 says "the picture is stale". `cursor_shape` does say the
    /// pointer is `not_allowed`, the controller already draws it locally, and it
    /// is purely additive — so the user sees that the screen is not live at the
    /// one place they are about to click. Making the stale frame itself
    /// unmistakable needs a controller-side change.
    async fn publish_cursor(&mut self, peer: &Option<Arc<PeerSession>>) {
        let Some(p) = peer else { return };
        let shape = match self.dispatcher.state() {
            InputState::Running => ctrlp::CursorShapeName::Arrow,
            _ => ctrlp::CursorShapeName::NotAllowed,
        };
        // §5: cursor_shape is sent when the channel opens and then on change
        // only, so the last published value is remembered rather than resent.
        if self.published_cursor == Some(shape) {
            return;
        }
        if p.send_ctrl(
            ctrl_msg::CURSOR_SHAPE,
            &ctrlp::CursorShape { shape: shape.as_wire().to_string() },
        )
        .await
        .is_ok()
        {
            self.published_cursor = Some(shape);
        }
    }

    fn log_injection_failure(&mut self) {
        if let Some(err) = self.dispatcher.take_last_error() {
            eprintln!("rc-host: input not applied — {}", err.detail);
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
        self.log_injection_failure();
    }

    fn on_hi(&mut self, env: rc_proto::envelope::Envelope) {
        if env.msg_type == rc_proto::consts::hi::MOUSE_MOVE {
            if let Ok(m) = env.payload_as::<ctrlp::MouseMove>() {
                self.dispatcher.mouse_move(&m, &mut self.injector);
            }
        }
    }

    /// Start capturing for one session: reuse the source the last session gave
    /// back, or open a new one. A failure here is reported as *unavailable* and
    /// suspends input; it never substitutes a picture that is not the screen.
    async fn start_capture(&mut self, peer: Arc<PeerSession>) {
        let source = match self.frame_source.take() {
            Some(source) => Some(source),
            None => match self.backend.open() {
                Ok(source) => {
                    eprintln!("rc-host: capture started ({})", self.backend.describe());
                    Some(source)
                }
                Err(e) => {
                    eprintln!("rc-host: capture unavailable ({e}) — remote input suspended");
                    None
                }
            },
        };
        let Some(source) = source else {
            self.dispatcher.suspend(InputState::NoPicture, &mut self.injector);
            self.publish_cursor(&Some(peer)).await;
            return;
        };

        let sink = Arc::new(PeerVideoSink { peer, runtime: tokio::runtime::Handle::current() });
        self.pump = Some(CapturePump::start(
            source,
            sink,
            self.pump_tx.clone(),
            PumpConfig {
                bitrate_bps: self.config.bitrate_bps,
                pacing: Pacing::new(self.config.fps, self.config.max_dimension),
            },
            self.encoders.clone(),
        ));
    }

    /// Stop the pump and take the source back, so the next session has one.
    async fn stop_capture(&mut self) {
        self.published_cursor = None;
        if let Some(pump) = self.pump.take() {
            self.frame_source = pump.stop(PUMP_STOP_GRACE).await;
            if self.frame_source.is_none() {
                eprintln!("rc-host: capture did not stop in time; a fresh source will be opened");
            }
        }
        self.dispatcher.suspend(InputState::NoPicture, &mut self.injector);
        self.log_injection_failure();
    }

    async fn teardown(&mut self, peer: &mut Option<Arc<PeerSession>>) {
        self.stop_capture().await;
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
                        .send(msg::BYE, &sig::Bye { session_id: session_id.clone(), reason: reason.clone(), relay_used: None, bytes_relayed: None })
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
                    self.log_injection_failure();
                    if let Some(p) = peer {
                        let _ = p.send_ctrl(ctrl_msg::INPUT_RESET, &serde_json::json!({})).await;
                    }
                }
                // Peer lifecycle and prompts are handled by the host UI /
                // call sites; the host binary logs the rest.
                _ => {}
            }
        }
    }
}

/// Watches for the ways a user ends this host, so the keys the controller is
/// holding are released before the process goes.
///
/// A host that exits with a modifier still down leaves it down: `SendInput`
/// injects into the system input queue and process exit sends no key-up, so the
/// machine is left with a stuck Ctrl until something presses it again. The
/// console window's close button matters as much as Ctrl-C here, because the
/// launch banner tells the user that closing the window is how to stop.
fn spawn_shutdown_watch() -> mpsc::Receiver<()> {
    let (tx, rx) = mpsc::channel::<()>(1);
    tokio::spawn(async move {
        wait_for_shutdown().await;
        let _ = tx.send(()).await;
    });
    rx
}

#[cfg(windows)]
async fn wait_for_shutdown() {
    let Ok(mut close) = tokio::signal::windows::ctrl_close() else {
        let _ = tokio::signal::ctrl_c().await;
        return;
    };
    tokio::select! {
        _ = tokio::signal::ctrl_c() => {}
        _ = close.recv() => {}
    }
}

/// The non-Windows build is the diagnostic one: its injector records input
/// rather than applying it, so nothing can be left held and there is no reason
/// to pull a unix signal backend into the Mac product's dependency graph for it.
#[cfg(not(windows))]
async fn wait_for_shutdown() {
    std::future::pending().await
}

enum ConnLoopExit {
    Reconnect,
    Shutdown,
}
