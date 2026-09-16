//! The access-code exchange of PROTOCOL.md §2.17: symmetric SPAKE2 between the
//! controller and the host, relayed verbatim by the server.
//!
//! The code itself never leaves either machine. Both sides run SPAKE2 over
//! Ed25519 with the *same* password — the normalised access code — and the same
//! symmetric identity, which is where the context binding lives:
//!
//! ```text
//! identity = "skipperdesk/pake/v1|" deviceId "|" sessionId
//! password = normalised access code (Crockford, uppercase, separators dropped)
//! ```
//!
//! Binding the host `deviceId` and the `sessionId` into the SPAKE2 identity
//! means a message captured in one session is useless in another: the two sides
//! would derive different keys and the confirmation below would fail. The role
//! names `skipperdesk-controller` / `skipperdesk-host` are **not** SPAKE2
//! identities (symmetric SPAKE2 has exactly one); they are the HKDF `info` that
//! separates the two confirmation keys, so neither side can replay the other's
//! tag.
//!
//! Key schedule, once SPAKE2 agrees on a 32-byte shared key:
//!
//! ```text
//! transcript = len32("skipperdesk/pake/v1") ‖ len32(deviceId) ‖ len32(sessionId)
//!              ‖ len32(controllerPubkey) ‖ len32(hostPubkey)
//!              ‖ len32(controllerMessage) ‖ len32(hostMessage)
//! prk        = HKDF-SHA256-Extract(salt = transcript, ikm = sharedKey)
//! sessionKey = Expand(prk, "skipperdesk/pake/v1 session-key", 32)
//! kcC        = Expand(prk, "skipperdesk/pake/v1 confirm skipperdesk-controller", 32)
//! kcH        = Expand(prk, "skipperdesk/pake/v1 confirm skipperdesk-host", 32)
//! confirmC   = HMAC-SHA256(kcC, transcript)
//! confirmH   = HMAC-SHA256(kcH, transcript)
//! ```
//!
//! On the wire (`pake.step`, payloads base64, ≤ 4096 characters), where
//! `len32(x)` is a big-endian 4-byte length prefix:
//!
//! | step | from | payload |
//! |---|---|---|
//! | 1 | controller | `len32(controllerPubkey)` ‖ controllerPubkey ‖ controller SPAKE2 message |
//! | 2 | host | `len32(hostPubkey)` ‖ hostPubkey ‖ host SPAKE2 message ‖ `confirmH` |
//! | 3 | controller | `confirmC` |
//!
//! The pubkeys are the two DER SPKI device keys, and they are in the transcript
//! above, so a relay that swaps one for its own breaks the confirmation it
//! cannot compute. That is what makes the key each side learns here safe to use
//! as the expected signer of the peer's `sdp` fingerprints (§2.12): without the
//! binding, a server that relayed a genuine exchange untouched could still have
//! handed each side its own key and sat in the middle of the DTLS handshake.
//!
//! A wrong code produces different keys on the two sides, so step 2 fails for
//! the controller and step 3 fails for the **host** — which is what matters:
//! the host learns the attempt was wrong before it has done anything else, and
//! feeds that failure to [`GuessPolicy`].

use base64::engine::general_purpose::STANDARD as B64;
use base64::Engine;
use hkdf::Hkdf;
use hmac::{Hmac, Mac};
use serde::{Deserialize, Serialize};
use sha2::Sha256;
use spake2::{Ed25519Group, Identity, Password, Spake2};

pub const STEP_CONTROLLER_START: u32 = 1;
pub const STEP_HOST_REPLY: u32 = 2;
pub const STEP_CONTROLLER_CONFIRM: u32 = 3;

pub const MAX_PAYLOAD_BASE64: usize = 4096;
pub const SESSION_KEY_LEN: usize = 32;
pub const CONFIRM_LEN: usize = 32;

