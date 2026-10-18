//! The signaling connection: one WebSocket lifecycle, from TCP connect through
//! challenge authentication to typed request/reply and pushed events.
//!
//! Reconnection policy deliberately lives OUTSIDE this crate — the session
//! state machine (`rc-session`) decides what a reconnect means, and the host
//! binary owns the backoff loop. This crate's job ends at "an authenticated
//! socket that can send correlated requests and deliver pushes".
//!
//! Mirrors `SignalingClient.swift` in behaviour; the wire itself is pinned by
//! `rc-proto`'s Go-generated vectors, and this crate is pinned by
//! `tests/live_server.rs`, which drives a REAL `rc-signal` binary through
//! register → hello → watch → connect → sdp/ice relay → bye.

#![forbid(unsafe_code)]

use std::collections::HashMap;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::Arc;
use std::time::Duration;

use futures_util::{SinkExt, StreamExt};
use rc_proto::consts::msg;
use rc_proto::envelope::Envelope;
use rc_proto::signaling as sig;
use tokio::sync::{mpsc, oneshot, Mutex};
use tokio_tungstenite::tungstenite::client::IntoClientRequest;
use tokio_tungstenite::tungstenite::Message;

#[derive(Debug, thiserror::Error)]
pub enum SignalError {
    #[error("websocket: {0}")]
    WebSocket(String),
    #[error("protocol: {0}")]
    Protocol(String),
    #[error("server error {code}: {message}")]
    Server { code: String, message: String, retry_after_sec: i32 },
    #[error("timed out waiting for {0}")]
    Timeout(&'static str),
    #[error("connection closed")]
    Closed,
}

impl SignalError {
    pub fn code(&self) -> Option<&str> {
        match self {
            Self::Server { code, .. } => Some(code),
            _ => None,
        }
    }

