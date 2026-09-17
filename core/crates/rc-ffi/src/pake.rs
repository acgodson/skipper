use std::ffi::c_char;
use std::panic::{catch_unwind, AssertUnwindSafe};

use rc_identity::access_code;
use rc_identity::pake::{
    GuessDecision, GuessLedger, PakeExchange, PakeMessage, MAX_PAYLOAD_BASE64,
};
use rc_identity::sdp::MAC_KEY_LEN;
use serde_json::json;

use crate::{optional_text, required_text, FfiError, ROLE_HOST};

const PANICKED: &str = "the pake exchange panicked";
const AUTHENTICATION: &str = "authentication";

pub struct SkipperPake {
    exchange: PakeExchange,
}

fn respond<F>(body: F) -> *mut c_char
where
    F: FnOnce() -> Result<serde_json::Value, FfiError>,
{
    crate::respond(PANICKED, body)
}

#[cfg(test)]
impl SkipperPake {
    pub(crate) fn from_exchange(exchange: PakeExchange) -> Self {
        Self { exchange }
    }
}

pub(crate) unsafe fn sdp_mac_key(pake: *mut SkipperPake) -> Result<[u8; MAC_KEY_LEN], String> {
    let pake = unsafe { pake.as_ref() }.ok_or("an sdp needs the pake handle of its session")?;
    pake.exchange
        .sdp_mac_key()
        .map_err(|_| "an sdp is refused until the access-code exchange completes".to_string())
}

#[no_mangle]
pub unsafe extern "C" fn skipper_pake_new(
    role: i32,
    access_code: *const u8,
    access_code_len: usize,
    device_id: *const u8,
    device_id_len: usize,
    session_id: *const u8,
    session_id_len: usize,
    own_pubkey: *const u8,
    own_pubkey_len: usize,
) -> *mut SkipperPake {
    let built = catch_unwind(AssertUnwindSafe(|| {
        let access_code =
            unsafe { required_text(access_code, access_code_len, "access_code") }.ok()?;
        let device_id = unsafe { required_text(device_id, device_id_len, "device_id") }.ok()?;
        let session_id = unsafe { required_text(session_id, session_id_len, "session_id") }.ok()?;
        let own_pubkey = unsafe { required_text(own_pubkey, own_pubkey_len, "own_pubkey") }.ok()?;
        let exchange = if role == ROLE_HOST {
            PakeExchange::host(access_code, device_id, session_id, own_pubkey)
        } else {
            PakeExchange::controller(access_code, device_id, session_id, own_pubkey)
        }
        .ok()?;
        Some(Box::into_raw(Box::new(SkipperPake { exchange })))
    }));
    built.ok().flatten().unwrap_or(std::ptr::null_mut())
}

#[no_mangle]
pub unsafe extern "C" fn skipper_pake_free(pake: *mut SkipperPake) {
    if pake.is_null() {
        return;
    }
    let _ = catch_unwind(AssertUnwindSafe(|| drop(unsafe { Box::from_raw(pake) })));
}

#[no_mangle]
pub unsafe extern "C" fn skipper_pake_step(
    pake: *mut SkipperPake,
    step: i32,
    payload_base64: *const u8,
    payload_base64_len: usize,
) -> *mut c_char {
    respond(|| {
        let pake = unsafe { pake.as_mut() }.ok_or("pake handle is null")?;
        let payload =
            unsafe { optional_text(payload_base64, payload_base64_len, "payload_base64") }?;
        let incoming = match (step, payload) {
            (0, None) => None,
            (step, Some(payload)) if step > 0 => {
                Some(PakeMessage::from_base64(step as u32, payload).map_err(|e| e.to_string())?)
            }
            _ => return Err("a step above zero must carry a payload".into()),
        };
        let outgoing = pake.exchange.step(incoming.as_ref()).map_err(|error| {
            match error.is_authentication() {
                true => FfiError::with_kind(error.to_string(), AUTHENTICATION),
                false => FfiError::from(error.to_string()),
            }
        })?;
        let outgoing =
            outgoing.map(|message| json!({ "step": message.step, "payload": message.to_base64() }));
        Ok(json!({
            "outgoing": outgoing,
            "complete": pake.exchange.is_complete(),
            "peerPubkey": pake.exchange.peer_public_key_base64(),
        }))
    })
}

#[no_mangle]
pub extern "C" fn skipper_pake_max_payload_base64() -> i32 {
    MAX_PAYLOAD_BASE64 as i32
}

unsafe fn ledger_from_json(pointer: *const u8, len: usize) -> Result<GuessLedger, String> {
    match unsafe { optional_text(pointer, len, "ledger_json") }? {
        None => Ok(GuessLedger::default()),
        Some(text) if text.trim().is_empty() => Ok(GuessLedger::default()),
        Some(text) => serde_json::from_str(text).map_err(|e| format!("ledger: {e}")),
    }
}

fn decision_json(ledger: &GuessLedger, decision: GuessDecision) -> serde_json::Value {
    let retry_after_ms = match decision {
        GuessDecision::Allowed => 0,
        GuessDecision::Locked { retry_after_ms } => retry_after_ms,
    };
    json!({
        "allowed": decision.is_allowed(),
        "retryAfterMs": retry_after_ms,
        "ledger": serde_json::to_value(ledger).unwrap_or_else(|_| json!({})),
    })
}

#[no_mangle]
pub unsafe extern "C" fn skipper_pake_guess_admit(
    ledger_json: *const u8,
    ledger_json_len: usize,
    now_ms: i64,
) -> *mut c_char {
    respond(|| {
        let ledger = unsafe { ledger_from_json(ledger_json, ledger_json_len) }?;
        Ok(decision_json(&ledger, ledger.admit(now_ms)))
    })
}

#[no_mangle]
pub unsafe extern "C" fn skipper_pake_guess_reply_sent(
    ledger_json: *const u8,
    ledger_json_len: usize,
    now_ms: i64,
) -> *mut c_char {
    respond(|| {
        let ledger = unsafe { ledger_from_json(ledger_json, ledger_json_len) }?.reply_sent(now_ms);
        Ok(decision_json(&ledger, ledger.admit(now_ms)))
    })
}

#[no_mangle]
pub unsafe extern "C" fn skipper_pake_guess_confirmed(
    ledger_json: *const u8,
    ledger_json_len: usize,
    now_ms: i64,
) -> *mut c_char {
    respond(|| {
        let ledger = unsafe { ledger_from_json(ledger_json, ledger_json_len) }?.confirmed();
        Ok(decision_json(&ledger, ledger.admit(now_ms)))
    })
}

#[no_mangle]
pub extern "C" fn skipper_access_code_generate() -> *mut c_char {
    respond(|| Ok(json!({ "accessCode": access_code::generate() })))
}