/// A DER SPKI P-256 key is 91 bytes; the cap exists only so a malformed length
/// prefix cannot make a receiver allocate.
pub const MAX_PUBLIC_KEY_LEN: usize = 256;

const CONTEXT_LABEL: &str = "skipperdesk/pake/v1";
const CONTROLLER_IDENTITY: &str = "skipperdesk-controller";
const HOST_IDENTITY: &str = "skipperdesk-host";

type HmacSha256 = Hmac<Sha256>;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum PakeRole {
    Controller,
    Host,
}

#[derive(Debug, thiserror::Error, PartialEq, Eq)]
pub enum PakeError {
    #[error("access code is empty after normalisation")]
    EmptyCode,
    #[error("deviceId, sessionId and the device public key are required")]
    MissingContext,
    #[error("payload is not valid base64")]
    BadBase64,
    #[error("payload exceeds {MAX_PAYLOAD_BASE64} base64 characters")]
    PayloadTooLarge,
    #[error("payload is malformed")]
    BadPayload,
    #[error("unexpected step {got}, expected {expected}")]
    UnexpectedStep { got: u32, expected: u32 },
    #[error("the exchange has already finished")]
    AlreadyFinished,
    #[error("the exchange failed earlier and cannot continue")]
    Abandoned,
    #[error("spake2 rejected the peer message")]
    BadPeerMessage,
    #[error("confirmation failed: the access code does not match")]
    ConfirmationFailed,
    #[error("the session key is not available until the exchange completes")]
    NotComplete,
}

/// One `pake` frame's payload, decoded.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PakeMessage {
    pub step: u32,
    pub payload: Vec<u8>,
}

impl PakeMessage {
    pub fn to_base64(&self) -> String {
        B64.encode(&self.payload)
    }

