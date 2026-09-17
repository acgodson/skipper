use std::ffi::CStr;

use rc_identity::pake::PakeExchange;
use rc_identity::{DeviceKey, SigningPurpose};
use serde_json::Value;

use crate::pake::{skipper_pake_step, SkipperPake};
use crate::sdp::{skipper_sdp_fingerprints, skipper_sdp_signing_message, skipper_sdp_verify};
use crate::signing::skipper_signing_message;
use crate::skipper_string_free;

const FP: &str = "sha-256 7B:8C:1D:4F:2A:90:33:AE:BB:01:5C:6D:77:E8:99:0A:1B:2C:3D:4E:5F:60:71:82:93:A4:B5:C6:D7:E8:F9:0A";
const RELAY_FP: &str = "sha-256 00:11:22:33:44:55:66:77:88:99:AA:BB:CC:DD:EE:FF:00:11:22:33:44:55:66:77:88:99:AA:BB:CC:DD:EE:FF";
const SESSION: &str = "8c7f1a2b3c4d5e6f708192a3b4c5d6e7";

fn take(raw: *mut std::ffi::c_char) -> Value {
    assert!(!raw.is_null());
    let text = unsafe { CStr::from_ptr(raw) }.to_str().unwrap().to_string();
    unsafe { skipper_string_free(raw) };
    serde_json::from_str(&text).unwrap()
}

fn fingerprints_of(bytes: &[u8]) -> Value {
    take(unsafe { skipper_sdp_fingerprints(bytes.as_ptr(), bytes.len()) })
}

fn media_sdp(fp: &str) -> String {
    format!("v=0\r\nm=application 9 UDP/DTLS/SCTP webrtc-datachannel\r\na=fingerprint:{fp}\r\na=setup:actpass\r\n")
}

#[test]
fn an_interior_nul_is_refused_not_truncated() {
    let mut body = format!("v=0\r\na=fingerprint:{FP}\r\n").into_bytes();
    body.extend_from_slice(b"a=x-pad:\0\r\n");
    body.extend_from_slice(format!("a=fingerprint:{RELAY_FP}\r\n").as_bytes());
    let result = fingerprints_of(&body);
    assert_eq!(result["ok"], false);
    assert!(
        result["error"].as_str().unwrap().contains("NUL"),
        "{result}"
    );
}

#[test]
fn invalid_utf8_is_refused() {
    let body = b"v=0\r\na=fingerprint:sha-256 \xff\xfe\r\n";
    let result = fingerprints_of(body);
    assert_eq!(result["ok"], false);
    assert!(
        result["error"].as_str().unwrap().contains("UTF-8"),
        "{result}"
    );
}

#[test]
fn a_null_pointer_with_a_length_is_refused_and_an_empty_value_is_not_null() {
    let result = take(unsafe { skipper_sdp_fingerprints(std::ptr::null(), 4) });
    assert_eq!(result["ok"], false);
    let empty = take(unsafe { skipper_sdp_fingerprints(b"".as_ptr(), 0) });
    assert_eq!(empty["ok"], false);
    assert!(
        empty["error"].as_str().unwrap().contains("fingerprint"),
        "an empty but present SDP reaches the parser: {empty}"
    );
}

#[test]
fn the_whole_length_is_read_even_without_a_terminator() {
    let body = media_sdp(FP);
    let result = fingerprints_of(body.as_bytes());
    assert_eq!(result["fp"], FP);
}

#[test]
fn a_nonce_signing_message_needs_exactly_thirty_two_bytes_and_never_builds_sdp() {
    let nonce = [7u8; 32];
    let hello = take(unsafe {
        skipper_signing_message(SigningPurpose::Hello.code(), nonce.as_ptr(), nonce.len())
    });
    assert_eq!(hello["ok"], true, "{hello}");
    let short =
        take(unsafe { skipper_signing_message(SigningPurpose::Hello.code(), nonce.as_ptr(), 31) });
    assert_eq!(short["ok"], false);
    let sdp = take(unsafe {
        skipper_signing_message(SigningPurpose::Sdp.code(), nonce.as_ptr(), nonce.len())
    });
    assert_eq!(sdp["ok"], false);
    let unknown = take(unsafe { skipper_signing_message(42, nonce.as_ptr(), nonce.len()) });
    assert_eq!(unknown["ok"], false);
}

struct Pair {
    controller: *mut SkipperPake,
    host: *mut SkipperPake,
}

impl Drop for Pair {
    fn drop(&mut self) {
        unsafe {
            crate::pake::skipper_pake_free(self.controller);
            crate::pake::skipper_pake_free(self.host);
        }
    }
}

fn boxed(exchange: PakeExchange) -> *mut SkipperPake {
    Box::into_raw(Box::new(SkipperPake::from_exchange(exchange)))
}

fn step(pake: *mut SkipperPake, step: i32, payload: Option<&str>) -> Value {
    let (pointer, len) = payload.map_or((std::ptr::null(), 0), |p| (p.as_ptr(), p.len()));
    take(unsafe { skipper_pake_step(pake, step, pointer, len) })
}

