use std::collections::BTreeMap;
use std::ffi::c_char;

use rc_identity::consent;
use rc_identity::ledger;
use rc_identity::pake::{GuessCounter, GuessLedger};
use rc_identity::signing;
use serde_json::json;

use crate::pake::ledger_from_json;
use crate::{optional_text, required_text};

const PANICKED: &str = "the consent policy panicked";

fn respond<F>(pointer: *const u8, len: usize, now_ms: i64, change: F) -> *mut c_char
where
    F: FnOnce(GuessLedger) -> GuessLedger,
{
    crate::respond(PANICKED, || {
        let ledger = change(unsafe { ledger_from_json(pointer, len) }?);
        let decision = consent::admit(&ledger, now_ms);
        Ok(json!({
            "prompt": decision.should_prompt(),
            "retryAfterMs": decision.retry_after_ms(),
            "ledger": serde_json::to_value(&ledger).map_err(|e| e.to_string())?,
        }))
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
pub unsafe extern "C" fn skipper_consent_prompted(
    ledger_json: *const u8,
    ledger_json_len: usize,
    now_ms: i64,
) -> *mut c_char {
    respond(ledger_json, ledger_json_len, now_ms, |ledger| {
        consent::prompted(&ledger, now_ms)
    })
}

#[no_mangle]
pub unsafe extern "C" fn skipper_consent_allowed(
    ledger_json: *const u8,
    ledger_json_len: usize,
    now_ms: i64,
) -> *mut c_char {
    respond(ledger_json, ledger_json_len, now_ms, |ledger| {
        consent::allowed(&ledger, now_ms)
    })
}

#[no_mangle]
pub unsafe extern "C" fn skipper_pubkey_canonical(
    pubkey: *const u8,
    pubkey_len: usize,
) -> *mut c_char {
    crate::respond("device key canonicalisation panicked", || {
        let pubkey = unsafe { required_text(pubkey, pubkey_len, "pubkey") }?;
        let key = ledger::controller_key(pubkey).map_err(|e| e.to_string())?;
        Ok(json!({ "key": key, "canonical": key == pubkey }))
    })
}

#[no_mangle]
pub unsafe extern "C" fn skipper_pubkey_fingerprint(
    pubkey: *const u8,
    pubkey_len: usize,
) -> *mut c_char {
    crate::respond("device key fingerprint panicked", || {
        let pubkey = unsafe { required_text(pubkey, pubkey_len, "pubkey") }?;
        let fingerprint = signing::public_key_fingerprint(pubkey).map_err(|e| e.to_string())?;
        Ok(json!({ "fingerprint": fingerprint }))
    })
}

#[no_mangle]
pub unsafe extern "C" fn skipper_ledger_prune(
    counters_json: *const u8,
    counters_json_len: usize,
    now_ms: i64,
) -> *mut c_char {
    crate::respond("ledger pruning panicked", || {
        let counters: BTreeMap<String, GuessCounter> =
            match unsafe { optional_text(counters_json, counters_json_len, "counters_json") }? {
                None => BTreeMap::new(),
                Some(text) => serde_json::from_str(text).map_err(|e| format!("counters: {e}"))?,
            };
        let pruned = ledger::prune(counters, now_ms);
        Ok(json!({ "counters": serde_json::to_value(pruned).map_err(|e| e.to_string())? }))
    })
}
