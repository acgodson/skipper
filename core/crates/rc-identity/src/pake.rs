use base64::engine::general_purpose::STANDARD as B64;
use base64::Engine;
use hkdf::Hkdf;
use hmac::{Hmac, Mac};
use serde::{Deserialize, Serialize};
use sha2::Sha256;
use spake2::{Ed25519Group, Identity, Password, Spake2};
use subtle::ConstantTimeEq;
use zeroize::Zeroize;

pub const STEP_CONTROLLER_START: u32 = 1;
pub const STEP_HOST_REPLY: u32 = 2;
pub const STEP_CONTROLLER_CONFIRM: u32 = 3;

pub const MAX_PAYLOAD_BASE64: usize = rc_session::relay::PAKE_PAYLOAD_MAX_BASE64;
pub const SESSION_KEY_LEN: usize = 32;
pub const CONFIRM_LEN: usize = 32;

/// A DER SPKI P-256 key is 91 bytes; the cap stops a malformed length prefix
/// from making a receiver allocate.
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

impl PakeError {
    /// A wrong access code, as opposed to a broken or malformed exchange.
    pub fn is_authentication(&self) -> bool {
        matches!(self, PakeError::ConfirmationFailed)
    }
}

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
        self.session.zeroize();
        self.controller_confirm.zeroize();
        self.host_confirm.zeroize();
    }
}

/// Drive with [`PakeExchange::step`]: the controller starts by stepping
/// `None`, every other call carries the frame that arrived from the peer.
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
        self.password.zeroize();
    }
}

impl PakeExchange {
    /// `own_public_key_base64` is this device's own `pubkey` (base64 DER SPKI).
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

    /// Empty until the peer's first frame has arrived.
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

    /// The key that MACs every `sdp` of this session (PROTOCOL.md §2.12).
    pub fn sdp_mac_key(&self) -> Result<[u8; crate::sdp::MAC_KEY_LEN], PakeError> {
        let mut session = self.session_key()?;
        let key = crate::sdp::mac_key(&session);
        session.zeroize();
        Ok(key)
    }

    pub fn step(
        &mut self,
        incoming: Option<&PakeMessage>,
    ) -> Result<Option<PakeMessage>, PakeError> {
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

    fn advance(
        &mut self,
        incoming: Option<&PakeMessage>,
    ) -> Result<Option<PakeMessage>, PakeError> {
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
            Err(PakeError::UnexpectedStep {
                got: message.step,
                expected,
            })
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
        Ok(PakeMessage {
            step: STEP_CONTROLLER_CONFIRM,
            payload: controller_confirm,
        })
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
        Ok(PakeMessage {
            step: STEP_HOST_REPLY,
            payload,
        })
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
        state
            .finish(peer_message)
            .map_err(|_| PakeError::BadPeerMessage)
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
    expand(
        &hkdf,
        &format!("{CONTEXT_LABEL} session-key"),
        &mut keys.session,
    );
    expand(
        &hkdf,
        &format!("{CONTEXT_LABEL} confirm {CONTROLLER_IDENTITY}"),
        &mut controller_key,
    );
    expand(
        &hkdf,
        &format!("{CONTEXT_LABEL} confirm {HOST_IDENTITY}"),
        &mut host_key,
    );
    keys.controller_confirm = tag(&controller_key, transcript);
    keys.host_confirm = tag(&host_key, transcript);
    controller_key.zeroize();
    host_key.zeroize();
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
    if bool::from(expected.as_slice().ct_eq(presented)) {
        Ok(())
    } else {
        Err(PakeError::ConfirmationFailed)
    }
}

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

#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct GuessCounter {
    #[serde(default)]
    pub failures: u32,
    #[serde(default, rename = "lastFailureMs")]
    pub last_failure_ms: i64,
    #[serde(default, rename = "lockedUntilMs")]
    pub locked_until_ms: i64,
    #[serde(
        default,
        rename = "failureTimesMs",
        skip_serializing_if = "Vec::is_empty"
    )]
    pub failure_times_ms: Vec<i64>,
    #[serde(
        default,
        rename = "declineTimesMs",
        skip_serializing_if = "Vec::is_empty"
    )]
    pub decline_times_ms: Vec<i64>,
    #[serde(
        default,
        rename = "promptTimesMs",
        skip_serializing_if = "Vec::is_empty"
    )]
    pub prompt_times_ms: Vec<i64>,
}

impl GuessCounter {
    /// The latest moment this counter still says anything about.
    pub fn last_activity_ms(&self) -> i64 {
        [
            &self.failure_times_ms,
            &self.decline_times_ms,
            &self.prompt_times_ms,
        ]
        .into_iter()
        .flatten()
        .copied()
        .chain([self.last_failure_ms, self.locked_until_ms])
        .max()
        .unwrap_or(0)
    }

