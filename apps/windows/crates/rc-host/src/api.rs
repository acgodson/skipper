//! The account API (protocol/API.md), mirroring `APIClient.swift`.
//!
//! Three things this client does deliberately differently from a naive HTTP
//! wrapper, each because API.md says so:
//!
//! * **No unknown request fields.** The server decodes with
//!   `DisallowUnknownFields`, so every body here is exactly its schema.
//! * **The two credential endpoints are never auto-retried.** A successful
//!   `device/token` or `device/refresh` answer is never stored for replay, so a
//!   transport-level retry with the same `Idempotency-Key` lands as
//!   `409 idempotency_replay_unavailable` (API.md §1.2) — the first attempt's
//!   credential is simply lost. Recovery is a fresh challenge, not a retry.
//! * **`internal` and `unavailable` are retried, and only those.**

use base64::engine::general_purpose::STANDARD as B64;
use base64::Engine;
use rand_core::{OsRng, RngCore};
use rc_proto::ctrl::QualityMode;
use serde::{Deserialize, Serialize};

use crate::backend::BaseUrl;

pub const PLATFORM: &str = "windows";
pub const CLIENT_HEADER: &str = "X-SkipperDesk-Client";
pub const IDEMPOTENCY_HEADER: &str = "Idempotency-Key";

const REQUEST_TIMEOUT: std::time::Duration = std::time::Duration::from_secs(20);
const MAX_INTERNAL_ATTEMPTS: u32 = 3;
const MAX_UNAVAILABLE_ATTEMPTS: u32 = 2;

#[derive(Debug, Clone, PartialEq, Eq, Deserialize)]
pub struct ApiError {
    pub code: String,
    pub message: String,
    #[serde(default)]
    pub reason: String,
    #[serde(default, rename = "retryAfterSec")]
    pub retry_after_sec: i32,
}

#[derive(Debug, thiserror::Error)]
pub enum ApiFailure {
    #[error("{} ({})", .0.message, .0.code)]
    Refused(ApiError),
    #[error("the account service could not be reached: {0}")]
    Transport(String),
    #[error("the account service answered something this build cannot read: {0}")]
    Malformed(String),
}

impl ApiFailure {
    pub fn code(&self) -> &str {
        match self {
            Self::Refused(e) => &e.code,
            Self::Transport(_) => "network",
            Self::Malformed(_) => "internal",
        }
    }

    pub fn reason(&self) -> &str {
        match self {
            Self::Refused(e) => &e.reason,
            _ => "",
        }
    }

    /// API.md §1.1: `unauthenticated` means refresh once and replay;
    /// `forbidden` with `unlinked` or `revoked` means this device was signed
    /// out elsewhere and the stored token must go. `revoked` is not in API.md's
    /// table but the server sends it (`auth.go`), and the Mac handles both.
    pub fn means_signed_out(&self) -> bool {
        self.code() == "forbidden" && matches!(self.reason(), "unlinked" | "revoked")
    }
}

#[derive(Debug, Clone, Deserialize)]
pub struct Challenge {
    /// Standard padded base64 of 32 bytes. Signed as its decoded bytes and
    /// echoed back **byte for byte** as the string that arrived.
    pub nonce: String,
    #[serde(default, rename = "expiresAt")]
    pub expires_at: i64,
}

impl Challenge {
    pub fn raw_nonce(&self) -> Result<Vec<u8>, ApiFailure> {
        let raw = B64
            .decode(self.nonce.as_bytes())
            .map_err(|e| ApiFailure::Malformed(format!("challenge nonce: {e}")))?;
        match raw.len() == rc_identity::signing::NONCE_LEN {
            true => Ok(raw),
            false => Err(ApiFailure::Malformed(format!(
                "a challenge nonce must be {} bytes, got {}",
                rc_identity::signing::NONCE_LEN,
                raw.len()
            ))),
        }
    }
}

#[derive(Debug, Clone, Deserialize)]
pub struct DeviceToken {
    #[serde(rename = "deviceToken")]
    pub device_token: String,
    #[serde(rename = "expiresAt")]
    pub expires_at: i64,
    #[serde(rename = "deviceId")]
    pub device_id: String,
    #[serde(default, rename = "accountId")]
    pub account_id: String,
    /// What the user is shown. The account id never is (DESIGN §4 rule 8).
    #[serde(default, rename = "accountEmail")]
    pub account_email: String,
}

#[derive(Debug, Clone, Deserialize)]
pub struct Concurrency {
    #[serde(default = "one", rename = "maxActivePairs")]
    pub max_active_pairs: i32,
}

fn one() -> i32 {
    1
}

/// An absent `concurrency` object means one pair, not zero. `derive(Default)`
/// would ignore the field's own default and read as "no sessions allowed".
impl Default for Concurrency {
    fn default() -> Self {
        Self {
            max_active_pairs: one(),
        }
    }
}

