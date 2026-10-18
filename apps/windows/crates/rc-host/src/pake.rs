//! The host's half of the §2.17 access-code exchange, mirroring
//! `SessionPake.swift`. The SPAKE2 itself, the key schedule and both guess
//! budgets are `rc_identity`; what lives here is the part that is orchestration
//! rather than crypto:
//!
//! * the exchange belongs to **one** `sessionId`, and a frame for any other is
//!   dropped — a new `session_start` abandons the old exchange;
//! * step 1's key prefix must be the `controllerPubkey` `session_start`
//!   named, checked *before* step 2 is built;
//! * the guess is charged to both budgets **before** step 2 leaves the host and
//!   withdrawn only when step 3 verifies, so a timeout, a `bye`, a replaced
//!   session or a crash has already been counted;
//! * a failed persist of that charge **refuses the exchange** rather than
//!   running it uncounted, because an uncounted guess is an unlimited one.

use std::collections::BTreeMap;

use rc_identity::ledger::{self, HOST_KEY};
use rc_identity::pake::{
    GuessCounter, GuessLedger, PakeError, PakeExchange, PakeMessage, STEP_CONTROLLER_CONFIRM,
    STEP_CONTROLLER_START,
};
use rc_identity::sdp::MAC_KEY_LEN;
use rc_proto::consts::bye;

use crate::secrets::{SecretAccount, SecretError, SecretStore};

/// §2.17: an exchange that has not completed within 10 s of step 1 is over.
pub const EXCHANGE_TIMEOUT_MS: i64 = 10_000;

#[derive(Debug, thiserror::Error)]
pub enum ExchangeError {
    #[error("{0}")]
    Pake(#[from] PakeError),
    #[error("session_start carried no usable controller key")]
    NoControllerKey,
    #[error("the controller key in step 1 is not the one session_start named")]
    KeyNotAnnounced,
    #[error("access-code attempts are locked out for another {0}s")]
    LockedOut(i64),
    #[error("the exchange timed out")]
    TimedOut,
    #[error("{0}")]
    Storage(#[from] SecretError),
}

impl ExchangeError {
    /// Which §2.14 reason ends the session. `auth_failed` is about the *code*:
    /// a confirmation that did not verify, a key that is not the announced one,
    /// or a lockout served without running SPAKE2 at all. Everything else — a
    /// malformed payload, a step out of order, the timeout — is `failed`.
    pub fn bye_reason(&self) -> &'static str {
        let authentication = match self {
            Self::Pake(e) => e.is_authentication(),
            Self::NoControllerKey | Self::KeyNotAnnounced | Self::LockedOut(_) => true,
            Self::TimedOut | Self::Storage(_) => false,
        };
        match authentication {
            true => bye::AUTH_FAILED,
            false => bye::FAILED,
        }
    }
}

/// The host's persisted per-controller counters, keyed by canonical device key.
pub struct GuessStore<'a> {
    secrets: &'a SecretStore,
}

impl<'a> GuessStore<'a> {
    pub fn new(secrets: &'a SecretStore) -> Self {
        Self { secrets }
    }

    fn counters(&self) -> Result<BTreeMap<String, GuessCounter>, SecretError> {
        self.secrets.map(SecretAccount::GuessCounters)
    }

    pub fn ledger(&self, controller_pubkey: &str) -> Result<GuessLedger, ExchangeError> {
        let key = ledger::controller_key(controller_pubkey)
            .map_err(|_| ExchangeError::NoControllerKey)?;
        let counters = self.counters()?;
        Ok(GuessLedger {
            controller: counters.get(&key).cloned().unwrap_or_default(),
            host: counters.get(HOST_KEY).cloned().unwrap_or_default(),
        })
    }

    pub fn save(
        &self,
        ledger: &GuessLedger,
        controller_pubkey: &str,
        now_ms: i64,
    ) -> Result<(), ExchangeError> {
        let key = ledger::controller_key(controller_pubkey)
            .map_err(|_| ExchangeError::NoControllerKey)?;
        let mut counters = self.counters()?;
        counters.insert(key, ledger.controller.clone());
        counters.insert(HOST_KEY.to_string(), ledger.host.clone());
        self.secrets
            .save(SecretAccount::GuessCounters, &ledger::prune(counters, now_ms))?;
        Ok(())
    }
}

