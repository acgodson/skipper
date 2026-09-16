//! The C ABI over [`rc_identity::sdp`], described by the `skipper_sdp_*`
//! section of `include/skipper_core.h`.
//!
//! Signing is absent on purpose: the device key may be in the Secure Enclave,
//! so only the platform can produce a signature. The core hands out the bytes
//! to sign and does every check on the way back in.

use std::ffi::c_char;

use rc_identity::sdp;
use serde_json::json;

use crate::{optional_str, required_str, respond};

#[no_mangle]
pub unsafe extern "C" fn skipper_sdp_fingerprints(sdp_body: *const c_char) -> *mut c_char {
    respond("sdp fingerprint extraction panicked", || {
        let body = unsafe { required_str(sdp_body, "sdp") }?;
        let fingerprints = sdp::fingerprints(body).map_err(|e| e.to_string())?;
        Ok(json!({ "fp": fingerprints }))
    })
}

#[no_mangle]
pub unsafe extern "C" fn skipper_sdp_signing_message(
    session_id: *const c_char,
    sdp_type: *const c_char,
    sdp_body: *const c_char,
) -> *mut c_char {
    respond("sdp signing-message construction panicked", || {
        let session_id = unsafe { required_str(session_id, "session_id") }?;
        let sdp_type = unsafe { required_str(sdp_type, "sdp_type") }?;
        let body = unsafe { required_str(sdp_body, "sdp") }?;
        let (fingerprints, message) = sdp::signing_material(session_id, sdp_type, body)
            .map_err(|e| e.to_string())?;
        Ok(json!({ "fp": fingerprints, "message": message }))
    })
}

#[no_mangle]
pub unsafe extern "C" fn skipper_sdp_verify(
    session_id: *const c_char,
    sdp_type: *const c_char,
    sdp_body: *const c_char,
    fingerprints: *const c_char,
    pubkey: *const c_char,
    sig: *const c_char,
    expected_pubkey: *const c_char,
) -> *mut c_char {
    respond("sdp verification panicked", || {
        let session_id = unsafe { required_str(session_id, "session_id") }?;
        let sdp_type = unsafe { required_str(sdp_type, "sdp_type") }?;
        let body = unsafe { required_str(sdp_body, "sdp") }?;
        let fingerprints = unsafe { required_str(fingerprints, "fp") }?;
        let pubkey = unsafe { required_str(pubkey, "pubkey") }?;
        let sig = unsafe { required_str(sig, "sig") }?;
        let expected = unsafe { optional_str(expected_pubkey) }?;
        sdp::verify(session_id, sdp_type, body, fingerprints, pubkey, sig, expected)
            .map_err(|e| e.to_string())?;
        Ok(json!({ "verified": true }))
    })
}
