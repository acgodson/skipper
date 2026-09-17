use std::ffi::c_char;

use base64::engine::general_purpose::STANDARD as B64;
use base64::Engine;
use rc_identity::sdp;
use serde_json::json;

use crate::pake::sdp_mac_key;
use crate::{required_text, respond, SkipperPake};

#[no_mangle]
pub unsafe extern "C" fn skipper_sdp_fingerprints(
    sdp_body: *const u8,
    sdp_body_len: usize,
) -> *mut c_char {
    respond("sdp fingerprint extraction panicked", || {
        let body = unsafe { required_text(sdp_body, sdp_body_len, "sdp") }?;
        let fingerprints = sdp::fingerprints(body).map_err(|e| e.to_string())?;
        Ok(json!({ "fp": fingerprints }))
    })
}

#[no_mangle]
pub unsafe extern "C" fn skipper_sdp_signing_message(
    pake: *mut SkipperPake,
    session_id: *const u8,
    session_id_len: usize,
    sdp_type: *const u8,
    sdp_type_len: usize,
    sdp_body: *const u8,
    sdp_body_len: usize,
) -> *mut c_char {
    respond("sdp signing-message construction panicked", || {
        let mac_key = unsafe { sdp_mac_key(pake) }?;
        let session_id = unsafe { required_text(session_id, session_id_len, "session_id") }?;
        let sdp_type = unsafe { required_text(sdp_type, sdp_type_len, "sdp_type") }?;
        let body = unsafe { required_text(sdp_body, sdp_body_len, "sdp") }?;
        let signable =
            sdp::signable(&mac_key, session_id, sdp_type, body).map_err(|e| e.to_string())?;
        Ok(json!({
            "fp": signable.fingerprints,
            "message": B64.encode(&signable.message),
            "mac": signable.mac,
        }))
    })
}

#[no_mangle]
pub unsafe extern "C" fn skipper_sdp_verify(
    pake: *mut SkipperPake,
    session_id: *const u8,
    session_id_len: usize,
    sdp_type: *const u8,
    sdp_type_len: usize,
    sdp_body: *const u8,
    sdp_body_len: usize,
    fingerprints: *const u8,
    fingerprints_len: usize,
    pubkey: *const u8,
    pubkey_len: usize,
    sig: *const u8,
    sig_len: usize,
    mac: *const u8,
    mac_len: usize,
    expected_pubkey: *const u8,
    expected_pubkey_len: usize,
) -> *mut c_char {
    respond("sdp verification panicked", || {
        let mac_key = unsafe { sdp_mac_key(pake) }?;
        let session_id = unsafe { required_text(session_id, session_id_len, "session_id") }?;
        let sdp_type = unsafe { required_text(sdp_type, sdp_type_len, "sdp_type") }?;
        let body = unsafe { required_text(sdp_body, sdp_body_len, "sdp") }?;
        let presented = sdp::Presented {
            fingerprints: unsafe { required_text(fingerprints, fingerprints_len, "fp") }?,
            pubkey: unsafe { required_text(pubkey, pubkey_len, "pubkey") }?,
            sig: unsafe { required_text(sig, sig_len, "sig") }?,
            mac: unsafe { required_text(mac, mac_len, "mac") }?,
        };
        let expected =
            unsafe { required_text(expected_pubkey, expected_pubkey_len, "expected_pubkey") }?;
        sdp::verify(&mac_key, session_id, sdp_type, body, &presented, expected)
            .map_err(|e| e.to_string())?;
        Ok(json!({ "verified": true }))
    })
}

#[no_mangle]
pub unsafe extern "C" fn skipper_sdp_without_candidates(
    sdp_body: *const u8,
    sdp_body_len: usize,
) -> *mut c_char {
    respond("sdp candidate stripping panicked", || {
        let body = unsafe { required_text(sdp_body, sdp_body_len, "sdp") }?;
        let stripped = sdp::without_candidates(body).map_err(|e| e.to_string())?;
        Ok(json!({ "sdp": stripped }))
    })
}
