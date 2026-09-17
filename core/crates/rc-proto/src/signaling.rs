use serde::{Deserialize, Serialize};

use crate::consts::ALG_ARGON2ID;

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Challenge {
    /// base64 of 32 random bytes; single-use, valid 20s.
    pub nonce: String,
    #[serde(rename = "serverTime")]
    pub server_time: i64,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct CodeVerifier {
    pub alg: String,
    /// base64, >= 16 bytes.
    pub salt: String,
    /// base64 Argon2id output over the UTF-8 plaintext code.
    pub hash: String,
    pub time: u32,
    #[serde(rename = "memKiB")]
    pub mem_kib: u32,
    pub par: u8,
    pub len: u32,
}

#[derive(Debug, thiserror::Error, PartialEq)]
pub enum VerifierError {
    #[error("code.alg must be {ALG_ARGON2ID:?}")]
    Alg,
    #[error("code.salt and code.hash are required")]
    Missing,
    #[error("code.time out of range 1..10")]
    Time,
    #[error("code.memKiB out of range 8192..262144")]
    MemKiB,
    #[error("code.par out of range 1..4")]
    Par,
    #[error("code.len out of range 16..64")]
    Len,
}

impl CodeVerifier {
    pub const REC_TIME: u32 = 3;
    pub const REC_MEM_KIB: u32 = 65536;
    pub const REC_PAR: u8 = 1;
    pub const REC_LEN: u32 = 32;

    /// Structural sanity only — does not verify the hash.
    pub fn validate(&self) -> Result<(), VerifierError> {
        if self.alg != ALG_ARGON2ID {
            return Err(VerifierError::Alg);
        }
        if self.salt.is_empty() || self.hash.is_empty() {
            return Err(VerifierError::Missing);
        }
        if !(1..=10).contains(&self.time) {
            return Err(VerifierError::Time);
        }
        if !(8192..=262144).contains(&self.mem_kib) {
            return Err(VerifierError::MemKiB);
        }
        if !(1..=4).contains(&self.par) {
            return Err(VerifierError::Par);
        }
        if !(16..=64).contains(&self.len) {
            return Err(VerifierError::Len);
        }
        Ok(())
    }
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Register {
    /// base64 DER SPKI, P-256.
    pub pubkey: String,
    /// base64 DER ECDSA-SHA256 over the raw challenge nonce bytes.
    pub sig: String,
    #[serde(default, skip_serializing_if = "String::is_empty")]
    pub label: String,
    /// The id this key held before the registry lost its record; honoured only when free.
    #[serde(rename = "preferredDeviceId", default, skip_serializing_if = "String::is_empty")]
    pub preferred_device_id: String,
    pub code: CodeVerifier,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct RegisterOk {
    #[serde(rename = "deviceId")]
    pub device_id: String,
    pub existing: bool,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Hello {
    #[serde(rename = "deviceId")]
    pub device_id: String,
    pub pubkey: String,
    pub sig: String,
    /// `host` or `controller`.
    pub role: String,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct IceServer {
    pub urls: Vec<String>,
    #[serde(default, skip_serializing_if = "String::is_empty")]
    pub username: String,
    #[serde(default, skip_serializing_if = "String::is_empty")]
    pub credential: String,
    #[serde(rename = "expiresAt", default, skip_serializing_if = "is_zero_i64")]
    pub expires_at: i64,
}

fn is_zero_i64(v: &i64) -> bool {
    *v == 0
}

fn null_as_default<'de, D, T>(d: D) -> Result<T, D::Error>
where
    D: serde::Deserializer<'de>,
    T: Deserialize<'de> + Default,
{
    Ok(Option::<T>::deserialize(d)?.unwrap_or_default())
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct HelloOk {
    #[serde(rename = "deviceId")]
    pub device_id: String,
    #[serde(rename = "serverTime")]
    pub server_time: i64,
    #[serde(rename = "iceServers", default, deserialize_with = "null_as_default")]
    pub ice_servers: Vec<IceServer>,
    #[serde(rename = "heartbeatSec")]
    pub heartbeat_sec: i32,
    #[serde(rename = "offlineAfterSec")]
    pub offline_after_sec: i32,
    #[serde(rename = "sessionTokenTtlSec")]
    pub session_token_ttl_sec: i32,
    #[serde(
        rename = "activeSessionId",
        default,
        skip_serializing_if = "String::is_empty"
    )]
    pub active_session_id: String,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct HeartbeatOk {
    #[serde(rename = "serverTime")]
    pub server_time: i64,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct DeviceRef {
    #[serde(rename = "deviceId")]
    pub device_id: String,
}

pub type Watch = DeviceRef;
pub type WatchOk = DeviceRef;
pub type Unwatch = DeviceRef;
pub type UnwatchOk = DeviceRef;

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Presence {
    #[serde(rename = "deviceId")]
    pub device_id: String,
    pub online: bool,
    /// Unix ms, 0 if never seen.
    #[serde(default)]
    pub since: i64,
}

/// Carries the plaintext access code. Never logged, stored or forwarded.
///
/// TODO: delete `access_code` at the v2 bump; authorisation moves to the
/// host's entitlement and the code is proved peer to peer by [`Pake`].
#[derive(Clone, PartialEq, Serialize, Deserialize)]
pub struct ConnectReq {
    #[serde(rename = "deviceId")]
    pub device_id: String,
    #[serde(
        rename = "accessCode",
        default,
        skip_serializing_if = "String::is_empty"
    )]
    pub access_code: String,
}

impl std::fmt::Debug for ConnectReq {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("ConnectReq")
            .field("device_id", &self.device_id)
            .field("access_code", &"<redacted>")
            .finish()
    }
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct ConnectOk {
    #[serde(rename = "sessionId")]
    pub session_id: String,
    #[serde(rename = "sessionToken")]
    pub session_token: String,
    #[serde(rename = "expiresAt")]
    pub expires_at: i64,
    #[serde(rename = "ttlSec")]
    pub ttl_sec: i32,
    #[serde(rename = "hostDeviceId")]
    pub host_device_id: String,
    #[serde(rename = "controllerDeviceId")]
    pub controller_device_id: String,
    /// base64 DER SPKI.
    #[serde(
        rename = "hostPubkey",
        default,
        skip_serializing_if = "String::is_empty"
    )]
    pub host_pubkey: String,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct SessionStart {
    #[serde(flatten)]
    pub session: ConnectOk,
    #[serde(
        rename = "controllerPubkey",
        default,
        skip_serializing_if = "String::is_empty"
    )]
    pub controller_pubkey: String,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Resume {
    #[serde(rename = "sessionId")]
    pub session_id: String,
    #[serde(rename = "sessionToken")]
    pub session_token: String,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct ResumeOk {
    #[serde(rename = "sessionId")]
    pub session_id: String,
    /// Rotated on every resume; the token used to make the call is dead after it.
    #[serde(rename = "sessionToken")]
    pub session_token: String,
    #[serde(rename = "expiresAt")]
    pub expires_at: i64,
    #[serde(rename = "ttlSec")]
    pub ttl_sec: i32,
    #[serde(rename = "peerAttached")]
    pub peer_attached: bool,
    pub role: String,
}

pub type Renew = Resume;

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct RenewOk {
    #[serde(rename = "sessionId")]
    pub session_id: String,
    #[serde(rename = "sessionToken")]
    pub session_token: String,
    #[serde(rename = "expiresAt")]
    pub expires_at: i64,
    #[serde(rename = "ttlSec")]
    pub ttl_sec: i32,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct PeerState {
    #[serde(rename = "sessionId")]
    pub session_id: String,
    pub attached: bool,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Sdp {
    #[serde(rename = "sessionId")]
    pub session_id: String,
    /// `offer` | `answer` | `pranswer` | `rollback`.
    #[serde(rename = "sdpType")]
    pub sdp_type: String,
    pub sdp: String,
    #[serde(default, skip_serializing_if = "is_false")]
    pub restart: bool,
    /// Every `a=fingerprint` value in `sdp`, de-duplicated, sorted, joined with `\n`.
    #[serde(default, skip_serializing_if = "String::is_empty")]
    pub fp: String,
    /// base64 DER SPKI.
    #[serde(default, skip_serializing_if = "String::is_empty")]
    pub pubkey: String,
    /// base64 DER ECDSA-SHA256 over `"skipperdesk/sdp/v1|" session_id "|" sdp_type "|" fp`.
    #[serde(default, skip_serializing_if = "String::is_empty")]
    pub sig: String,
    /// v3: base64 HMAC-SHA256 under the PAKE-derived `sdpMacKey`, over the same bytes as `sig`.
    #[serde(default, skip_serializing_if = "String::is_empty")]
    pub mac: String,
}

fn is_false(v: &bool) -> bool {
    !*v
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Ice {
    #[serde(rename = "sessionId")]
    pub session_id: String,
    /// Empty string means end-of-candidates.
    pub candidate: String,
    #[serde(rename = "sdpMid", default, skip_serializing_if = "String::is_empty")]
    pub sdp_mid: String,
    #[serde(rename = "sdpMLineIndex", default, skip_serializing_if = "is_zero_i32")]
    pub sdp_mline_index: i32,
}

fn is_zero_i32(v: &i32) -> bool {
    *v == 0
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Bye {
    #[serde(rename = "sessionId")]
    pub session_id: String,
    pub reason: String,
}

pub type RefreshCode = CodeVerifier;

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct RefreshCodeOk {
    #[serde(rename = "deviceId")]
    pub device_id: String,
    #[serde(rename = "updatedAt")]
    pub updated_at: i64,
}

/// Relayed by the server exactly as `sdp` and `ice`: validated for
/// attachment, routed verbatim, never parsed, stored or logged.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Pake {
    #[serde(rename = "sessionId")]
    pub session_id: String,
    pub step: i32,
    /// base64 of the opaque PAKE message.
    pub payload: String,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct ErrorPayload {
    /// Machine-readable; branch on this, never on `message`.
    pub code: String,
    pub message: String,
    #[serde(rename = "retryAfterSec", default, skip_serializing_if = "is_zero_i32")]
    pub retry_after_sec: i32,
    /// Set when `code` is `entitlement`; see `consts::entitlement`.
    #[serde(default, skip_serializing_if = "String::is_empty")]
    pub reason: String,
}

impl std::fmt::Display for ErrorPayload {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "{}: {}", self.code, self.message)
    }
}

impl std::error::Error for ErrorPayload {}