    pub fn retry_after_sec(&self) -> i32 {
        match self {
            Self::Server { retry_after_sec, .. } => *retry_after_sec,
            _ => 0,
        }
    }
}

/// Unsolicited messages the server pushes. Everything else arrives as a reply.
#[derive(Debug)]
pub enum Push {
    Challenge(sig::Challenge),
    Presence(sig::Presence),
    SessionStart(sig::SessionStart),
    PeerState(sig::PeerState),
    Sdp(sig::Sdp),
    Ice(sig::Ice),
    /// One frame of the §2.17 access-code exchange, relayed opaquely.
    Pake(sig::Pake),
    /// *v5* §2.18: this session's TURN credentials, pushed once metering starts.
    IceServers(sig::IceServers),
    Bye(sig::Bye),
    /// An `error` with no `re` — e.g. `displaced` when another socket
    /// authenticates as this device.
    ServerError(sig::ErrorPayload),
    /// The socket died. Terminal for this connection object.
    Disconnected(String),
}

pub struct Config {
    /// `wss://<api base domain>/ws`, derived from the one configured domain.
    /// `ws://127.0.0.1:<port>/ws` is local development only.
    pub url: String,
    pub request_timeout: Duration,
    pub handshake_timeout: Duration,
}

impl Config {
    pub fn new(url: &str) -> Self {
        Self {
            url: url.to_string(),
            request_timeout: Duration::from_secs(15),
            handshake_timeout: Duration::from_secs(20),
        }
    }
}

type Pending = Arc<Mutex<HashMap<String, oneshot::Sender<Envelope>>>>;

/// One authenticated-or-authenticating socket.
pub struct SignalConnection {
    outgoing: mpsc::Sender<Message>,
    pending: Pending,
    next_id: AtomicU64,
    request_timeout: Duration,
    /// The most recent unconsumed challenge nonce (raw bytes).
    challenge: Arc<Mutex<Option<Vec<u8>>>>,
}

pub struct PushReceiver(pub mpsc::Receiver<Push>);

impl SignalConnection {
    /// Open the socket. The first `challenge` is awaited here so callers can
    /// immediately authenticate; later challenges also refresh the stored nonce.
    ///
    /// §0: binary frames are a protocol error. The server never sends them, so one is treated as a dead socket.
    ///
    /// §0: unknown pushes are ignored.
    ///
    /// When the socket ends, every in-flight request fails so callers see `Closed`, not a hang.
    ///
    /// The server pushes `challenge` immediately on connect (§2.1); `connect` waits for it so `authenticate` has a nonce to sign.
    pub async fn connect(config: &Config) -> Result<(Self, PushReceiver), SignalError> {
        let request = config
            .url
            .as_str()
            .into_client_request()
            .map_err(|e| SignalError::WebSocket(e.to_string()))?;
        let (ws, _) = tokio::time::timeout(
            config.handshake_timeout,
            tokio_tungstenite::connect_async_tls_with_config(request, None, true, None),
        )
        .await
        .map_err(|_| SignalError::Timeout("websocket handshake"))?
        .map_err(|e| SignalError::WebSocket(e.to_string()))?;

        let (mut sink, mut stream) = ws.split();
        let (out_tx, mut out_rx) = mpsc::channel::<Message>(64);
        let (push_tx, push_rx) = mpsc::channel::<Push>(64);
        let pending: Pending = Arc::new(Mutex::new(HashMap::new()));
        let challenge = Arc::new(Mutex::new(None::<Vec<u8>>));

        tokio::spawn(async move {
            while let Some(frame) = out_rx.recv().await {
                if sink.send(frame).await.is_err() {
                    break;
                }
            }
            let _ = sink.close().await;
        });

        {
            let pending = pending.clone();
            let challenge = challenge.clone();
            let push_tx = push_tx.clone();
            tokio::spawn(async move {
                let reason = loop {
                    let frame = match stream.next().await {
                        Some(Ok(f)) => f,
                        Some(Err(e)) => break e.to_string(),
                        None => break "eof".to_string(),
                    };
                    let text = match frame {
                        Message::Text(t) => t,
                        Message::Ping(_) | Message::Pong(_) => continue,
                        Message::Close(c) => {
                            break c.map(|c| c.to_string()).unwrap_or_else(|| "close".into())
                        }
                        _ => break "unexpected non-text frame".to_string(),
                    };
                    let env = match Envelope::decode(text.as_bytes()) {
                        Ok(env) => env,
                        Err(e) => break format!("bad frame: {e}"),
                    };

                    if !env.re.is_empty() {
                        if let Some(tx) = pending.lock().await.remove(&env.re) {
                            let _ = tx.send(env);
                            continue;
                        }
                    }

                    let forward = |p: Push| {
                        let push_tx = push_tx.clone();
                        async move {
                            let _ = push_tx.send(p).await;
                        }
                    };
                    match env.msg_type.as_str() {
                        msg::CHALLENGE => {
                            if let Ok(c) = env.payload_as::<sig::Challenge>() {
                                use base64::Engine;
                                if let Ok(nonce) =
                                    base64::engine::general_purpose::STANDARD.decode(&c.nonce)
                                {
                                    *challenge.lock().await = Some(nonce);
                                }
                                forward(Push::Challenge(c)).await;
                            }
                        }
                        msg::PRESENCE => {
                            if let Ok(p) = env.payload_as() {
                                forward(Push::Presence(p)).await;
                            }
                        }
                        msg::SESSION_START => {
                            if let Ok(p) = env.payload_as() {
                                forward(Push::SessionStart(p)).await;
                            }
                        }
                        msg::PEER_STATE => {
                            if let Ok(p) = env.payload_as() {
                                forward(Push::PeerState(p)).await;
                            }
                        }
                        msg::SDP => {
                            if let Ok(p) = env.payload_as() {
                                forward(Push::Sdp(p)).await;
                            }
                        }
                        msg::ICE => {
                            if let Ok(p) = env.payload_as() {
                                forward(Push::Ice(p)).await;
                            }
                        }
                        msg::PAKE => {
                            if let Ok(p) = env.payload_as() {
                                forward(Push::Pake(p)).await;
                            }
                        }
                        msg::ICE_SERVERS => {
                            if let Ok(p) = env.payload_as() {
                                forward(Push::IceServers(p)).await;
                            }
                        }
                        msg::BYE => {
                            if let Ok(p) = env.payload_as() {
                                forward(Push::Bye(p)).await;
                            }
                        }
                        msg::ERROR => {
                            if let Ok(p) = env.payload_as() {
                                forward(Push::ServerError(p)).await;
                            }
                        }
                        _ => {}
                    }
                };
                pending.lock().await.clear();
                let _ = push_tx.send(Push::Disconnected(reason)).await;
            });
        }

        let conn = Self {
            outgoing: out_tx,
            pending,
            next_id: AtomicU64::new(1),
            request_timeout: config.request_timeout,
            challenge,
        };
        let deadline = tokio::time::Instant::now() + config.handshake_timeout;
        loop {
            if conn.challenge.lock().await.is_some() {
                break;
            }
            if tokio::time::Instant::now() >= deadline {
                return Err(SignalError::Timeout("initial challenge"));
            }
            tokio::time::sleep(Duration::from_millis(10)).await;
        }
        Ok((conn, PushReceiver(push_rx)))
    }

