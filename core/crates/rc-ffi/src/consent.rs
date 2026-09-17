use std::ffi::c_char;

use rc_identity::consent::{ConsentDecision, ConsentLedger};
use serde_json::json;

use crate::optional_text;

const PANICKED: &str = "the consent policy panicked";

unsafe fn ledger_from_json(pointer: *const u8, len: usize) -> Result<ConsentLedger, String> {
    match unsafe { optional_text(pointer, len, "ledger_json") }? {
        None => Ok(ConsentLedger::default()),
        Some(text) if text.trim().is_empty() => Ok(ConsentLedger::default()),
        Some(text) => serde_json::from_str(text).map_err(|e| format!("consent ledger: {e}")),
    }
}

fn decision_json(ledger: &ConsentLedger, decision: ConsentDecision) -> serde_json::Value {
    json!({
        "prompt": decision.should_prompt(),
        "retryAfterMs": decision.retry_after_ms(),
        "ledger": serde_json::to_value(ledger).unwrap_or_else(|_| json!({})),
    })
}

fn respond<F>(pointer: *const u8, len: usize, now_ms: i64, change: F) -> *mut c_char
where
    F: FnOnce(ConsentLedger) -> ConsentLedger,
{
    crate::respond(PANICKED, || {
        let ledger = change(unsafe { ledger_from_json(pointer, len) }?);
        Ok(decision_json(&ledger, ledger.admit(now_ms)))
    })
}

#[no_mangle]
pub unsafe extern "C" fn skipper_consent_admit(
    ledger_json: *const u8,
    ledger_json_len: usize,
    now_ms: i64,
) -> *mut c_char {
    respond(ledger_json, ledger_json_len, now_ms, |ledger| ledger)
}

#[no_mangle]
pub unsafe extern "C" fn skipper_consent_declined(
    ledger_json: *const u8,
    ledger_json_len: usize,
    now_ms: i64,
) -> *mut c_char {
    respond(ledger_json, ledger_json_len, now_ms, |ledger| {
        ledger.declined(now_ms)
    })
}

#[no_mangle]
pub unsafe extern "C" fn skipper_consent_allowed(
    ledger_json: *const u8,
    ledger_json_len: usize,
    now_ms: i64,
) -> *mut c_char {
    respond(ledger_json, ledger_json_len, now_ms, |ledger| {
        ledger.allowed()
    })
}
