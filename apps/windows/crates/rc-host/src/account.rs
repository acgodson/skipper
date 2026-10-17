//! Browser sign-in and the device token, mirroring `AccountLinker.swift`.
//!
//! The nonce is what binds the browser leg to this process: it is generated
//! here, never persisted, sent to the website as a query parameter, echoed back
//! in the `skipperdesk://link` return, and compared in constant time. The
//! server independently binds it, storing only `SHA-256(nonce)` against the
//! one-time code — so a code that reaches the wrong process is useless.
//!
//! The access code and the device token are never logged and never put in a
//! URL. The only secret this file writes to disk is the token record, through
//! [`crate::SecretStore`].

use base64::engine::general_purpose::URL_SAFE_NO_PAD as B64URL;
use base64::Engine;
use rand_core::{OsRng, RngCore};
use serde::{Deserialize, Serialize};
use subtle::ConstantTimeEq;

use crate::api::{ApiClient, ApiFailure, DeviceToken, Entitlement, PLATFORM};
use crate::backend::BaseUrl;
use crate::secrets::{SecretAccount, SecretError, SecretStore};

/// `skipperdesk://link` — scheme and authority, both checked.
pub const CALLBACK_SCHEME: &str = "skipperdesk";
pub const CALLBACK_HOST: &str = "link";

/// 32 bytes, base64url, unpadded — 43 characters, which is the shape the
/// website's own pattern accepts.
pub const NONCE_BYTES: usize = 32;

/// How long this process waits for the browser. It bounds only the wait: the
/// security is the nonce binding, the pubkey equality check the server makes,
/// and the single-use 120-second code it mints after sign-in.
pub const ATTEMPT_LIFETIME_MS: i64 = 15 * 60 * 1000;

/// Refresh when less than this is left, and once on any `401`.
pub const REFRESH_WINDOW_MS: i64 = 7 * 24 * 60 * 60 * 1000;

/// One in-flight sign-in. Memory only: a persisted nonce would let a code
/// captured now be redeemed after a restart.
#[derive(Debug, Clone)]
pub struct LinkAttempt {
    nonce: String,
    started_at_ms: i64,
}

impl LinkAttempt {
    pub fn begin(now_ms: i64) -> Self {
        let mut raw = [0u8; NONCE_BYTES];
        OsRng.fill_bytes(&mut raw);
        Self {
            nonce: B64URL.encode(raw),
            started_at_ms: now_ms,
        }
    }

    pub fn nonce(&self) -> &str {
        &self.nonce
    }

    /// `<web base>/link?nonce=&device=&platform=windows`.
    ///
    /// `platform=windows` is accepted by the production page: it validates the
    /// value against `/^[a-z][a-z0-9]{1,15}$/` and defaults to `macos` only
    /// when the parameter is absent. The value the *device record* ends up with
    /// comes from the token request, not from this URL, so both say `windows`.
    pub fn sign_in_url(&self, web: &BaseUrl, pubkey: &str) -> String {
        format!(
            "{}/link?nonce={}&device={}&platform={PLATFORM}",
            web.origin(),
            encode_query(&self.nonce),
            encode_query(pubkey),
        )
    }
}

/// Percent-encodes everything that is not unreserved. The device key is
/// standard base64, so `+`, `/` and `=` must all survive the round trip.
fn encode_query(value: &str) -> String {
    let mut out = String::with_capacity(value.len());
    for byte in value.bytes() {
        match byte {
            b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'-' | b'_' | b'.' | b'~' => {
                out.push(byte as char)
            }
            other => out.push_str(&format!("%{other:02X}")),
        }
    }
    out
}

