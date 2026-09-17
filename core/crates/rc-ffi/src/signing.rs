use std::ffi::c_char;

use base64::engine::general_purpose::STANDARD as B64;
use base64::Engine;
use rc_identity::signing::{signing_message, SigningPurpose};
use serde_json::json;

use crate::{payload_bytes, respond};

#[no_mangle]
pub unsafe extern "C" fn skipper_signing_message(
    purpose: i32,
    payload: *const u8,
    payload_len: usize,
) -> *mut c_char {
    respond("signing-message construction panicked", || {
        let purpose = SigningPurpose::from_code(purpose).map_err(|e| e.to_string())?;
        if !purpose.takes_nonce() {
            return Err("an sdp message is built only by skipper_sdp_signing_message".into());
        }
        let payload = unsafe { payload_bytes(payload, payload_len, "payload") }?;
        let message = signing_message(purpose, payload).map_err(|e| e.to_string())?;
        Ok(json!({ "message": B64.encode(message) }))
    })
}