    pub fn from_base64(step: u32, payload_base64: &str) -> Result<Self, PakeError> {
        if payload_base64.len() > MAX_PAYLOAD_BASE64 {
            return Err(PakeError::PayloadTooLarge);
        }
        let payload = B64
            .decode(payload_base64.as_bytes())
            .map_err(|_| PakeError::BadBase64)?;
        Ok(Self { step, payload })
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Stage {
    Fresh,
    ControllerAwaitingReply,
    HostAwaitingConfirm,
    Complete,
    Abandoned,
}

struct Keys {
    session: [u8; SESSION_KEY_LEN],
    controller_confirm: [u8; CONFIRM_LEN],
    host_confirm: [u8; CONFIRM_LEN],
}

impl Drop for Keys {
    fn drop(&mut self) {
        burn(&mut self.session);
        burn(&mut self.controller_confirm);
        burn(&mut self.host_confirm);
    }
}

/// One side of the exchange. Drive it with [`PakeExchange::step`]: the
/// controller starts by stepping `None`, every other call carries the frame
/// that arrived from the peer.
pub struct PakeExchange {
    role: PakeRole,
    password: Vec<u8>,
    identity: Vec<u8>,
    device_id: String,
    session_id: String,
    own_public_key: Vec<u8>,
    peer_public_key: Vec<u8>,
    stage: Stage,
    state: Option<Spake2<Ed25519Group>>,
    own_message: Vec<u8>,
    keys: Option<Keys>,
    #[cfg(test)]
    test_seed: Option<u8>,
}

impl Drop for PakeExchange {
    fn drop(&mut self) {
        burn(&mut self.password);
    }
}

impl PakeExchange {
    /// `own_public_key_base64` is this device's own `pubkey` (base64 DER SPKI).
    /// It travels in this side's first frame and is bound into the transcript,
    /// so the peer ends the exchange knowing which key must sign the `sdp`
    /// fingerprints it will accept.
    pub fn controller(
        access_code: &str,
        device_id: &str,
        session_id: &str,
        own_public_key_base64: &str,
    ) -> Result<Self, PakeError> {
        Self::new(
            PakeRole::Controller,
            access_code,
            device_id,
            session_id,
            own_public_key_base64,
        )
    }

    pub fn host(
        access_code: &str,
        device_id: &str,
        session_id: &str,
        own_public_key_base64: &str,
    ) -> Result<Self, PakeError> {
        Self::new(
            PakeRole::Host,
            access_code,
            device_id,
            session_id,
            own_public_key_base64,
        )
    }

    fn new(
        role: PakeRole,
        access_code: &str,
        device_id: &str,
        session_id: &str,
        own_public_key_base64: &str,
    ) -> Result<Self, PakeError> {
        let password = crate::access_code::normalize(access_code);
        if password.is_empty() {
            return Err(PakeError::EmptyCode);
        }
        if device_id.is_empty() || session_id.is_empty() {
            return Err(PakeError::MissingContext);
        }
        let own_public_key = B64
            .decode(own_public_key_base64.as_bytes())
            .map_err(|_| PakeError::MissingContext)?;
        if own_public_key.is_empty() || own_public_key.len() > MAX_PUBLIC_KEY_LEN {
            return Err(PakeError::MissingContext);
        }
        Ok(Self {
            role,
            password: password.into_bytes(),
            identity: format!("{CONTEXT_LABEL}|{device_id}|{session_id}").into_bytes(),
            device_id: device_id.to_string(),
            session_id: session_id.to_string(),
            own_public_key,
            peer_public_key: Vec::new(),
            stage: Stage::Fresh,
            state: None,
            own_message: Vec::new(),
            keys: None,
            #[cfg(test)]
            test_seed: None,
        })
    }

    pub fn role(&self) -> PakeRole {
        self.role
    }

    pub fn is_complete(&self) -> bool {
        self.stage == Stage::Complete
    }

    /// The peer's device `pubkey`, base64 DER SPKI, once its first frame has
    /// arrived: the host learns it at step 1, the controller at step 2. Empty
    /// before that.
    pub fn peer_public_key_base64(&self) -> String {
        if self.peer_public_key.is_empty() {
            String::new()
        } else {
            B64.encode(&self.peer_public_key)
        }
    }

    pub fn session_key(&self) -> Result<[u8; SESSION_KEY_LEN], PakeError> {
        match (&self.keys, self.stage) {
            (Some(keys), Stage::Complete) => Ok(keys.session),
            _ => Err(PakeError::NotComplete),
        }
    }

    /// The 32-byte key, base64 (std, padded) — the form the FFI hands out.
    pub fn session_key_base64(&self) -> Result<String, PakeError> {
        self.session_key().map(|key| B64.encode(key))
    }

    pub fn step(&mut self, incoming: Option<&PakeMessage>) -> Result<Option<PakeMessage>, PakeError> {
        match self.stage {
            Stage::Abandoned => return Err(PakeError::Abandoned),
            Stage::Complete => return Err(PakeError::AlreadyFinished),
            _ => {}
        }
        let result = self.advance(incoming);
        if result.is_err() {
            self.stage = Stage::Abandoned;
        }
        result
    }

    fn advance(&mut self, incoming: Option<&PakeMessage>) -> Result<Option<PakeMessage>, PakeError> {
        match (self.role, self.stage, incoming) {
            (PakeRole::Controller, Stage::Fresh, None) => Ok(Some(self.controller_start())),
            (PakeRole::Controller, Stage::ControllerAwaitingReply, Some(message)) => {
                self.expect_step(message, STEP_HOST_REPLY)?;
                self.controller_finish(&message.payload).map(Some)
            }
            (PakeRole::Host, Stage::Fresh, Some(message)) => {
                self.expect_step(message, STEP_CONTROLLER_START)?;
                self.host_reply(&message.payload).map(Some)
            }
            (PakeRole::Host, Stage::HostAwaitingConfirm, Some(message)) => {
                self.expect_step(message, STEP_CONTROLLER_CONFIRM)?;
                self.host_finish(&message.payload)?;
                Ok(None)
            }
            (role, stage, incoming) => Err(PakeError::UnexpectedStep {
                got: incoming.map(|m| m.step).unwrap_or(0),
                expected: expected_step(role, stage),
            }),
        }
    }

    fn expect_step(&self, message: &PakeMessage, expected: u32) -> Result<(), PakeError> {
        if message.step == expected {
            Ok(())
        } else {
            Err(PakeError::UnexpectedStep { got: message.step, expected })
        }
    }

    fn controller_start(&mut self) -> PakeMessage {
        let (state, message) = self.begin();
        self.state = Some(state);
        self.own_message = message.clone();
        self.stage = Stage::ControllerAwaitingReply;
        PakeMessage {
            step: STEP_CONTROLLER_START,
            payload: prefix_public_key(&self.own_public_key, &message),
        }
    }

    fn controller_finish(&mut self, payload: &[u8]) -> Result<PakeMessage, PakeError> {
        let (host_public_key, rest) = split_public_key(payload)?;
        if rest.len() <= CONFIRM_LEN {
            return Err(PakeError::BadPayload);
        }
        self.peer_public_key = host_public_key.to_vec();
        let (host_message, host_confirm) = rest.split_at(rest.len() - CONFIRM_LEN);
        if host_message == self.own_message.as_slice() {
            return Err(PakeError::BadPeerMessage);
        }
        let shared = self.finish_spake2(host_message)?;
        let transcript = self.transcript(&self.own_message, host_message);
        let keys = derive(&shared, &transcript);
        verify(&keys.host_confirm, host_confirm)?;
        let controller_confirm = keys.controller_confirm.to_vec();
        self.keys = Some(keys);
        self.stage = Stage::Complete;
        Ok(PakeMessage { step: STEP_CONTROLLER_CONFIRM, payload: controller_confirm })
    }

    fn host_reply(&mut self, payload: &[u8]) -> Result<PakeMessage, PakeError> {
        let (controller_public_key, controller_message) = split_public_key(payload)?;
        if controller_message.is_empty() {
            return Err(PakeError::BadPayload);
        }
        self.peer_public_key = controller_public_key.to_vec();
        let (state, message) = self.begin();
        self.state = Some(state);
        self.own_message = message.clone();
        if controller_message == self.own_message.as_slice() {
            return Err(PakeError::BadPeerMessage);
        }
        let shared = self.finish_spake2(controller_message)?;
        let transcript = self.transcript(controller_message, &self.own_message);
        let keys = derive(&shared, &transcript);
        let mut payload = prefix_public_key(&self.own_public_key, &message);
        payload.extend_from_slice(&keys.host_confirm);
        self.keys = Some(keys);
        self.stage = Stage::HostAwaitingConfirm;
        Ok(PakeMessage { step: STEP_HOST_REPLY, payload })
    }

    fn host_finish(&mut self, controller_confirm: &[u8]) -> Result<(), PakeError> {
        let keys = self.keys.as_ref().ok_or(PakeError::Abandoned)?;
        verify(&keys.controller_confirm, controller_confirm)?;
        self.stage = Stage::Complete;
        Ok(())
    }

    fn begin(&self) -> (Spake2<Ed25519Group>, Vec<u8>) {
        #[cfg(test)]
        if let Some(seed) = self.test_seed {
            return Spake2::<Ed25519Group>::start_symmetric_with_rng(
                &Password::new(&self.password),
                &Identity::new(&self.identity),
                crate::pake::tests::SeededRng::new(seed),
            );
        }
        Spake2::<Ed25519Group>::start_symmetric(
            &Password::new(&self.password),
            &Identity::new(&self.identity),
        )
    }

    fn finish_spake2(&mut self, peer_message: &[u8]) -> Result<Vec<u8>, PakeError> {
        let state = self.state.take().ok_or(PakeError::Abandoned)?;
        state.finish(peer_message).map_err(|_| PakeError::BadPeerMessage)
    }

    fn transcript(&self, controller_message: &[u8], host_message: &[u8]) -> Vec<u8> {
        let (controller_public_key, host_public_key) = match self.role {
            PakeRole::Controller => (&self.own_public_key, &self.peer_public_key),
            PakeRole::Host => (&self.peer_public_key, &self.own_public_key),
        };
        let mut out = Vec::new();
        for field in [
            CONTEXT_LABEL.as_bytes(),
            self.device_id.as_bytes(),
            self.session_id.as_bytes(),
            controller_public_key,
            host_public_key,
            controller_message,
            host_message,
        ] {
            out.extend_from_slice(&(field.len() as u32).to_be_bytes());
            out.extend_from_slice(field);
        }
        out
    }
}

fn prefix_public_key(public_key: &[u8], body: &[u8]) -> Vec<u8> {
    let mut out = Vec::with_capacity(4 + public_key.len() + body.len());
    out.extend_from_slice(&(public_key.len() as u32).to_be_bytes());
    out.extend_from_slice(public_key);
    out.extend_from_slice(body);
    out
}

fn split_public_key(payload: &[u8]) -> Result<(&[u8], &[u8]), PakeError> {
    if payload.len() < 4 {
        return Err(PakeError::BadPayload);
    }
    let (length, rest) = payload.split_at(4);
    let length = u32::from_be_bytes([length[0], length[1], length[2], length[3]]) as usize;
    if length == 0 || length > MAX_PUBLIC_KEY_LEN || length > rest.len() {
        return Err(PakeError::BadPayload);
    }
    Ok(rest.split_at(length))
}

fn expected_step(role: PakeRole, stage: Stage) -> u32 {
    match (role, stage) {
        (PakeRole::Controller, Stage::Fresh) => 0,
        (PakeRole::Controller, _) => STEP_HOST_REPLY,
        (PakeRole::Host, Stage::Fresh) => STEP_CONTROLLER_START,
        (PakeRole::Host, _) => STEP_CONTROLLER_CONFIRM,
    }
}

fn derive(shared: &[u8], transcript: &[u8]) -> Keys {
    let hkdf = Hkdf::<Sha256>::new(Some(transcript), shared);
    let mut keys = Keys {
        session: [0u8; SESSION_KEY_LEN],
        controller_confirm: [0u8; CONFIRM_LEN],
        host_confirm: [0u8; CONFIRM_LEN],
    };
    let mut controller_key = [0u8; 32];
    let mut host_key = [0u8; 32];
    expand(&hkdf, &format!("{CONTEXT_LABEL} session-key"), &mut keys.session);
    expand(&hkdf, &format!("{CONTEXT_LABEL} confirm {CONTROLLER_IDENTITY}"), &mut controller_key);
    expand(&hkdf, &format!("{CONTEXT_LABEL} confirm {HOST_IDENTITY}"), &mut host_key);
    keys.controller_confirm = tag(&controller_key, transcript);
    keys.host_confirm = tag(&host_key, transcript);
    burn(&mut controller_key);
    burn(&mut host_key);
    keys
}

fn expand(hkdf: &Hkdf<Sha256>, info: &str, out: &mut [u8]) {
    hkdf.expand(info.as_bytes(), out)
        .expect("32 bytes is a legal HKDF-SHA256 output length");
}

fn tag(key: &[u8], transcript: &[u8]) -> [u8; CONFIRM_LEN] {
    let mut mac = HmacSha256::new_from_slice(key).expect("HMAC accepts any key length");
    mac.update(transcript);
    mac.finalize().into_bytes().into()
}

fn verify(expected: &[u8; CONFIRM_LEN], presented: &[u8]) -> Result<(), PakeError> {
    if presented.len() != CONFIRM_LEN {
        return Err(PakeError::BadPayload);
    }
    if constant_time_equal(expected, presented) {
        Ok(())
    } else {
        Err(PakeError::ConfirmationFailed)
    }
}

fn constant_time_equal(left: &[u8], right: &[u8]) -> bool {
    if left.len() != right.len() {
        return false;
    }
    let mut difference = 0u8;
    for (a, b) in left.iter().zip(right.iter()) {
        difference |= a ^ b;
    }
    difference == 0
}

fn burn(bytes: &mut [u8]) {
    for byte in bytes.iter_mut() {
        unsafe { std::ptr::write_volatile(byte, 0) };
    }
    std::sync::atomic::compiler_fence(std::sync::atomic::Ordering::SeqCst);
}

/// How many wrong codes a controller may present before the host stops
/// answering, PROTOCOL.md §2.17.
///
/// Pure by design: it owns no clock and no storage. The caller passes `now_ms`
/// and persists the [`GuessCounter`] it gets back, keyed by controller public
/// key and session — which is what lets the platform survive a restart without
/// the core knowing where anything is stored.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct GuessPolicy {
    pub window_ms: i64,
    pub threshold: u32,
    pub base_lockout_ms: i64,
    pub max_lockout_ms: i64,
}

impl Default for GuessPolicy {
    fn default() -> Self {
        Self {
            window_ms: 15 * 60 * 1000,
            threshold: 5,
            base_lockout_ms: 60 * 1000,
            max_lockout_ms: 60 * 60 * 1000,
        }
    }
}

#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct GuessCounter {
    #[serde(default)]
    pub failures: u32,
    #[serde(default, rename = "lastFailureMs")]
    pub last_failure_ms: i64,
    #[serde(default, rename = "lockedUntilMs")]
    pub locked_until_ms: i64,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum GuessDecision {
    Allowed,
    Locked { retry_after_ms: i64 },
}

impl GuessDecision {
    pub fn is_allowed(&self) -> bool {
        matches!(self, GuessDecision::Allowed)
    }
}

impl GuessPolicy {
    /// May this controller start another `pake` step 1?
    pub fn check(&self, counter: &GuessCounter, now_ms: i64) -> GuessDecision {
        if counter.locked_until_ms > now_ms {
            GuessDecision::Locked { retry_after_ms: counter.locked_until_ms - now_ms }
        } else {
            GuessDecision::Allowed
        }
    }

