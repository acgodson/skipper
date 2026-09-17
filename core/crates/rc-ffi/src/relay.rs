//! Protocol v5 relayed frames, checked by the one grammar every Rust side
//! uses, [`rc_proto::relay`], plus the client's own stricter input rules.

use std::ffi::c_char;

use rc_proto::relay::{self, Relay};
use rc_session::input;
use serde::Deserialize;
use serde_json::{json, value::RawValue, Value};

use crate::{required_text, respond, FfiError};

#[derive(Deserialize)]
struct Frame<'a> {
    #[serde(rename = "type")]
    msg_type: String,
    #[serde(borrow)]
    payload: &'a RawValue,
}

fn verdict(relayed: &Relay) -> Result<Value, String> {
    input::session_id(relayed.session_id()).map_err(|e| e.to_string())?;
    Ok(match relayed {
        Relay::Sdp(message) => {
            input::sdp_type(&message.sdp_type).map_err(|e| e.to_string())?;
            json!({ "type": "sdp" })
        }
        Relay::Ice(_) => json!({ "type": "ice" }),
        Relay::Pake(message) => json!({ "type": "pake", "step": message.step }),
    })
}

pub(crate) fn check(frame_json: &str) -> Result<Value, String> {
    let frame: Frame =
        serde_json::from_str(frame_json).map_err(|e| format!("relayed frame: {e}"))?;
    let relayed = relay::decode(&frame.msg_type, frame.payload.get()).map_err(|e| e.to_string())?;
    verdict(&relayed)
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