fn decode_query(value: &str) -> Option<String> {
    let bytes = value.as_bytes();
    let mut out = Vec::with_capacity(bytes.len());
    let mut index = 0;
    while index < bytes.len() {
        match bytes[index] {
            b'%' => {
                let hex = bytes.get(index + 1..index + 3)?;
                let hex = std::str::from_utf8(hex).ok()?;
                out.push(u8::from_str_radix(hex, 16).ok()?);
                index += 3;
            }
            b'+' => {
                out.push(b' ');
                index += 1;
            }
            byte => {
                out.push(byte);
                index += 1;
            }
        }
    }
    String::from_utf8(out).ok()
}

/// What a `skipperdesk://` URL turned out to be. The order matters: a URL that
/// is not ours is not an error to report, and a nonce mismatch abandons the
/// whole attempt rather than retrying.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Verdict {
    NotOurs,
    NoAttempt,
    Expired,
    NonceMismatch,
    MissingCode,
    Accepted { code: String },
}

pub fn callback_verdict(url: &str, attempt: Option<&LinkAttempt>, now_ms: i64) -> Verdict {
    let Some(rest) = url.strip_prefix(&format!("{CALLBACK_SCHEME}://")) else {
        return Verdict::NotOurs;
    };
    let (authority, query) = match rest.split_once('?') {
        Some((authority, query)) => (authority, query),
        None => (rest, ""),
    };
    if authority.trim_end_matches('/') != CALLBACK_HOST {
        return Verdict::NotOurs;
    }
    let Some(attempt) = attempt else {
        return Verdict::NoAttempt;
    };
    if now_ms.saturating_sub(attempt.started_at_ms) > ATTEMPT_LIFETIME_MS {
        return Verdict::Expired;
    }
    let mut code = String::new();
    let mut nonce = String::new();
    for pair in query.split('&') {
        let Some((name, value)) = pair.split_once('=') else { continue };
        let Some(value) = decode_query(value) else { continue };
        match name {
            "code" => code = value,
            "nonce" => nonce = value,
            _ => {}
        }
    }
    // Constant time, and length-checked first so the comparison itself cannot
    // leak the length.
    let matches = nonce.len() == attempt.nonce.len()
        && bool::from(nonce.as_bytes().ct_eq(attempt.nonce.as_bytes()));
    if !matches {
        return Verdict::NonceMismatch;
    }
    if code.is_empty() {
        return Verdict::MissingCode;
    }
    Verdict::Accepted { code }
}

/// What is stored, sealed, for the device token. `account_email` is here
/// because it is what the user is shown; `account_id` is never rendered.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct TokenRecord {
    #[serde(rename = "deviceToken")]
    pub device_token: String,
    #[serde(rename = "deviceId")]
    pub device_id: String,
    #[serde(default, rename = "accountId")]
    pub account_id: String,
    #[serde(default, rename = "accountEmail")]
    pub account_email: String,
    #[serde(rename = "expiresAtMs")]
    pub expires_at_ms: i64,
}

impl TokenRecord {
    pub fn needs_refresh(&self, now_ms: i64) -> bool {
        self.expires_at_ms.saturating_sub(now_ms) < REFRESH_WINDOW_MS
    }
}

impl From<DeviceToken> for TokenRecord {
    fn from(granted: DeviceToken) -> Self {
        Self {
            device_token: granted.device_token,
            device_id: granted.device_id,
            account_id: granted.account_id,
            account_email: granted.account_email,
            expires_at_ms: granted.expires_at,
        }
    }
}

/// A sign-out the server has not confirmed yet. Retried at every launch and
/// before any new sign-in, so a device is never left linked because the network
/// was down when its owner signed out.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct PendingUnlink {
    #[serde(rename = "deviceId")]
    pub device_id: String,
    #[serde(rename = "deviceToken")]
    pub device_token: String,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum AccountState {
    Unlinked,
    Linking,
    Linked { email: String },
}

pub struct Account<'a> {
    api: ApiClient,
    secrets: &'a SecretStore,
    key: &'a rc_identity::DeviceKey,
    label: String,
    hardware_id: String,
    attempt: Option<LinkAttempt>,
    entitlement: Option<(Entitlement, i64)>,
}