    /// The host rejected a confirmation. Failures are forgotten once the
    /// controller has stayed quiet for a whole window — measured from the end of
    /// any lockout it is serving, so that waiting out a 32-minute lockout does
    /// not also wipe the count that earned it.
    pub fn record_failure(&self, counter: &GuessCounter, now_ms: i64) -> GuessCounter {
        let quiet_since = counter.last_failure_ms.max(counter.locked_until_ms);
        let expired =
            counter.failures > 0 && now_ms.saturating_sub(quiet_since) > self.window_ms;
        let failures = if expired { 1 } else { counter.failures.saturating_add(1) };
        let locked_until_ms = if failures >= self.threshold {
            now_ms.saturating_add(self.lockout_ms(failures))
        } else {
            counter.locked_until_ms
        };
        GuessCounter { failures, last_failure_ms: now_ms, locked_until_ms }
    }

    /// The exchange completed. The controller is trusted from here.
    pub fn record_success(&self, _counter: &GuessCounter) -> GuessCounter {
        GuessCounter::default()
    }

    fn lockout_ms(&self, failures: u32) -> i64 {
        let doublings = failures.saturating_sub(self.threshold);
        let factor = 1i64.checked_shl(doublings).unwrap_or(i64::MAX);
        self.base_lockout_ms
            .checked_mul(factor)
            .unwrap_or(i64::MAX)
            .min(self.max_lockout_ms)
    }
}

#[cfg(test)]
impl PakeExchange {
    fn with_seed(mut self, seed: u8) -> Self {
        self.test_seed = Some(seed);
        self
    }
}

#[cfg(test)]
mod tests;