    fn with_guesses(&self, guesses: GuessCounter) -> GuessCounter {
        GuessCounter {
            decline_times_ms: self.decline_times_ms.clone(),
            prompt_times_ms: self.prompt_times_ms.clone(),
            ..guesses
        }
    }
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
    pub fn check(&self, counter: &GuessCounter, now_ms: i64) -> GuessDecision {
        if counter.locked_until_ms > now_ms {
            GuessDecision::Locked {
                retry_after_ms: counter.locked_until_ms - now_ms,
            }
        } else {
            GuessDecision::Allowed
        }
    }

    pub fn record_failure(&self, counter: &GuessCounter, now_ms: i64) -> GuessCounter {
        let quiet_since = counter.last_failure_ms.max(counter.locked_until_ms);
        let expired = counter.failures > 0 && now_ms.saturating_sub(quiet_since) > self.window_ms;
        let failures = if expired {
            1
        } else {
            counter.failures.saturating_add(1)
        };
        let locked_until_ms = if failures >= self.threshold {
            now_ms.saturating_add(self.lockout_ms(failures))
        } else {
            counter.locked_until_ms
        };
        counter.with_guesses(GuessCounter {
            failures,
            last_failure_ms: now_ms,
            locked_until_ms,
            ..GuessCounter::default()
        })
    }

    pub fn record_success(&self, counter: &GuessCounter) -> GuessCounter {
        counter.with_guesses(GuessCounter::default())
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

/// The host-wide budget: failures from every controller together, so a relay
/// that invents a fresh controller key per guess still runs out.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct HostGuessBudget {
    pub window_ms: i64,
    pub max_failures: usize,
}

impl Default for HostGuessBudget {
    fn default() -> Self {
        Self {
            window_ms: 60 * 60 * 1000,
            max_failures: 20,
        }
    }
}

impl HostGuessBudget {
    fn recent(&self, times: &[i64], now_ms: i64) -> Vec<i64> {
        let since = now_ms.saturating_sub(self.window_ms);
        let mut recent: Vec<i64> = times.iter().copied().filter(|&at| at > since).collect();
        recent.sort_unstable();
        let excess = recent.len().saturating_sub(self.max_failures);
        recent.drain(..excess);
        recent
    }

    fn counter(&self, recent: Vec<i64>, last_failure_ms: i64) -> GuessCounter {
        let locked_until_ms = match recent.len() >= self.max_failures {
            true => recent[0].saturating_add(self.window_ms),
            false => 0,
        };
        GuessCounter {
            failures: recent.len() as u32,
            last_failure_ms,
            locked_until_ms,
            failure_times_ms: recent,
            ..GuessCounter::default()
        }
    }

    pub fn check(&self, counter: &GuessCounter, now_ms: i64) -> GuessDecision {
        let recent = self.recent(&counter.failure_times_ms, now_ms);
        match recent.len() >= self.max_failures {
            true => GuessDecision::Locked {
                retry_after_ms: recent[0].saturating_add(self.window_ms) - now_ms,
            },
            false => GuessDecision::Allowed,
        }
    }

    pub fn record_failure(&self, counter: &GuessCounter, now_ms: i64) -> GuessCounter {
        let mut times = counter.failure_times_ms.clone();
        times.push(now_ms);
        counter.with_guesses(self.counter(self.recent(&times, now_ms), now_ms))
    }

    /// Withdraws the most recent failure: the one recorded for an exchange
    /// that has now verified.
    pub fn withdraw_latest(&self, counter: &GuessCounter) -> GuessCounter {
        let mut times = counter.failure_times_ms.clone();
        times.sort_unstable();
        times.pop();
        counter.with_guesses(self.counter(times, counter.last_failure_ms))
    }
}

/// Both of the host's counters for one exchange. A failure is recorded in
/// both **before** step 2 leaves the host and withdrawn only when step 3
/// verifies, so an exchange that ends any other way — timeout, `bye`, a new
/// `session_start`, a crash — has already been counted.
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct GuessLedger {
    #[serde(default)]
    pub controller: GuessCounter,
    #[serde(default)]
    pub host: GuessCounter,
}

impl GuessLedger {
    pub fn admit(&self, now_ms: i64) -> GuessDecision {
        let decisions = [
            GuessPolicy::default().check(&self.controller, now_ms),
            HostGuessBudget::default().check(&self.host, now_ms),
        ];
        decisions
            .into_iter()
            .filter_map(|decision| match decision {
                GuessDecision::Locked { retry_after_ms } => Some(retry_after_ms),
                GuessDecision::Allowed => None,
            })
            .max()
            .map_or(GuessDecision::Allowed, |retry_after_ms| {
                GuessDecision::Locked { retry_after_ms }
            })
    }

    pub fn reply_sent(&self, now_ms: i64) -> Self {
        Self {
            controller: GuessPolicy::default().record_failure(&self.controller, now_ms),
            host: HostGuessBudget::default().record_failure(&self.host, now_ms),
        }
    }

    pub fn confirmed(&self) -> Self {
        Self {
            controller: GuessPolicy::default().record_success(&self.controller),
            host: HostGuessBudget::default().withdraw_latest(&self.host),
        }
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