impl<'a> Account<'a> {
    pub fn new(
        api: ApiClient,
        secrets: &'a SecretStore,
        key: &'a rc_identity::DeviceKey,
        label: String,
        hardware_id: String,
    ) -> Self {
        Self {
            api,
            secrets,
            key,
            label,
            hardware_id,
            attempt: None,
            entitlement: None,
        }
    }

    pub fn stored_token(&self) -> Result<Option<TokenRecord>, SecretError> {
        self.secrets.load(SecretAccount::DeviceToken)
    }

    pub fn state(&self) -> AccountState {
        if self.attempt.is_some() {
            return AccountState::Linking;
        }
        match self.stored_token() {
            Ok(Some(record)) => AccountState::Linked {
                email: record.account_email,
            },
            _ => AccountState::Unlinked,
        }
    }

    /// Opens the browser leg. Any sign-out that is still owed is finished
    /// first, so a new account cannot be linked over an old one that the
    /// backend still thinks is live.
    pub async fn begin_sign_in(&mut self, web: &BaseUrl, now_ms: i64) -> Result<String, String> {
        self.retry_pending_unlink().await;
        let attempt = LinkAttempt::begin(now_ms);
        let url = attempt.sign_in_url(web, &self.key.public_key_spki_base64());
        self.attempt = Some(attempt);
        Ok(url)
    }

    /// Redeems the one-time code the browser returned. `device_id` must already
    /// exist: this call never mints one, and a key the registry does not know
    /// is `bad_request{unregistered}` with the code left unspent, so signalling
    /// `register` comes first.
    pub async fn complete_sign_in(
        &mut self,
        url: &str,
        now_ms: i64,
    ) -> Result<TokenRecord, String> {
        let verdict = callback_verdict(url, self.attempt.as_ref(), now_ms);
        let code = match verdict {
            Verdict::Accepted { code } => code,
            Verdict::NotOurs => return Err("that link was not meant for SkipperDesk".into()),
            Verdict::NoAttempt => {
                return Err("no sign-in was waiting for that link; choose Sign in again".into())
            }
            Verdict::Expired => {
                self.attempt = None;
                return Err("that sign-in took too long; choose Sign in again".into());
            }
            Verdict::NonceMismatch => {
                self.attempt = None;
                return Err("that sign-in link did not belong to this request".into());
            }
            Verdict::MissingCode => return Err("that sign-in link carried no code".into()),
        };
        self.attempt = None;

        let challenge = self
            .api
            .challenge_for_code(&code)
            .await
            .map_err(|e| e.to_string())?;
        let nonce = challenge.raw_nonce().map_err(|e| e.to_string())?;
        let signature = self
            .key
            .sign(rc_identity::SigningPurpose::ApiChallenge, &nonce)
            .map_err(|e| e.to_string())?;
        let granted = self
            .api
            .device_token(
                &code,
                &challenge,
                &self.key.public_key_spki_base64(),
                &signature,
                &self.hardware_id,
                &self.label,
            )
            .await
            .map_err(|e| e.to_string())?;
        self.store(granted.into())
    }

    /// §1.5. Proves the private key, so this recovers a lost token without the
    /// browser — but not a device that was unlinked, which needs the whole flow
    /// again.
    pub async fn refresh(&mut self, record: &TokenRecord) -> Result<TokenRecord, String> {
        let challenge = self
            .api
            .challenge_for_device(&record.device_id)
            .await
            .map_err(|e| e.to_string())?;
        let nonce = challenge.raw_nonce().map_err(|e| e.to_string())?;
        let signature = self
            .key
            .sign(rc_identity::SigningPurpose::ApiChallenge, &nonce)
            .map_err(|e| e.to_string())?;
        let granted = self
            .api
            .refresh(
                &record.device_id,
                &challenge,
                &self.key.public_key_spki_base64(),
                &signature,
            )
            .await
            .map_err(|e| self.on_failure(e))?;
        self.store(granted.into())
    }

