//! Protocol v5 relayed frames decoded into their exact schema: exact-case
//! keys, each once, no `null`, no unknown key, every field bounded by
//! [`rc_session::relay`].

use std::ffi::c_char;

use rc_session::{input, relay};
use serde::Deserialize;
use serde_json::{json, Number, Value};

use crate::{required_text, respond, FfiError};

#[derive(Deserialize)]
#[serde(deny_unknown_fields, rename_all = "camelCase")]
struct Sdp {
    session_id: String,
    sdp_type: String,
    sdp: String,
    #[serde(rename = "restart")]
    _restart: Option<bool>,
    fp: Option<String>,
    pubkey: Option<String>,
    sig: Option<String>,
    mac: Option<String>,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields, rename_all = "camelCase")]
struct Ice {
    session_id: String,
    candidate: String,
    sdp_mid: Option<String>,
    #[serde(rename = "sdpMLineIndex")]
    sdp_m_line_index: Option<Number>,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields, rename_all = "camelCase")]
struct Pake {
    session_id: String,
    step: Number,
    payload: String,
}

fn integer(number: &Number, error: relay::RelayError) -> Result<i64, relay::RelayError> {
    number.as_i64().ok_or(error)
}

fn optional<F>(value: &Option<String>, check: F) -> Result<(), relay::RelayError>
where
    F: FnOnce(&str) -> Result<(), relay::RelayError>,
{
    value.as_deref().map_or(Ok(()), check)
}

fn check_sdp(message: &Sdp) -> Result<(), String> {
    input::session_id(&message.session_id).map_err(|e| e.to_string())?;
    input::sdp_type(&message.sdp_type).map_err(|e| e.to_string())?;
    relay::sdp_body(&message.sdp)
        .and_then(|_| optional(&message.fp, relay::fingerprint_list))
        .and_then(|_| {
            optional(&message.pubkey, |v| {
                relay::base64_field("pubkey", v, relay::PUBKEY_MAX_BYTES)
            })
        })
        .and_then(|_| {
            optional(&message.sig, |v| {
                relay::base64_field("sig", v, relay::SIGNATURE_MAX_BYTES)
            })
        })
        .and_then(|_| {
            optional(&message.mac, |v| {
                relay::base64_field("mac", v, relay::MAC_MAX_BYTES)
            })
        })
        .map_err(|e| e.to_string())
}

fn check_ice(message: &Ice) -> Result<(), String> {
    input::session_id(&message.session_id).map_err(|e| e.to_string())?;
    relay::candidate(&message.candidate)
        .and_then(|_| optional(&message.sdp_mid, relay::sdp_mid))
        .and_then(|_| match &message.sdp_m_line_index {
            None => Ok(()),
            Some(index) => {
                relay::m_line_index(integer(index, relay::RelayError::MLineIndex)?).map(|_| ())
            }
        })
        .map_err(|e| e.to_string())
}

fn check_pake(message: &Pake) -> Result<u8, String> {
    input::session_id(&message.session_id).map_err(|e| e.to_string())?;
    let step = integer(&message.step, relay::RelayError::PakeStep)
        .and_then(relay::pake_step)
        .map_err(|e| e.to_string())?;
    relay::pake_payload(&message.payload).map_err(|e| e.to_string())?;
    Ok(step)
}

#[derive(Deserialize)]
#[serde(tag = "type", content = "payload")]
enum Relayed {
    #[serde(rename = "sdp")]
    Sdp(Sdp),
    #[serde(rename = "ice")]
    Ice(Ice),
    #[serde(rename = "pake")]
    Pake(Pake),
}

fn payload_without_nulls(frame_json: &str) -> Result<(), String> {
    let frame: Value =
        serde_json::from_str(frame_json).map_err(|e| format!("relayed frame: {e}"))?;
    match frame.get("payload").and_then(Value::as_object) {
        Some(payload) if payload.values().all(|value| !value.is_null()) => Ok(()),
        _ => Err("a relayed payload is an object without null members".into()),
    }
}

pub(crate) fn check(frame_json: &str) -> Result<Value, String> {
    payload_without_nulls(frame_json)?;
    let relayed: Relayed =
        serde_json::from_str(frame_json).map_err(|e| format!("relayed frame: {e}"))?;
    match relayed {
        Relayed::Sdp(message) => check_sdp(&message).map(|_| json!({ "type": "sdp" })),
        Relayed::Ice(message) => check_ice(&message).map(|_| json!({ "type": "ice" })),
        Relayed::Pake(message) => {
            check_pake(&message).map(|step| json!({ "type": "pake", "step": step }))
        }
    }
}

#[no_mangle]
pub unsafe extern "C" fn skipper_relayed_check(
    frame_json: *const u8,
    frame_json_len: usize,
) -> *mut c_char {
    respond("the relayed-frame check panicked", || {
        let frame = unsafe { required_text(frame_json, frame_json_len, "frame_json") }?;
        check(frame).map_err(FfiError::from)
    })
}

#[cfg(test)]
mod tests;