    fn now_ms() -> i64 {
        std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map(|d| d.as_millis() as i64)
            .unwrap_or(0)
    }

    /// Take the current challenge nonce (single-use, §2.1).
    pub async fn take_challenge_nonce(&self) -> Option<Vec<u8>> {
        self.challenge.lock().await.take()
    }

    /// Fire-and-forget send (`sdp`, `ice`, `bye` need no reply).
    pub async fn send<T: serde::Serialize>(
        &self,
        msg_type: &str,
        payload: &T,
    ) -> Result<(), SignalError> {
        let env = Envelope::new(msg_type, "", "", Self::now_ms(), Some(payload))
            .map_err(|e| SignalError::Protocol(e.to_string()))?;
        let bytes = env.encode().map_err(|e| SignalError::Protocol(e.to_string()))?;
        self.outgoing
            .send(Message::Text(String::from_utf8(bytes).expect("json is utf8")))
            .await
            .map_err(|_| SignalError::Closed)
    }

    /// Correlated request: assigns an id, waits for the matching reply, maps a
    /// same-id `error` into `SignalError::Server`.
    pub async fn request<T: serde::Serialize, R: serde::de::DeserializeOwned>(
        &self,
        msg_type: &str,
        payload: &T,
        expect_reply_type: &str,
    ) -> Result<R, SignalError> {
        let id = format!("r-{}", self.next_id.fetch_add(1, Ordering::Relaxed));
        let env = Envelope::new(msg_type, &id, "", Self::now_ms(), Some(payload))
            .map_err(|e| SignalError::Protocol(e.to_string()))?;
        let bytes = env.encode().map_err(|e| SignalError::Protocol(e.to_string()))?;

        let (tx, rx) = oneshot::channel();
        self.pending.lock().await.insert(id.clone(), tx);
        if self
            .outgoing
            .send(Message::Text(String::from_utf8(bytes).expect("json is utf8")))
            .await
            .is_err()
        {
            self.pending.lock().await.remove(&id);
            return Err(SignalError::Closed);
        }

        let reply = match tokio::time::timeout(self.request_timeout, rx).await {
            Ok(Ok(env)) => env,
            Ok(Err(_)) => return Err(SignalError::Closed),
            Err(_) => {
                self.pending.lock().await.remove(&id);
                return Err(SignalError::Timeout("reply"));
            }
        };

        if reply.msg_type == msg::ERROR {
            let e: sig::ErrorPayload = reply
                .payload_as()
                .map_err(|e| SignalError::Protocol(e.to_string()))?;
            return Err(SignalError::Server {
                code: e.code,
                message: e.message,
                retry_after_sec: e.retry_after_sec,
            });
        }
        if reply.msg_type != expect_reply_type {
            return Err(SignalError::Protocol(format!(
                "expected {expect_reply_type}, got {}",
                reply.msg_type
            )));
        }
        reply
            .payload_as()
            .map_err(|e| SignalError::Protocol(e.to_string()))
    }

