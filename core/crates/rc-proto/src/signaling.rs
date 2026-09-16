//! Signaling payloads — surface 1, client <-> `rc-signal`. PROTOCOL.md §2.

use serde::{Deserialize, Serialize};

use crate::consts::ALG_ARGON2ID;

/// §2.1. Pushed unsolicited on connect and after `register_ok`.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Challenge {
    /// base64 of 32 random bytes. Single-use, valid 20 s.
    pub nonce: String,
    #[serde(rename = "serverTime")]
    pub server_time: i64,
}

/// §2.3. The Argon2id verifier for an access code.
///
/// The plaintext code is deliberately absent: it never leaves the device that
/// owns it, except inside `connect_req` from the peer trying to connect.
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

/// Why a [`CodeVerifier`] is structurally unacceptable. These are the server's
/// own accepted ranges (§2.3) restated so a bad verifier is caught before it
/// costs a round trip.
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
    /// Recommended parameters from §2.3.
    pub const REC_TIME: u32 = 3;
    pub const REC_MEM_KIB: u32 = 65536;
    pub const REC_PAR: u8 = 1;
    pub const REC_LEN: u32 = 32;

    /// Structural sanity only — this does not verify the hash.
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

/// §2.2. Idempotent per pubkey: re-registering a known key returns the existing
/// `deviceId` and leaves the stored access code untouched.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Register {
    /// base64 DER SPKI, P-256.
    pub pubkey: String,
    /// base64 DER ECDSA-SHA256 over the raw challenge nonce bytes.
    pub sig: String,
    #[serde(default, skip_serializing_if = "String::is_empty")]
    pub label: String,
    pub code: CodeVerifier,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct RegisterOk {
    #[serde(rename = "deviceId")]
    pub device_id: String,
    pub existing: bool,
}

/// §2.4.
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

/// Accept an explicit JSON `null` wherever a defaulted value is expected.
///
/// Go's `encoding/json` writes a nil slice or map as `null`, and several
/// protocol fields have no `omitempty`. Without this, a perfectly legal frame
/// from the reference implementation fails to decode.
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
    /// Go encodes a nil slice as `null`, not `[]`, and `iceServers` has no
    /// `omitempty` — so a server with no TURN configured really does send
    /// `"iceServers": null`. `#[serde(default)]` alone does not cover an
    /// explicit null, only an absent key.
    #[serde(rename = "iceServers", default, deserialize_with = "null_as_default")]
    pub ice_servers: Vec<IceServer>,
    #[serde(rename = "heartbeatSec")]
    pub heartbeat_sec: i32,
    #[serde(rename = "offlineAfterSec")]
    pub offline_after_sec: i32,
    #[serde(rename = "sessionTokenTtlSec")]
    pub session_token_ttl_sec: i32,
    /// Present when this device already has a session server-side. The client
    /// that did not issue it holds no token for it — see the stale-session
    /// handling in the session state machine.
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

/// `watch`, `watch_ok`, `unwatch`, `unwatch_ok` all carry only a device id.
pub type Watch = DeviceRef;
pub type WatchOk = DeviceRef;
pub type Unwatch = DeviceRef;
pub type UnwatchOk = DeviceRef;

/// §2.8.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Presence {
    #[serde(rename = "deviceId")]
    pub device_id: String,
    pub online: bool,
    /// Unix ms, 0 if never seen.
    #[serde(default)]
    pub since: i64,
}

/// §2.9. In v1 this carries the **plaintext** access code. Never log, store or
/// forward it.
///
/// It has no `Debug` derive on purpose: a `{:?}` on this type in a log line is
/// exactly the accident the whole verifier design exists to prevent.
///
/// TODO: delete `access_code` at the v2 bump. A v2 `connect_req` carries only
/// `device_id`; authorisation is the host's entitlement and the code is proved
/// peer to peer by the [`Pake`] exchange.
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
    /// The host's registered `pubkey`, base64 DER SPKI — the key the controller
    /// requires on the host's signed `sdp` (§2.12). Public material; the server
    /// has had it since `register`.
    #[serde(
        rename = "hostPubkey",
        default,
        skip_serializing_if = "String::is_empty"
    )]
    pub host_pubkey: String,
}

/// §2.9. Pushed to the host when a controller connects: everything `connect_ok`
/// carries plus the controller's registered `pubkey`, which the host's guess
/// counter and trusted-controller list are keyed on.
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

/// §2.12. Relayed verbatim; the server never parses or stores `sdp`, and it
/// neither checks nor could produce `sig` — which is exactly why the
/// fingerprints are signed.
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
    /// Every `a=fingerprint` value in `sdp`, de-duplicated, sorted, joined
    /// with `\n`.
    #[serde(default, skip_serializing_if = "String::is_empty")]
    pub fp: String,
    /// The sender's device key, base64 DER SPKI.
    #[serde(default, skip_serializing_if = "String::is_empty")]
    pub pubkey: String,
    /// base64 DER ECDSA-SHA256 over
    /// `"skipperdesk/sdp/v1|" session_id "|" sdp_type "|" fp`.
    #[serde(default, skip_serializing_if = "String::is_empty")]
    pub sig: String,
}

fn is_false(v: &bool) -> bool {
    !*v
}

/// §2.13. Relayed verbatim.
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

/// §2.15. Replaces this device's verifier and kills all of its sessions and
/// tokens. Same shape as [`CodeVerifier`].
pub type RefreshCode = CodeVerifier;

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct RefreshCodeOk {
    #[serde(rename = "deviceId")]
    pub device_id: String,
    #[serde(rename = "updatedAt")]
    pub updated_at: i64,
}

/// §2.17. One opaque message of the peer-to-peer PAKE exchange, relayed by the
/// server exactly as `sdp` and `ice` are: validated for attachment, routed
/// verbatim, never parsed, stored or logged.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Pake {
    #[serde(rename = "sessionId")]
    pub session_id: String,
    pub step: i32,
    /// base64 of the opaque PAKE message.
    pub payload: String,
}

/// §0.1. Every error on every surface is this shape.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct ErrorPayload {
    /// Machine-readable, from §7. Branch on this, never on `message`.
    pub code: String,
    pub message: String,
    #[serde(
        rename = "retryAfterSec",
        default,
        skip_serializing_if = "is_zero_i32"
    )]
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