fn completed_pair(controller_code: &str, host_code: &str) -> (Pair, Value) {
    let controller_key = DeviceKey::generate().public_key_spki_base64();
    let host_key = DeviceKey::generate().public_key_spki_base64();
    let pair = Pair {
        controller: boxed(
            PakeExchange::controller(controller_code, "482719351", SESSION, &controller_key)
                .unwrap(),
        ),
        host: boxed(PakeExchange::host(host_code, "482719351", SESSION, &host_key).unwrap()),
    };
    let one = step(pair.controller, 0, None);
    let two = step(pair.host, 1, one["outgoing"]["payload"].as_str());
    let three = step(pair.controller, 2, two["outgoing"]["payload"].as_str());
    if three["ok"] == false {
        return (pair, three);
    }
    let done = step(pair.host, 3, three["outgoing"]["payload"].as_str());
    (pair, done)
}

#[test]
fn a_wrong_code_is_reported_as_an_authentication_failure() {
    let (_pair, outcome) = completed_pair("K7FM3Q8PW2XY", "K7FM3Q8PW2X0");
    assert_eq!(outcome["ok"], false);
    assert_eq!(outcome["kind"], "authentication", "{outcome}");
}

#[test]
fn a_malformed_frame_is_not_an_authentication_failure() {
    let key = DeviceKey::generate().public_key_spki_base64();
    let host = boxed(PakeExchange::host("K7FM3Q8PW2XY", "482719351", SESSION, &key).unwrap());
    let outcome = step(host, 1, Some("AAAA"));
    assert_eq!(outcome["ok"], false);
    assert!(outcome.get("kind").is_none(), "{outcome}");
    unsafe { crate::pake::skipper_pake_free(host) };
}

fn text(value: &str) -> (*const u8, usize) {
    (value.as_ptr(), value.len())
}

fn verify(
    pake: *mut SkipperPake,
    sdp: &[u8],
    sdp_type: &str,
    sent: &Value,
    key: &DeviceKey,
) -> Value {
    let (session, session_len) = text(SESSION);
    let (kind, kind_len) = text(sdp_type);
    let fp = sent["fp"].as_str().unwrap();
    let mac = sent["mac"].as_str().unwrap();
    let payload = rc_identity::sdp::payload(SESSION, sdp_type, fp).unwrap();
    let sig = key.sign(SigningPurpose::Sdp, &payload).unwrap();
    let pubkey = key.public_key_spki_base64();
    take(unsafe {
        skipper_sdp_verify(
            pake,
            session,
            session_len,
            kind,
            kind_len,
            sdp.as_ptr(),
            sdp.len(),
            fp.as_ptr(),
            fp.len(),
            pubkey.as_ptr(),
            pubkey.len(),
            sig.as_ptr(),
            sig.len(),
            mac.as_ptr(),
            mac.len(),
            pubkey.as_ptr(),
            pubkey.len(),
        )
    })
}

fn signing_message(pake: *mut SkipperPake, sdp_type: &str, sdp: &str) -> Value {
    let (session, session_len) = text(SESSION);
    let (kind, kind_len) = text(sdp_type);
    take(unsafe {
        skipper_sdp_signing_message(
            pake,
            session,
            session_len,
            kind,
            kind_len,
            sdp.as_ptr(),
            sdp.len(),
        )
    })
}

#[test]
fn c1_through_the_boundary_a_nul_pad_cannot_hide_swapped_fingerprints() {
    let (pair, done) = completed_pair("K7FM3Q8PW2XY", "k7fm-3q8p-w2xy");
    assert_eq!(done["ok"], true, "{done}");
    let peer = DeviceKey::generate();
    for sdp_type in ["offer", "answer"] {
        let genuine = media_sdp(FP);
        let sent = signing_message(pair.controller, sdp_type, &genuine);
        assert_eq!(sent["fp"], FP);
        let accepted = verify(pair.host, genuine.as_bytes(), sdp_type, &sent, &peer);
        assert_eq!(accepted["verified"], true, "{accepted}");

        let attack = format!(
            "v=0\r\na=fingerprint:{FP}\r\na=x-pad:\0\r\n{}",
            media_sdp(RELAY_FP).trim_start_matches("v=0\r\n")
        );
        let refused = verify(pair.host, attack.as_bytes(), sdp_type, &sent, &peer);
        assert_eq!(refused["ok"], false, "{sdp_type}: {refused}");
    }
}

#[test]
fn an_sdp_is_refused_before_the_exchange_completes_and_under_another_exchange() {
    let key = DeviceKey::generate().public_key_spki_base64();
    let fresh =
        boxed(PakeExchange::controller("K7FM3Q8PW2XY", "482719351", SESSION, &key).unwrap());
    let early = signing_message(fresh, "offer", &media_sdp(FP));
    assert_eq!(early["ok"], false, "{early}");
    unsafe { crate::pake::skipper_pake_free(fresh) };

    let null = signing_message(std::ptr::null_mut(), "offer", &media_sdp(FP));
    assert_eq!(null["ok"], false);

    let (ours, _) = completed_pair("K7FM3Q8PW2XY", "K7FM3Q8PW2XY");
    let (theirs, _) = completed_pair("K7FM3Q8PW2XY", "K7FM3Q8PW2XY");
    let peer = DeviceKey::generate();
    let sent = signing_message(ours.controller, "offer", &media_sdp(FP));
    let relayed = verify(theirs.host, media_sdp(FP).as_bytes(), "offer", &sent, &peer);
    assert_eq!(relayed["ok"], false);
    assert!(
        relayed["error"].as_str().unwrap().contains("mac"),
        "{relayed}"
    );
}
