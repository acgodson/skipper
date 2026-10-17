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

use rc_identity::pake::PakeMessage;
use rc_identity::{DeviceKey, IdentityRecord};
use rc_proto::consts::{bye, ctrl as ctrl_msg, err, msg, role};
use rc_proto::{ctrl as ctrlp, signaling as sig};
use rc_session::{
    ConsentOutcome, IceLinkState, ResumeOk, Role, SessionAction, SessionGrant, SessionStateMachine,
};
use rc_signal_client::{Config, Push, SignalConnection};
use rc_transport::{IceState, PeerConfig, PeerSession, TransportEvent};
use tokio::sync::mpsc;

use crate::consent::{ConsentAnswer, ConsentPrompt};
use crate::inject::{InputDispatcher, InputState, Injector};
use crate::keepawake::KeepAwake;
use crate::media::{CaptureBackend, CaptureStatus, Pacing, SoftwareEncoder, VideoEncoder};
use crate::pake::{GuessStore, HostExchange};
use crate::pump::{CapturePump, EncoderFactory, PumpConfig, PumpEvent, VideoSink};
use crate::secrets::{SecretAccount, SecretStore};

/// How long teardown waits for the blocking pump to notice the stop flag. Two
/// frame budgets plus slack: the loop checks the flag every few milliseconds and
/// the longest single blocking call in it is one `AcquireNextFrame` timeout.
const PUMP_STOP_GRACE: Duration = Duration::from_secs(2);

pub struct HostConfig {
    /// `wss://<api base domain>/ws`, derived from the one configured domain by
    /// [`crate::backend`]. No compiled-in address, no certificate pin.
    pub signaling_url: String,
    pub label: String,
    /// §2.17 Consent. **Off** by default: the code proves a controller *may*
    /// connect, and whoever is at this PC decides whether it connects now.
    pub unattended: bool,
    pub force_relay: bool,
    pub bitrate_bps: u32,
    pub fps: f32,
    /// Longest edge the encoder is allowed. See [`Pacing`].
    pub max_dimension: u32,
}