    /// Mint a device id, or reclaim the one this key already holds. Consumes
    /// the pending challenge; the server pushes a fresh one after
    /// `register_ok` for the follow-up `hello`.
    ///
    /// `preferred_device_id` and `id_cert` are the §2.2 re-registration pair:
    /// the id this key last held and the certificate the registry issued for
    /// it. Without a certificate the registry mints a fresh id whatever is
    /// asked for, so either both are sent or neither is.
    ///
    /// No access-code verifier is sent. A v5 server answers `bad_request` to a
    /// `register` that carries one: it stores nothing about any access code,
    /// which is proved peer to peer instead (§2.3, §2.17).
    pub async fn register(
        &self,
        key: &rc_identity::DeviceKey,
        label: &str,
        preferred_device_id: &str,
        id_cert: &str,
    ) -> Result<sig::RegisterOk, SignalError> {
        let nonce = self
            .take_challenge_nonce()
            .await
            .ok_or(SignalError::Timeout("challenge before register"))?;
        let restoring = !preferred_device_id.is_empty() && !id_cert.is_empty();
        let borrow = |value: &str| match restoring {
            true => value.to_string(),
            false => String::new(),
        };
        let payload = sig::Register {
            pubkey: key.public_key_spki_base64(),
            sig: key
                .sign(rc_identity::SigningPurpose::Register, &nonce)
                .map_err(|e| SignalError::Protocol(e.to_string()))?,
            label: label.to_string(),
            preferred_device_id: borrow(preferred_device_id),
            id_cert: borrow(id_cert),
            code: sig::CodeVerifier::default(),
        };
        self.request(msg::REGISTER, &payload, msg::REGISTER_OK).await
    }

    /// One `pake` frame (§2.17). Fire-and-forget: the reply is the peer's next
    /// step, which arrives as a push.
    pub async fn send_pake(
        &self,
        session_id: &str,
        message: &rc_identity::pake::PakeMessage,
    ) -> Result<(), SignalError> {
        self.send(
            msg::PAKE,
            &sig::Pake {
                session_id: session_id.to_string(),
                step: message.step as i32,
                payload: message.to_base64(),
            },
        )
        .await
    }

    /// Authenticate an existing device. On success the socket is this device's
    /// presence connection until it dies.
    ///
    /// The register flow consumes the connect-time challenge and the server pushes another, so this waits briefly for one to be present.
    pub async fn hello(
        &self,
        device_id: &str,
        key: &rc_identity::DeviceKey,
        role: &str,
    ) -> Result<sig::HelloOk, SignalError> {
        let deadline = tokio::time::Instant::now() + self.request_timeout;
        let nonce = loop {
            if let Some(nonce) = self.take_challenge_nonce().await {
                break nonce;
            }
            if tokio::time::Instant::now() >= deadline {
                return Err(SignalError::Timeout("challenge before hello"));
            }
            tokio::time::sleep(Duration::from_millis(10)).await;
        };
        let payload = sig::Hello {
            device_id: device_id.to_string(),
            pubkey: key.public_key_spki_base64(),
            sig: key
                .sign(rc_identity::SigningPurpose::Hello, &nonce)
                .map_err(|e| SignalError::Protocol(e.to_string()))?,
            role: role.to_string(),
        };
        self.request(msg::HELLO, &payload, msg::HELLO_OK).await
    }
}