#[derive(Debug, Clone, Default, Deserialize)]
pub struct Limits {
    /// Open enum; an unknown value resolves to `auto`, never to `sharp`.
    #[serde(default, rename = "maxQuality")]
    pub max_quality: String,
}

/// §4.2. Decoding is lenient on purpose: an open enum must survive a value this
/// build has never heard of, and an absent optional is not a zero.
#[derive(Debug, Clone, Deserialize)]
pub struct Entitlement {
    pub status: String,
    #[serde(default)]
    pub tier: String,
    #[serde(default, rename = "balanceCents")]
    pub balance_cents: Option<i64>,
    #[serde(default, rename = "minutesRemaining")]
    pub minutes_remaining: Option<i64>,
    #[serde(default, rename = "trialEndsAt")]
    pub trial_ends_at: Option<i64>,
    #[serde(default)]
    pub concurrency: Concurrency,
    #[serde(default)]
    pub limits: Limits,
    #[serde(default = "default_refresh", rename = "refreshAfterSec")]
    pub refresh_after_sec: i32,
}

/// `Entitlement.defaultRefreshAfterSec` on the Mac.
pub const DEFAULT_REFRESH_AFTER_SEC: i32 = 60;

fn default_refresh() -> i32 {
    DEFAULT_REFRESH_AFTER_SEC
}

impl Entitlement {
    /// `trial` and `active` are the two that may open a session; an
    /// unrecognised status is treated as `exhausted`, so a value from a newer
    /// backend fails closed.
    pub fn may_connect(&self) -> bool {
        matches!(self.status.as_str(), "trial" | "active")
    }

    /// §4.4: the host is the enforcement point, and a value it does not
    /// recognise clamps to `auto` rather than to the most permissive mode.
    pub fn max_quality(&self) -> QualityMode {
        QualityMode::from_wire(&self.limits.max_quality)
    }
}

#[derive(Debug, Serialize)]
struct ChallengeRequest<'a> {
    #[serde(skip_serializing_if = "Option::is_none")]
    code: Option<&'a str>,
    #[serde(rename = "deviceId", skip_serializing_if = "Option::is_none")]
    device_id: Option<&'a str>,
}

#[derive(Debug, Serialize)]
struct TokenRequest<'a> {
    code: &'a str,
    nonce: &'a str,
    pubkey: &'a str,
    sig: &'a str,
    platform: &'a str,
    #[serde(rename = "hardwareId")]
    hardware_id: &'a str,
    #[serde(skip_serializing_if = "str::is_empty")]
    label: &'a str,
}

#[derive(Debug, Serialize)]
struct RefreshRequest<'a> {
    #[serde(rename = "deviceId")]
    device_id: &'a str,
    pubkey: &'a str,
    nonce: &'a str,
    sig: &'a str,
}

pub struct ApiClient {
    http: reqwest::Client,
    base: BaseUrl,
    client_header: String,
}

impl ApiClient {
    pub fn new(base: BaseUrl, app_version: &str) -> Result<Self, ApiFailure> {
        let http = reqwest::Client::builder()
            .timeout(REQUEST_TIMEOUT)

            .build()
            .map_err(|e| ApiFailure::Transport(e.to_string()))?;
        Ok(Self {
            http,
            base,
            client_header: format!("{PLATFORM}/{app_version}"),
        })
    }

    /// Opaque, client-generated, 16–64 characters (API.md §1.2). A fresh one
    /// per *operation*, never per attempt.
    pub fn idempotency_key() -> String {
        let mut raw = [0u8; 18];
        OsRng.fill_bytes(&mut raw);
        base64::engine::general_purpose::URL_SAFE_NO_PAD.encode(raw)
    }

    async fn send<T: serde::de::DeserializeOwned>(
        &self,
        request: reqwest::RequestBuilder,
        retries: bool,
    ) -> Result<T, ApiFailure> {
        let mut attempt = 0u32;
        loop {
            attempt += 1;
            let attempt_request = request
                .try_clone()
                .ok_or_else(|| ApiFailure::Transport("request body is not replayable".into()))?;
            let outcome = self.once(attempt_request).await;
            let Err(failure) = outcome else { return outcome };
            let ApiFailure::Refused(refused) = &failure else {
                return Err(failure);
            };
            let budget = match refused.code.as_str() {
                "internal" => MAX_INTERNAL_ATTEMPTS,
                "unavailable" => MAX_UNAVAILABLE_ATTEMPTS,
                _ => return Err(failure),
            };
            if !retries || attempt >= budget {
                return Err(failure);
            }
            let wait = match refused.retry_after_sec {
                seconds if seconds > 0 => seconds.min(30) as u64 * 1000,
                _ => u64::from(attempt) * 500,
            };
            tokio::time::sleep(std::time::Duration::from_millis(wait)).await;
        }
    }