/// §2.17 Consent 3: while the owner is being asked the host has no peer
/// connection, so the controller's offer and its candidates are kept and
/// applied on Allow. The cap is the Mac's `maxHeldCandidates`.
const MAX_HELD_CANDIDATES: usize = 64;

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
    secrets: SecretStore,
    /// The §2.17 exchange for the current session. Nothing is applied and no
    /// `sdp` is sent or accepted until this one is complete.
    exchange: Option<HostExchange>,
    /// The controller key the exchange bound, and the only acceptable signer of
    /// this session's `sdp` (§2.12 step 5).
    expected_peer: Option<String>,
    /// `hello_ok.iceServers` — STUN only, v5.
    base_ice_servers: Vec<sig::IceServer>,
    /// The §2.18 list for the live session, dropped when it ends.
    session_ice_servers: Vec<sig::IceServer>,
    held_sdp: Option<sig::Sdp>,
    held_ice: Vec<sig::Ice>,
    prompt: Option<ConsentPrompt>,
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
        secrets: SecretStore,
    ) -> (Self, mpsc::Receiver<PumpEvent>) {
        Self::with_identity_path(config, identity, key, injector, backend, secrets, None)
    }

    pub fn with_identity_path(
        config: HostConfig,
        identity: IdentityRecord,
        key: DeviceKey,
        injector: I,
        backend: B,
        secrets: SecretStore,
        identity_path: Option<std::path::PathBuf>,
    ) -> (Self, mpsc::Receiver<PumpEvent>) {
        let keep = KeepAwake::enabled(config.unattended);
        let (pump_tx, pump_rx) = mpsc::channel::<PumpEvent>(32);
        let mut machine = SessionStateMachine::new(Role::Host);
        machine.consent_required = !config.unattended;
        let host = Self {
            machine,
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
            secrets,
            exchange: None,
            expected_peer: None,
            base_ice_servers: Vec::new(),
            session_ice_servers: Vec::new(),
            held_sdp: None,
            held_ice: Vec::new(),
            prompt: None,
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
        let mut answers = crate::consent::spawn_console_reader();
        // §4.3 step 1: losing the signalling socket is a *control-plane*
        // outage. Media over an already-established WebRTC path is unaffected,
        // so the peer connection, its event stream and the capture pump outlive
        // any one connection attempt. Tearing them down here is how a session
        // used to die of a moment's network flutter: the controller restarts
        // ICE after its resume, and the host has to still be there to answer.
        let (te_tx, mut te_rx) = mpsc::channel::<TransportEvent>(256);
        let mut peer: Option<Arc<PeerSession>> = None;
        let mut backoff = Duration::from_millis(500);
        loop {
            let attempt = self
                .run_one_connection(
                    &mut pump_rx,
                    &mut shutdown_rx,
                    &mut answers,
                    &mut peer,
                    &te_tx,
                    &mut te_rx,
                )
                .await;
            match attempt {
                Ok(ConnLoopExit::Shutdown) => {
                    self.teardown(&mut peer).await;
                    return Ok(());
                }
                Ok(ConnLoopExit::Reconnect) | Err(_) => {
                    // The backoff is interruptible: asking the host to stop
                    // must not wait out a 15-second sleep with a modifier still
                    // held down on the machine.
                    tokio::select! {
                        _ = tokio::time::sleep(backoff) => {}
                        _ = shutdown_rx.recv() => {
                            self.teardown(&mut peer).await;
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
        answers: &mut mpsc::Receiver<ConsentAnswer>,
        peer: &mut Option<Arc<PeerSession>>,
        te_tx: &mpsc::Sender<TransportEvent>,
        te_rx: &mut mpsc::Receiver<TransportEvent>,
    ) -> Result<ConnLoopExit, String> {
        let cfg = Config::new(&self.config.signaling_url);
        let (conn, mut pushes) = SignalConnection::connect(&cfg).await.map_err(|e| e.to_string())?;
        let conn = Arc::new(conn);
        let registered = self.authenticate(&conn).await?;
        let hello = self.hello(&conn, registered).await?;
        eprintln!(
            "rc-host: authenticated as {} — online and waiting for a controller",
            self.identity.device_id
        );
        self.base_ice_servers = hello.ice_servers.clone();

        let actions = self.machine.signaling_authenticated(
            (!hello.active_session_id.is_empty()).then_some(hello.active_session_id.as_str()),
        );
        self.apply(&actions, &conn, peer, te_tx).await;

        let mut heartbeat = tokio::time::interval(Duration::from_secs(hello.heartbeat_sec.max(1) as u64));
        let mut ticker = tokio::time::interval(Duration::from_millis(500));

        let exit = loop {
            tokio::select! {
                _ = heartbeat.tick() => {
                    let _: Result<sig::HeartbeatOk, _> =
                        conn.request(msg::HEARTBEAT, &(), msg::HEARTBEAT_OK).await;
                }
                _ = ticker.tick() => {
                    let now = now_ms();
                    // The 10-second exchange timer is the host's, not the
                    // state machine's: an exchange that stalls must end the
                    // session rather than sit there holding the 1:1 slot.
                    if self.exchange.as_ref().is_some_and(|e| e.timed_out(now)) {
                        self.end_exchange(crate::pake::ExchangeError::TimedOut, &conn, peer, te_tx)
                            .await;
                    }
                    let actions = self.machine.tick(now);
                    self.apply(&actions, &conn, peer, te_tx).await;
                }
                push = pushes.0.recv() => {
                    let Some(push) = push else {
                        // Socket died: tell the machine, then reconnect.
                        let actions = self.machine.signaling_lost();
                        self.apply(&actions, &conn, peer, te_tx).await;
                        break ConnLoopExit::Reconnect;
                    };
                    if let Some(exit) = self.on_push(push, &conn, peer, te_tx).await {
                        break exit;
                    }
                }
                answer = answers.recv() => {
                    match answer {
                        Some(answer) => self.on_consent_answer(answer, &conn, peer, te_tx).await,
                        // The console closed. A host that cannot be asked must
                        // not fall through to answering for its owner.
                        None => {}
                    }
                }
                event = te_rx.recv() => {
                    if let Some(event) = event {
                        self.on_transport(event, &conn, peer, te_tx).await;
                    }
                }
                event = pump_rx.recv() => {
                    if let Some(event) = event {
                        self.on_pump_event(event, peer).await;
                    }
                }
                _ = shutdown_rx.recv() => {
                    eprintln!("rc-host: stopping - releasing all remote input");
                    break ConnLoopExit::Shutdown;
                }
            }
        };

        // Nothing is torn down here: see §4.3 in `run`. A session that has
        // genuinely ended has already been cleared by whatever ended it.
        Ok(exit)
    }

    /// §2.2: register on first run, and again — once, with the same key — when
    /// `hello` says `unknown_device`. A stored certificate is what makes the
    /// second case keep this PC's Device ID; without one the registry mints a
    /// fresh id, which the host adopts and records rather than asking anyone.
    /// Answers whether this connection has already spent its one `register`.
    async fn authenticate(&mut self, conn: &Arc<SignalConnection>) -> Result<bool, String> {
        if !self.identity.device_id.is_empty() && self.identity.server_registered {
            return Ok(false);
        }
        self.register(conn).await.map(|()| true)
    }

    async fn register(&mut self, conn: &Arc<SignalConnection>) -> Result<(), String> {
        let certificates = self.id_certificates();
        let certificate = certificates
            .get(&self.identity.device_id)
            .cloned()
            .unwrap_or_default();
        let registered = conn
            .register(
                &self.key,
                &self.config.label,
                &self.identity.device_id,
                &certificate,
            )
            .await
            .map_err(|e| e.to_string())?;
        if !self.identity.device_id.is_empty() && registered.device_id != self.identity.device_id {
            eprintln!(
                "rc-host: this PC's Device ID changed from {} to {}; any computer that saved the \
                 old one must be given the new one",
                self.identity.device_id, registered.device_id
            );
        }
        self.identity.device_id = registered.device_id;
        self.identity.server_registered = true;
        self.store_id_certificate(&registered.id_cert);
        if let Some(path) = &self.identity_path {
            if let Err(e) = self.identity.save(path) {
                // A registration that is not written is one that happens again
                // on the next launch, with a different id each time.
                return Err(format!("the identity could not be saved: {e}"));
            }
        }
        eprintln!("rc-host: registered as device {}", self.identity.device_id);
        Ok(())
    }

    /// §2.2 "Re-registering": `unknown_device` means the registry no longer
    /// knows this key, so the stored certificate is presented once to reclaim
    /// the id. `register` is one per connection, so a connection that already
    /// spent its one gives up and lets the backoff loop reconnect rather than
    /// earning a `bad_request`.
    async fn hello(
        &mut self,
        conn: &Arc<SignalConnection>,
        already_registered: bool,
    ) -> Result<sig::HelloOk, String> {
        let first = conn
            .hello(&self.identity.device_id, &self.key, role::HOST)
            .await;
        let hello = match first {
            Ok(hello) => hello,
            Err(e) if e.code() == Some(err::UNKNOWN_DEVICE) && !already_registered => {
                eprintln!("rc-host: the backend does not know this device; re-registering");
                self.register(conn).await?;
                conn.hello(&self.identity.device_id, &self.key, role::HOST)
                    .await
                    .map_err(|e| e.to_string())?
            }
            Err(e) => return Err(e.to_string()),
        };
        self.store_id_certificate(&hello.id_cert);
        Ok(hello)
    }

    fn id_certificates(&self) -> std::collections::BTreeMap<String, String> {
        match self.secrets.map(SecretAccount::DeviceIdCertificates) {
            Ok(book) => book,
            Err(e) => {
                eprintln!("rc-host: {e}");
                std::collections::BTreeMap::new()
            }
        }
    }

    /// The certificate is opaque: it is stored and presented, never parsed.
    /// Keyed by `deviceId` so a changed id does not overwrite the proof that
    /// would have reclaimed the old one.
    fn store_id_certificate(&mut self, certificate: &str) {
        if certificate.is_empty() || self.identity.device_id.is_empty() {
            return;
        }
        let mut book = self.id_certificates();
        if book.get(&self.identity.device_id).is_some_and(|held| held == certificate) {
            return;
        }
        book.insert(self.identity.device_id.clone(), certificate.to_string());
        if let Err(e) = self
            .secrets
            .save(SecretAccount::DeviceIdCertificates, &book)
        {
            eprintln!("rc-host: {e}; this PC may not keep its Device ID across a backend reset");
        }
    }

    async fn on_push(
        &mut self,
        push: Push,
        conn: &Arc<SignalConnection>,
        peer: &mut Option<Arc<PeerSession>>,
        te_tx: &mpsc::Sender<TransportEvent>,
    ) -> Option<ConnLoopExit> {
        match push {
            Push::SessionStart(grant) => {
                self.on_session_start(grant, conn, peer, te_tx).await;
            }
            Push::Pake(frame) => {
                self.on_pake(frame, conn, peer, te_tx).await;
            }
            Push::IceServers(servers) => {
                if self.machine.session_id() != Some(servers.session_id.as_str()) {
                    return None;
                }
                let relays = servers
                    .ice_servers
                    .iter()
                    .filter(|s| !s.credential.is_empty())
                    .count();
                self.session_ice_servers = servers.ice_servers;
                if relays > 0 && peer.as_ref().is_some_and(|p| !p.gathers_relay_candidates()) {
                    // §2.18 arrives *after* this host's first `sdp`, so its own
                    // connection was already built and gathering. webrtc-rs
                    // 0.11 has no `set_configuration`, so these credentials
                    // reach the next connection in this session (a resume or an
                    // ICE restart) and the media path meanwhile relies on the
                    // controller's relay candidate.
                    eprintln!(
                        "rc-host: this session's relay credentials arrived after the connection \
                         was built; they apply from the next ICE generation"
                    );
                }
                let actions = self.machine.ice_servers_arrived(&servers.session_id);
                self.apply(&actions, conn, peer, te_tx).await;
            }
            Push::Sdp(sdp) => {
                self.on_remote_sdp(sdp, conn, peer, te_tx).await;
            }
            Push::Ice(ice) => {
                self.on_remote_ice(ice, peer).await;
            }
            Push::Bye(ended) => {
                let actions = self.machine.close_locally(&ended.reason);
                self.clear_session();
                self.teardown(peer).await;
                self.apply(&actions, conn, peer, te_tx).await;
            }
            Push::ServerError(e) if e.code == err::DISPLACED => {
                // Another socket authenticated as this device. Terminal for
                // this process's connection; do not fight it in a loop.
                return Some(ConnLoopExit::Shutdown);
            }
            Push::ServerError(e) if e.code == err::ENTITLEMENT => {
                eprintln!(
                    "rc-host: the backend refused a session for this PC's account ({}): {}",
                    e.reason, e.message
                );
            }
            _ => {}
        }
        None
    }

    /// §2.9/§2.17: a grant is a *signalling* session. Nothing starts here —
    /// no peer connection, no capture — because the controller has not yet
    /// proved the access code. All this does is tear the last session down and
    /// arm the exchange.
    async fn on_session_start(
        &mut self,
        grant: sig::SessionStart,
        conn: &Arc<SignalConnection>,
        peer: &mut Option<Arc<PeerSession>>,
        te_tx: &mpsc::Sender<TransportEvent>,
    ) {
        let now = now_ms();
        let actions = self.machine.session_granted(
            &SessionGrant {
                session_id: grant.session.session_id.clone(),
                session_token: grant.session.session_token,
                host_device_id: grant.session.host_device_id.clone(),
                controller_device_id: grant.session.controller_device_id,
            },
            now,
        );
        if self.machine.take_rejection().is_some() {
            return;
        }
        // A previous session's peer and pump must be gone before a new one
        // starts; this is what makes a second and third session work rather
        // than silently reuse a dead track.
        self.clear_session();
        self.teardown(peer).await;
        self.apply(&actions, conn, peer, te_tx).await;

        let armed = HostExchange::arm(
            &GuessStore::new(&self.secrets),
            &self.identity.access_code,
            &grant.session.host_device_id,
            &grant.session.session_id,
            &self.key.public_key_spki_base64(),
            &grant.controller_pubkey,
            now,
        );
        match armed {
            Ok(exchange) => self.exchange = Some(exchange),
            Err(e) => self.end_exchange(e, conn, peer, te_tx).await,
        }
    }

    /// One relayed `pake` frame. Everything that decides whether the exchange
    /// may continue is in [`HostExchange`]; what is here is routing, the reply,
    /// and what completion means.
    async fn on_pake(
        &mut self,
        frame: sig::Pake,
        conn: &Arc<SignalConnection>,
        peer: &mut Option<Arc<PeerSession>>,
        te_tx: &mpsc::Sender<TransportEvent>,
    ) {
        let Some(exchange) = &mut self.exchange else { return };
        if exchange.session_id() != frame.session_id || exchange.is_complete() {
            return;
        }
        // v5: a step outside 1..3 is refused at decode, before any handling.
        let step = match u32::try_from(frame.step) {
            Ok(step) if (1..=3).contains(&step) => step,
            _ => {
                self.end_exchange(
                    rc_identity::pake::PakeError::UnexpectedStep {
                        got: 0,
                        expected: rc_identity::pake::STEP_CONTROLLER_START,
                    }
                    .into(),
                    conn,
                    peer,
                    te_tx,
                )
                .await;
                return;
            }
        };
        let message = match PakeMessage::from_base64(step, &frame.payload) {
            Ok(message) => message,
            Err(e) => {
                self.end_exchange(e.into(), conn, peer, te_tx).await;
                return;
            }
        };

        let now = now_ms();
        let session_id = frame.session_id.clone();
        let stepped = {
            let guesses = GuessStore::new(&self.secrets);
            let exchange = self.exchange.as_mut().expect("checked above");
            exchange.step(&guesses, &message, now)
        };
        let reply = match stepped {
            Ok(reply) => reply,
            Err(e) => {
                self.end_exchange(e, conn, peer, te_tx).await;
                return;
            }
        };
        if let Some(reply) = reply {
            if let Err(e) = conn.send_pake(&session_id, &reply).await {
                eprintln!("rc-host: the access-code exchange could not be sent: {e}");
            }
        }
        if self.exchange.as_ref().is_some_and(|e| e.is_complete()) {
            self.exchange_completed(conn, peer, te_tx).await;
        }
    }

    /// The code is proved. The controller key the transcript bound becomes the
    /// only acceptable signer of this session's `sdp`, and — with unattended
    /// access off — the owner is asked before anything starts.
    async fn exchange_completed(
        &mut self,
        conn: &Arc<SignalConnection>,
        peer: &mut Option<Arc<PeerSession>>,
        te_tx: &mpsc::Sender<TransportEvent>,
    ) {
        let Some(exchange) = &self.exchange else { return };
        let controller = exchange.controller_pubkey().to_string();
        self.expected_peer = Some(controller.clone());
        self.record_trusted_controller(&controller);

        let now = now_ms();
        if self.machine.consent_required {
            let ledger = GuessStore::new(&self.secrets).ledger(&controller);
            let admitted = ledger
                .as_ref()
                .map(|ledger| rc_identity::consent::admit(ledger, now));
            if !admitted.as_ref().is_ok_and(|d| d.should_prompt()) {
                eprintln!(
                    "rc-host: declined without asking — the consent budget for this controller \
                     or this PC is spent"
                );
                let actions = self.machine.user_ended(bye::DECLINED);
                self.clear_session();
                self.teardown(peer).await;
                self.apply(&actions, conn, peer, te_tx).await;
                return;
            }
        }
        let actions = self.machine.pake_succeeded(now);
        self.apply(&actions, conn, peer, te_tx).await;
    }

    /// Ends the session the way §2.14 says: `auth_failed` when it was about the
    /// code, `failed` when the exchange merely broke.
    async fn end_exchange(
        &mut self,
        error: crate::pake::ExchangeError,
        conn: &Arc<SignalConnection>,
        peer: &mut Option<Arc<PeerSession>>,
        te_tx: &mpsc::Sender<TransportEvent>,
    ) {
        eprintln!("rc-host: access-code exchange failed: {error}");
        let actions = self.machine.user_ended(error.bye_reason());
        self.clear_session();
        self.teardown(peer).await;
        self.apply(&actions, conn, peer, te_tx).await;
    }

    /// §4.5: the list does not gate anything. It exists so the owner can see
    /// who has connected and so Refresh Code has something to revoke.
    fn record_trusted_controller(&self, pubkey: &str) {
        let Ok(key) = rc_identity::canonical_public_key(pubkey) else { return };
        let mut known: std::collections::BTreeMap<String, TrustedController> =
            match self.secrets.map(SecretAccount::TrustedControllers) {
                Ok(known) => known,
                Err(e) => {
                    eprintln!("rc-host: {e}");
                    return;
                }
            };
        let now = now_ms();
        let label = self
            .machine
            .peer_device_id()
            .map(rc_identity::access_code::formatted_device_id)
            .unwrap_or_default();
        let entry = known.entry(key).or_insert(TrustedController {
            label: label.clone(),
            first_seen_ms: now,
            last_seen_ms: now,
        });
        entry.label = label;
        entry.last_seen_ms = now;
        if let Err(e) = self
            .secrets
            .save(SecretAccount::TrustedControllers, &known)
        {
            eprintln!("rc-host: {e}");
        }
    }

    async fn on_consent_answer(
        &mut self,
        answer: ConsentAnswer,
        conn: &Arc<SignalConnection>,
        peer: &mut Option<Arc<PeerSession>>,
        te_tx: &mpsc::Sender<TransportEvent>,
    ) {
        let Some(prompt) = &self.prompt else { return };
        let prompt_id = prompt.prompt_id.clone();
        let actions =
            self.machine
                .consent_answered(answer == ConsentAnswer::Allow, Some(&prompt_id), now_ms());
        if actions.is_empty() && answer == ConsentAnswer::Allow {
            // §2.17 Consent 4: Allow inside the first 1.5 s is refused, not
            // queued. Saying so is the difference between a guard and a bug.
            println!("  Not yet — please answer again.");
            return;
        }
        self.apply(&actions, conn, peer, te_tx).await;
    }

    /// §2.17 Consent 3 and §4.2: a signal for another session is dropped, one
    /// for this session waits until the state machine itself started the peer,
    /// and nothing touches a peer connection while the owner is being asked.
    fn disposition(&self, session_id: &str, peer: &Option<Arc<PeerSession>>) -> Disposition {
        if self.machine.session_id() != Some(session_id) {
            return Disposition::Drop;
        }
        let started = self.machine.peer_started()
            && *self.machine.phase() != rc_session::SessionPhase::AwaitingConsent;
        match started && peer.is_some() {
            true => Disposition::Apply,
            false => Disposition::Hold,
        }
    }

    /// Everything §2.12 requires of a receiver, in its order, before anything
    /// is installed — and the post-install fingerprint re-check afterwards.
    ///
    /// The host answers; it never offers. An ICE-restart offer takes the same
    /// path, signed again over its own fingerprints.
    async fn on_remote_sdp(
        &mut self,
        sdp: sig::Sdp,
        conn: &Arc<SignalConnection>,
        peer: &mut Option<Arc<PeerSession>>,
        te_tx: &mpsc::Sender<TransportEvent>,
    ) {
        if self.disposition(&sdp.session_id, peer) == Disposition::Drop {
            return;
        }
        // "A peer neither sends nor accepts an `sdp` until its §2.17 exchange
        // for this `sessionId` has completed": an earlier one is dropped, not
        // refused, because it proves nothing either way.
        let (Some(exchange), Some(expected)) = (&self.exchange, self.expected_peer.clone()) else {
            eprintln!("rc-host: dropped an sdp that arrived before the access code was proved");
            return;
        };
        if !exchange.is_complete() || exchange.session_id() != sdp.session_id {
            eprintln!("rc-host: dropped an sdp that arrived before the access code was proved");
            return;
        }
        let Ok(mac_key) = exchange.sdp_mac_key() else {
            eprintln!("rc-host: dropped an sdp that arrived before the access code was proved");
            return;
        };

        let presented = rc_identity::sdp::Presented {
            fingerprints: &sdp.fp,
            pubkey: &sdp.pubkey,
            sig: &sdp.sig,
            mac: &sdp.mac,
        };
        if let Err(e) = rc_identity::sdp::verify(
            &mac_key,
            &sdp.session_id,
            &sdp.sdp_type,
            &sdp.sdp,
            &presented,
            &expected,
        ) {
            self.refuse_peer(&e.to_string(), conn, peer, te_tx).await;
            return;
        }

        if self.disposition(&sdp.session_id, peer) != Disposition::Apply {
            self.held_sdp = Some(sdp);
            return;
        }
        self.install_offer(sdp, &mac_key, conn, peer, te_tx).await;
    }

    /// The verified offer, installed and answered. Candidates are stripped
    /// first: they only ever arrive as `ice`, so "before any remote candidate"
    /// is literally true of the post-install check.
    async fn install_offer(
        &mut self,
        sdp: sig::Sdp,
        mac_key: &[u8; rc_identity::sdp::MAC_KEY_LEN],
        conn: &Arc<SignalConnection>,
        peer: &mut Option<Arc<PeerSession>>,
        te_tx: &mpsc::Sender<TransportEvent>,
    ) {
        let Some(p) = peer.clone() else { return };
        let body = match rc_identity::sdp::without_candidates(&sdp.sdp) {
            Ok(body) => body,
            Err(e) => {
                self.refuse_peer(&e.to_string(), conn, peer, te_tx).await;
                return;
            }
        };
        if let Err(e) = p.set_remote_offer(&body).await {
            eprintln!("rc-host: remote {} failed: {e}", sdp.sdp_type);
            return;
        }

        // §2.12: the fingerprints the WebRTC stack reports as installed must
        // equal the verified ones. This closes any gap between the verifier's
        // SDP parser and the stack's.
        let installed = p.installed_remote_sdp().await.unwrap_or_default();
        match rc_identity::sdp::fingerprints(&installed) {
            Ok(found) if found == sdp.fp => {}
            Ok(_) => {
                self.refuse_peer(
                    "the fingerprints the WebRTC stack installed are not the verified ones",
                    conn,
                    peer,
                    te_tx,
                )
                .await;
                return;
            }
            Err(e) => {
                self.refuse_peer(&e.to_string(), conn, peer, te_tx).await;
                return;
            }
        }

        let answer = match p.answer().await {
            Ok(answer) => answer,
            Err(e) => {
                eprintln!("rc-host: answer failed: {e}");
                return;
            }
        };
        if let Err(e) = self
            .send_signed_sdp(&sdp.session_id, "answer", &answer, sdp.restart, mac_key, conn)
            .await
        {
            eprintln!("rc-host: the answer could not be sent: {e}");
            return;
        }
        self.release_held_candidates(peer).await;
    }

    /// §2.12: `fp`, `pubkey`, `sig` and `mac`. The signature proves *which
    /// device* sent the fingerprints; the MAC proves it was the device that
    /// just proved the access code in this session. Neither is optional — a
    /// peer that enforces §2.12 refuses an answer missing either.
    async fn send_signed_sdp(
        &self,
        session_id: &str,
        sdp_type: &str,
        body: &str,
        restart: bool,
        mac_key: &[u8; rc_identity::sdp::MAC_KEY_LEN],
        conn: &Arc<SignalConnection>,
    ) -> Result<(), String> {
        let signable = rc_identity::sdp::signable(mac_key, session_id, sdp_type, body)
            .map_err(|e| e.to_string())?;
        let signature = self
            .key
            .sign(
                rc_identity::SigningPurpose::Sdp,
                &rc_identity::sdp::payload(session_id, sdp_type, &signable.fingerprints)
                    .map_err(|e| e.to_string())?,
            )
            .map_err(|e| e.to_string())?;
        conn.send(
            msg::SDP,
            &sig::Sdp {
                session_id: session_id.to_string(),
                sdp_type: sdp_type.to_string(),
                sdp: body.to_string(),
                restart,
                fp: signable.fingerprints,
                pubkey: self.key.public_key_spki_base64(),
                sig: signature,
                mac: signable.mac,
            },
        )
        .await
        .map_err(|e| e.to_string())
    }

    async fn on_remote_ice(&mut self, ice: sig::Ice, peer: &Option<Arc<PeerSession>>) {
        match self.disposition(&ice.session_id, peer) {
            Disposition::Drop => {}
            Disposition::Hold => {
                if self.held_ice.len() < MAX_HELD_CANDIDATES {
                    self.held_ice.push(ice);
                }
            }
            Disposition::Apply => {
                if let Some(p) = peer {
                    let _ = p.add_remote_candidate(&ice).await;
                }
            }
        }
    }

    async fn release_held_candidates(&mut self, peer: &Option<Arc<PeerSession>>) {
        for ice in std::mem::take(&mut self.held_ice) {
            if let Some(p) = peer {
                let _ = p.add_remote_candidate(&ice).await;
            }
        }
    }

    /// §2.14: a §2.12 failure is terminal and must never be retried. It is a
    /// device-key failure, which is `peer_auth_failed` — not `auth_failed`,
    /// which is about the code.
    async fn refuse_peer(
        &mut self,
        reason: &str,
        conn: &Arc<SignalConnection>,
        peer: &mut Option<Arc<PeerSession>>,
        te_tx: &mpsc::Sender<TransportEvent>,
    ) {
        eprintln!("rc-host: the other computer could not be verified: {reason}");
        let actions = self.machine.user_ended(bye::PEER_AUTH_FAILED);
        self.clear_session();
        self.teardown(peer).await;
        self.apply(&actions, conn, peer, te_tx).await;
    }

    /// Everything that belongs to one session and must not outlive it: the
    /// exchange and its key, the pinned peer key, the held signals, the prompt,
    /// and — §2.5 — this session's TURN credentials.
    fn clear_session(&mut self) {
        self.exchange = None;
        self.expected_peer = None;
        self.held_sdp = None;
        self.held_ice.clear();
        self.prompt = None;
        self.session_ice_servers.clear();
    }

    async fn on_transport(
        &mut self,
        event: TransportEvent,
        conn: &Arc<SignalConnection>,
        peer: &mut Option<Arc<PeerSession>>,
        te_tx: &mpsc::Sender<TransportEvent>,
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
                self.apply(&actions, conn, peer, te_tx).await;
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

    /// Starts this session's peer connection — the one thing a verified
    /// exchange, and only a verified exchange, is allowed to cause.
    async fn start_peer(
        &mut self,
        peer: &mut Option<Arc<PeerSession>>,
        te_tx: &mpsc::Sender<TransportEvent>,
    ) {
        if !self.exchange.as_ref().is_some_and(|e| e.is_complete()) {
            eprintln!("rc-host: refused to start a peer before the access code was proved");
            return;
        }
        self.teardown(peer).await;
        let servers = match self.session_ice_servers.is_empty() {
            true => self.base_ice_servers.clone(),
            false => self.session_ice_servers.clone(),
        };
        let started = PeerSession::new(PeerConfig {
            ice_servers: servers,
            force_relay: self.config.force_relay,
        })
        .await;
        let (new_peer, mut events) = match started {
            Ok(started) => started,
            Err(e) => {
                eprintln!("rc-host: the peer connection could not be created: {e}");
                return;
            }
        };
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
    }

    /// Perform the effects the state machine asked for.
    async fn apply(
        &mut self,
        actions: &[SessionAction],
        conn: &Arc<SignalConnection>,
        peer: &mut Option<Arc<PeerSession>>,
        te_tx: &mpsc::Sender<TransportEvent>,
    ) {
        for action in actions {
            match action {
                SessionAction::StartPeerConnection { .. } => {
                    self.start_peer(peer, te_tx).await;
                    // The controller offered while the owner was deciding;
                    // §2.17 Consent 3 says that offer is applied now, after the
                    // usual §2.12 checks, and not before.
                    if let (Some(held), Some(exchange)) =
                        (self.held_sdp.take(), self.exchange.as_ref())
                    {
                        if let Ok(mac_key) = exchange.sdp_mac_key() {
                            Box::pin(self.install_offer(held, &mac_key, conn, peer, te_tx)).await;
                        }
                    }
                }
                SessionAction::TeardownPeerConnection => {
                    self.teardown(peer).await;
                }
                SessionAction::ClearStoredSession => {
                    self.clear_session();
                }
                SessionAction::PromptForConsent {
                    prompt_id,
                    replaces_previous,
                    ..
                } => {
                    self.present_consent(prompt_id, *replaces_previous);
                }
                SessionAction::DismissConsentPrompt { outcome } => {
                    self.dismiss_consent(*outcome);
                }
                SessionAction::RestartIce { .. } => {
                    // The controller is the offerer for the initial
                    // negotiation and restarts by default (§2.9, §4.3 step 4).
                    // A host that offered here would be renegotiating against
                    // a peer that is already doing it.
                }
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
                    Box::pin(self.apply(&follow_up, conn, peer, te_tx)).await;
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
                        // §2.11: `iceServers` is present only while the session
                        // is metered, and is then a fresh list with new
                        // 10-minute credentials. Absent means keep what we have.
                        if !ok.ice_servers.is_empty()
                            && self.machine.session_id() == Some(ok.session_id.as_str())
                        {
                            self.session_ice_servers = ok.ice_servers.clone();
                        }
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
                // A host never sends `connect_req`, is never asked for an
                // access code, has no watches of its own, and schedules its
                // resumes on the 500 ms tick.
                SessionAction::SendConnectReq { .. }
                | SessionAction::PromptForAccessCode { .. }
                | SessionAction::ReissueWatches
                | SessionAction::ScheduleResume { .. } => {}
            }
        }
    }

    /// §2.17 Consent: the prompt is named by the core's own random id, never
    /// by the server-chosen `sessionId`, and the budget is charged the moment
    /// it opens — a hang-up while it is up costs the controller as much as a
    /// Decline.
    fn present_consent(&mut self, prompt_id: &str, replaces_previous: bool) {
        let Some(pubkey) = self.expected_peer.clone() else { return };
        let Ok(fingerprint) = rc_identity::public_key_fingerprint(&pubkey) else { return };
        let guesses = GuessStore::new(&self.secrets);
        if let Ok(ledger) = guesses.ledger(&pubkey) {
            let charged = rc_identity::consent::prompted(&ledger, now_ms());
            if let Err(e) = guesses.save(&charged, &pubkey, now_ms()) {
                eprintln!("rc-host: {e}");
            }
        }
        let prompt = ConsentPrompt {
            prompt_id: prompt_id.to_string(),
            controller_device_id: self
                .machine
                .peer_device_id()
                .unwrap_or_default()
                .to_string(),
            controller_fingerprint: fingerprint,
            replaces_previous,
        };
        prompt.render();
        self.prompt = Some(prompt);
    }

    fn dismiss_consent(&mut self, outcome: ConsentOutcome) {
        self.prompt = None;
        ConsentPrompt::dismissed(outcome);
        if outcome == ConsentOutcome::Allowed {
            if let Some(pubkey) = self.expected_peer.clone() {
                let guesses = GuessStore::new(&self.secrets);
                if let Ok(ledger) = guesses.ledger(&pubkey) {
                    let refunded = rc_identity::consent::allowed(&ledger, now_ms());
                    if let Err(e) = guesses.save(&refunded, &pubkey, now_ms()) {
                        eprintln!("rc-host: {e}");
                    }
                }
            }
            return;
        }
        // Nothing held for a request that was not allowed is ever applied.
        self.held_sdp = None;
        self.held_ice.clear();
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Disposition {
    Drop,
    Hold,
    Apply,
}

/// §4.5: who has connected before, for the owner to look at and for Refresh
/// Code to revoke. It gates nothing.
#[derive(Debug, Clone, serde::Serialize, serde::Deserialize)]
struct TrustedController {
    #[serde(default)]
    label: String,
    #[serde(default, rename = "firstSeenMs")]
    first_seen_ms: i64,
    #[serde(default, rename = "lastSeenMs")]
    last_seen_ms: i64,
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