    /// The cached entitlement, re-fetched no more often than the answer itself
    /// asked for. That cap is what keeps this inside 60 requests an hour.
    pub async fn entitlement(&mut self, now_ms: i64, force: bool) -> Option<&Entitlement> {
        let fresh = self.entitlement.as_ref().is_some_and(|(value, fetched)| {
            now_ms.saturating_sub(*fetched) < i64::from(value.refresh_after_sec) * 1000
        });
        if fresh && !force {
            return self.entitlement.as_ref().map(|(value, _)| value);
        }
        let token = self.stored_token().ok().flatten()?;
        match self.api.entitlement(&token.device_token).await {
            Ok(value) => {
                self.entitlement = Some((value, now_ms));
            }
            Err(e) => {
                eprintln!("rc-host: the account's entitlement could not be read: {e}");
                let _ = self.on_failure(e);
            }
        }
        self.entitlement.as_ref().map(|(value, _)| value)
    }

    /// Sign out: `DELETE /v1/devices/{id}`, which unlinks. Local state is
    /// cleared only once the server has confirmed; until then the intent is
    /// recorded so it is retried.
    pub async fn sign_out(&mut self) -> Result<(), String> {
        let Some(record) = self.stored_token().map_err(|e| e.to_string())? else {
            return Ok(());
        };
        let pending = PendingUnlink {
            device_id: record.device_id.clone(),
            device_token: record.device_token.clone(),
        };
        self.secrets
            .save(SecretAccount::PendingUnlink, &pending)
            .map_err(|e| e.to_string())?;
        match self.api.unlink(&record.device_token, &record.device_id).await {
            Ok(()) => self.finish_unlink(),
            Err(e) if unlink_is_done(&e) => self.finish_unlink(),
            Err(e) => Err(e.to_string()),
        }
    }

    async fn retry_pending_unlink(&mut self) {
        let Ok(Some(pending)) = self.secrets.load::<PendingUnlink>(SecretAccount::PendingUnlink)
        else {
            return;
        };
        match self
            .api
            .unlink(&pending.device_token, &pending.device_id)
            .await
        {
            Ok(()) => {
                let _ = self.finish_unlink();
            }
            Err(e) if unlink_is_done(&e) => {
                let _ = self.finish_unlink();
            }
            Err(e) => eprintln!("rc-host: a pending sign-out is still owed: {e}"),
        }
    }

    fn finish_unlink(&mut self) -> Result<(), String> {
        self.entitlement = None;
        for account in [SecretAccount::DeviceToken, SecretAccount::PendingUnlink] {
            self.secrets.remove(account).map_err(|e| e.to_string())?;
        }
        Ok(())
    }

    fn store(&mut self, record: TokenRecord) -> Result<TokenRecord, String> {
        // A grant that is not written is one the user has to repeat in the
        // browser, so the failure is reported rather than swallowed.
        self.secrets
            .save(SecretAccount::DeviceToken, &record)
            .map_err(|e| e.to_string())?;
        Ok(record)
    }

    /// A device the backend has unlinked or revoked keeps no token: holding one
    /// would mean retrying with a credential that can never work again.
    fn on_failure(&mut self, failure: ApiFailure) -> String {
        if failure.code() == "unauthenticated" || failure.means_signed_out() {
            self.entitlement = None;
            if let Err(e) = self.secrets.remove(SecretAccount::DeviceToken) {
                eprintln!("rc-host: {e}");
            }
        }
        failure.to_string()
    }
}

/// An unlink that cannot be completed because there is nothing left to unlink
/// has, in substance, completed.
fn unlink_is_done(failure: &ApiFailure) -> bool {
    matches!(failure.code(), "unauthenticated" | "not_found") || failure.means_signed_out()
}

#[cfg(test)]
mod tests;