/// One session's exchange. Built on `session_start`, dropped with the session.
pub struct HostExchange {
    session_id: String,
    controller_pubkey: String,
    exchange: PakeExchange,
    started_at_ms: i64,
    complete: bool,
}

impl HostExchange {
    /// Refuses before any SPAKE2 runs when either budget is spent, which is
    /// what makes a lockout free for the host (§2.17: no step 2, no guess).
    pub fn arm(
        guesses: &GuessStore<'_>,
        access_code: &str,
        host_device_id: &str,
        session_id: &str,
        own_pubkey: &str,
        controller_pubkey: &str,
        now_ms: i64,
    ) -> Result<Self, ExchangeError> {
        if controller_pubkey.is_empty() {
            return Err(ExchangeError::NoControllerKey);
        }
        let admitted = guesses.ledger(controller_pubkey)?.admit(now_ms);
        if let rc_identity::pake::GuessDecision::Locked { retry_after_ms } = admitted {
            return Err(ExchangeError::LockedOut(retry_after_ms.div_euclid(1000) + 1));
        }
        Ok(Self {
            session_id: session_id.to_string(),
            controller_pubkey: controller_pubkey.to_string(),
            exchange: PakeExchange::host(access_code, host_device_id, session_id, own_pubkey)?,
            started_at_ms: now_ms,
            complete: false,
        })
    }

    pub fn session_id(&self) -> &str {
        &self.session_id
    }

    pub fn controller_pubkey(&self) -> &str {
        &self.controller_pubkey
    }

    pub fn is_complete(&self) -> bool {
        self.complete
    }

    pub fn timed_out(&self, now_ms: i64) -> bool {
        !self.complete && now_ms.saturating_sub(self.started_at_ms) >= EXCHANGE_TIMEOUT_MS
    }

    /// The key that MACs every `sdp` of this session (§2.12).
    pub fn sdp_mac_key(&self) -> Result<[u8; MAC_KEY_LEN], PakeError> {
        self.exchange.sdp_mac_key()
    }

    /// Takes one relayed frame and returns what to send back, if anything.
    ///
    /// Step 2 is where the guess is spent, so the order is fixed: check the
    /// announced key, re-check both budgets, persist the charge, and only then
    /// hand the confirmation out.
    pub fn step(
        &mut self,
        guesses: &GuessStore<'_>,
        frame: &PakeMessage,
        now_ms: i64,
    ) -> Result<Option<PakeMessage>, ExchangeError> {
        if self.timed_out(now_ms) {
            return Err(ExchangeError::TimedOut);
        }
        match frame.step {
            STEP_CONTROLLER_START => self.reply(guesses, frame, now_ms).map(Some),
            STEP_CONTROLLER_CONFIRM => {
                self.exchange.step(Some(frame))?;
                self.complete = true;
                let ledger = guesses.ledger(&self.controller_pubkey)?.confirmed();
                guesses.save(&ledger, &self.controller_pubkey, now_ms)?;
                Ok(None)
            }
            step => Err(PakeError::UnexpectedStep {
                got: step,
                expected: STEP_CONTROLLER_START,
            }
            .into()),
        }
    }

    fn reply(
        &mut self,
        guesses: &GuessStore<'_>,
        frame: &PakeMessage,
        now_ms: i64,
    ) -> Result<PakeMessage, ExchangeError> {
        let reply = self.exchange.step(Some(frame))?.ok_or(PakeError::BadPayload)?;
        if !rc_identity::signing::same_public_key(
            self.exchange.peer_public_key_base64().as_str(),
            &self.controller_pubkey,
        ) {
            return Err(ExchangeError::KeyNotAnnounced);
        }
        let ledger = guesses.ledger(&self.controller_pubkey)?;
        if let rc_identity::pake::GuessDecision::Locked { retry_after_ms } = ledger.admit(now_ms) {
            return Err(ExchangeError::LockedOut(retry_after_ms.div_euclid(1000) + 1));
        }
        guesses.save(&ledger.reply_sent(now_ms), &self.controller_pubkey, now_ms)?;
        Ok(reply)
    }
}

#[cfg(test)]
mod tests;
