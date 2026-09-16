//! The C ABI over [`rc_identity::pake`], described by the `skipper_pake_*`
//! section of `include/skipper_core.h`.

use std::ffi::c_char;
use std::panic::{catch_unwind, AssertUnwindSafe};

use rc_identity::access_code;
use rc_identity::pake::{
    GuessCounter, GuessDecision, GuessPolicy, PakeExchange, PakeMessage, MAX_PAYLOAD_BASE64,
};
use serde_json::json;

use crate::{error_string, into_c_string, optional_str, required_str, ROLE_HOST};

pub struct SkipperPake {
    exchange: PakeExchange,
}

fn respond<F>(body: F) -> *mut c_char
where
    F: FnOnce() -> Result<serde_json::Value, String>,
{
    let outcome = catch_unwind(AssertUnwindSafe(|| match body() {
        Ok(mut value) => {
            if let Some(object) = value.as_object_mut() {
                object.insert("ok".to_string(), json!(true));
            }
            value.to_string()
        }
        Err(message) => error_string(&message),
    }));
    into_c_string(outcome.unwrap_or_else(|_| error_string("the pake exchange panicked")))
}

fn counter_from_json(raw: Option<&str>) -> Result<GuessCounter, String> {
    match raw {
        None => Ok(GuessCounter::default()),
        Some(text) if text.trim().is_empty() => Ok(GuessCounter::default()),
        Some(text) => serde_json::from_str(text).map_err(|e| format!("counter: {e}")),
    }
}

fn counter_json(counter: &GuessCounter) -> serde_json::Value {
    serde_json::to_value(counter).unwrap_or_else(|_| json!({}))
}

#[no_mangle]
pub unsafe extern "C" fn skipper_pake_new(
    role: i32,
    access_code: *const c_char,
    device_id: *const c_char,
    session_id: *const c_char,
) -> *mut SkipperPake {
    let built = catch_unwind(AssertUnwindSafe(|| {
        let access_code = unsafe { required_str(access_code, "access_code") }.ok()?;
        let device_id = unsafe { required_str(device_id, "device_id") }.ok()?;
        let session_id = unsafe { required_str(session_id, "session_id") }.ok()?;
        let exchange = if role == ROLE_HOST {
            PakeExchange::host(access_code, device_id, session_id)
        } else {
            PakeExchange::controller(access_code, device_id, session_id)
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
    payload_base64: *const c_char,
) -> *mut c_char {
    respond(|| {
        let pake = unsafe { pake.as_mut() }.ok_or("pake handle is null")?;
        let payload = unsafe { optional_str(payload_base64) }?;
        let incoming = match (step, payload) {
            (0, None) => None,
            (step, Some(payload)) if step > 0 => Some(
                PakeMessage::from_base64(step as u32, payload).map_err(|e| e.to_string())?,
            ),
            _ => return Err("a step above zero must carry a payload".to_string()),
        };
        let outgoing =
            pake.exchange.step(incoming.as_ref()).map_err(|e| e.to_string())?;
        let outgoing = outgoing.map(|message| {
            json!({ "step": message.step, "payload": message.to_base64() })
        });
        Ok(json!({ "outgoing": outgoing, "complete": pake.exchange.is_complete() }))
    })
}

#[no_mangle]
pub unsafe extern "C" fn skipper_pake_session_key(pake: *mut SkipperPake) -> *mut c_char {
    respond(|| {
        let pake = unsafe { pake.as_mut() }.ok_or("pake handle is null")?;
        let key = pake.exchange.session_key_base64().map_err(|e| e.to_string())?;
        Ok(json!({ "sessionKey": key }))
    })
}

#[no_mangle]
pub extern "C" fn skipper_pake_max_payload_base64() -> i32 {
    MAX_PAYLOAD_BASE64 as i32
}

#[no_mangle]
pub unsafe extern "C" fn skipper_pake_guess_policy_check(
    counter_json_in: *const c_char,
    now_ms: i64,
) -> *mut c_char {
    respond(|| {
        let counter = counter_from_json(unsafe { optional_str(counter_json_in) }?)?;
        let decision = GuessPolicy::default().check(&counter, now_ms);
        Ok(decision_json(&counter, decision))
    })
}

#[no_mangle]
pub unsafe extern "C" fn skipper_pake_guess_policy_record_failure(
    counter_json_in: *const c_char,
    now_ms: i64,
) -> *mut c_char {
    respond(|| {
        let policy = GuessPolicy::default();
        let counter = policy.record_failure(&counter_from_json(unsafe {
            optional_str(counter_json_in)
        }?)?, now_ms);
        let decision = policy.check(&counter, now_ms);
        Ok(decision_json(&counter, decision))
    })
}

#[no_mangle]
pub unsafe extern "C" fn skipper_pake_guess_policy_record_success(
    counter_json_in: *const c_char,
) -> *mut c_char {
    respond(|| {
        let counter = GuessPolicy::default()
            .record_success(&counter_from_json(unsafe { optional_str(counter_json_in) }?)?);
        Ok(decision_json(&counter, GuessDecision::Allowed))
    })
}

#[no_mangle]
pub extern "C" fn skipper_access_code_generate() -> *mut c_char {
    respond(|| Ok(json!({ "accessCode": access_code::generate() })))
}

fn decision_json(counter: &GuessCounter, decision: GuessDecision) -> serde_json::Value {
    let retry_after_ms = match decision {
        GuessDecision::Allowed => 0,
        GuessDecision::Locked { retry_after_ms } => retry_after_ms,
    };
    json!({
        "allowed": decision.is_allowed(),
        "retryAfterMs": retry_after_ms,
        "counter": counter_json(counter),
    })
}