    /// An empty body is a 204 with a unit return type.
    async fn once<T: serde::de::DeserializeOwned>(
        &self,
        request: reqwest::RequestBuilder,
    ) -> Result<T, ApiFailure> {
        let response = request
            .header(CLIENT_HEADER, &self.client_header)
            .header(reqwest::header::ACCEPT, "application/json")
            .send()
            .await
            .map_err(|e| ApiFailure::Transport(e.to_string()))?;
        let status = response.status();
        let body = response
            .bytes()
            .await
            .map_err(|e| ApiFailure::Transport(e.to_string()))?;
        if !status.is_success() {
            #[derive(Deserialize)]
            struct Envelope {
                error: ApiError,
            }
            let refused = serde_json::from_slice::<Envelope>(&body)
                .map(|e| e.error)
                .unwrap_or_else(|_| ApiError {
                    code: match status.as_u16() {
                        401 => "unauthenticated".into(),
                        403 => "forbidden".into(),
                        404 => "not_found".into(),
                        429 => "rate_limited".into(),
                        500..=599 => "internal".into(),
                        _ => "bad_request".into(),
                    },
                    message: format!("the account service answered {status}"),
                    reason: String::new(),
                    retry_after_sec: 0,
                });
            return Err(ApiFailure::Refused(refused));
        }
        if body.is_empty() {
            return serde_json::from_slice(b"null")
                .map_err(|e| ApiFailure::Malformed(e.to_string()));
        }
        serde_json::from_slice(&body).map_err(|e| ApiFailure::Malformed(e.to_string()))
    }

    fn post(&self, path: &str) -> reqwest::RequestBuilder {
        self.http
            .post(self.base.url(path))
            .header(reqwest::header::CONTENT_TYPE, "application/json; charset=utf-8")
    }

    pub async fn challenge_for_code(&self, code: &str) -> Result<Challenge, ApiFailure> {
        self.send(
            self.post("/v1/auth/device/challenge").json(&ChallengeRequest {
                code: Some(code),
                device_id: None,
            }),
            true,
        )
        .await
    }

    pub async fn challenge_for_device(&self, device_id: &str) -> Result<Challenge, ApiFailure> {
        self.send(
            self.post("/v1/auth/device/challenge").json(&ChallengeRequest {
                code: None,
                device_id: Some(device_id),
            }),
            true,
        )
        .await
    }

    /// The device's first token. `hardware_id` is sent here and nowhere else;
    /// the server keeps only an HMAC of it.
    ///
    /// Not retried: see the module note.
    #[allow(clippy::too_many_arguments)]
    pub async fn device_token(
        &self,
        code: &str,
        link_nonce: &str,
        pubkey: &str,
        signature: &str,
        hardware_id: &str,
        label: &str,
    ) -> Result<DeviceToken, ApiFailure> {
        self.send(
            self.post("/v1/auth/device/token")
                .header(IDEMPOTENCY_HEADER, Self::idempotency_key())
                .json(&TokenRequest {
                    code,
                    nonce: link_nonce,
                    pubkey,
                    sig: signature,
                    platform: PLATFORM,
                    hardware_id,
                    label,
                }),
            false,
        )
        .await
    }

    /// Proves possession of the **private key**, not of the old token, so a
    /// lost token store recovers without the browser. Not retried.
    pub async fn refresh(
        &self,
        device_id: &str,
        challenge: &Challenge,
        pubkey: &str,
        signature: &str,
    ) -> Result<DeviceToken, ApiFailure> {
        self.send(
            self.post("/v1/auth/device/refresh")
                .header(IDEMPOTENCY_HEADER, Self::idempotency_key())
                .json(&RefreshRequest {
                    device_id,
                    pubkey,
                    nonce: &challenge.nonce,
                    sig: signature,
                }),
            false,
        )
        .await
    }

    pub async fn entitlement(&self, device_token: &str) -> Result<Entitlement, ApiFailure> {
        self.send(
            self.http
                .get(self.base.url("/v1/entitlement"))
                .bearer_auth(device_token),
            true,
        )
        .await
    }

    /// Sign out. **Not** `device/revoke`, which only kills the calling token
    /// and leaves the device linked and entitled: this unlinks it, so the next
    /// `connect_req` naming this PC as host is refused `entitlement{unlinked}`.
    pub async fn unlink(&self, device_token: &str, device_id: &str) -> Result<(), ApiFailure> {
        let _: Option<serde_json::Value> = self
            .send(
                self.http
                    .delete(self.base.url(&format!("/v1/devices/{device_id}")))
                    .bearer_auth(device_token)
                    .header(IDEMPOTENCY_HEADER, Self::idempotency_key()),
                true,
            )
            .await?;
        Ok(())
    }
}

#[cfg(test)]
mod tests;
