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

#[test]
fn verify_refuses_a_missing_or_empty_peer_pin_and_a_foreign_session_id() {
    let (pair, _) = completed_pair("K7FM3Q8PW2XY", "K7FM3Q8PW2XY");
    let peer = DeviceKey::generate();
    let body = media_sdp(FP);
    let sent = signing_message(pair.controller, "offer", &body);
    let fp = sent["fp"].as_str().unwrap();
    let mac = sent["mac"].as_str().unwrap();
    let payload = rc_identity::sdp::payload(SESSION, "offer", fp).unwrap();
    let sig = peer.sign(SigningPurpose::Sdp, &payload).unwrap();
    let pubkey = peer.public_key_spki_base64();
    let call = |session: &str, expected: Option<&str>| {
        let (expected, expected_len) = expected.map_or((std::ptr::null(), 0), text);
        take(unsafe {
            skipper_sdp_verify(
                pair.host,
                session.as_ptr(),
                session.len(),
                "offer".as_ptr(),
                5,
                body.as_ptr(),
                body.len(),
                fp.as_ptr(),
                fp.len(),
                pubkey.as_ptr(),
                pubkey.len(),
                sig.as_ptr(),
                sig.len(),
                mac.as_ptr(),
                mac.len(),
                expected,
                expected_len,
            )
        })
    };
    assert_eq!(call(SESSION, Some(&pubkey))["verified"], true);
    for refused in [
        call(SESSION, None),
        call(SESSION, Some("")),
        call("S|offer", Some(&pubkey)),
    ] {
        assert_eq!(refused["ok"], false, "{refused}");
    }
    let sent_bad = signing_message(pair.controller, "pranswer", &body);
    assert_eq!(sent_bad["ok"], false, "{sent_bad}");
}

#[test]
fn candidates_are_stripped_through_the_boundary() {
    let body = format!(
        "{}a=candidate:1 1 udp 1 203.0.113.9 9 typ host\r\n",
        media_sdp(FP)
    );
    let stripped =
        take(unsafe { crate::sdp::skipper_sdp_without_candidates(body.as_ptr(), body.len()) });
    assert_eq!(stripped["sdp"], media_sdp(FP));
    let padded = "a=candidate:1\0\r\n";
    let refused =
        take(unsafe { crate::sdp::skipper_sdp_without_candidates(padded.as_ptr(), padded.len()) });
    assert_eq!(refused["ok"], false);
}

fn session_call(
    body: impl FnOnce(*mut crate::SkipperSession) -> *mut std::ffi::c_char,
    session: *mut crate::SkipperSession,
) -> Value {
    take(body(session))
}

#[test]
fn a_malformed_grant_is_an_error_and_changes_nothing() {
    let session = crate::skipper_session_new(crate::ROLE_HOST, 3_000, 45_000, 300_000);
    let grant = |id: &str, host: &str, ctrl: &str| {
        session_call(
            |s| unsafe {
                crate::skipper_session_granted(
                    s,
                    id.as_ptr(),
                    id.len(),
                    "t".as_ptr(),
                    1,
                    host.as_ptr(),
                    host.len(),
                    ctrl.as_ptr(),
                    ctrl.len(),
                    0,
                )
            },
            session,
        )
    };
    for (id, host) in [("S|offer", "739000587"), (SESSION, "739 000 587")] {
        let refused = grant(id, host, "481930275");
        assert_eq!(refused["ok"], false, "{refused}");
        assert!(refused.get("actions").is_none());
    }
    let state = session_call(|s| unsafe { crate::skipper_session_state(s) }, session);
    assert_eq!(state["state"]["hasSession"], false);

    let granted = grant(SESSION, "739000587", "Evil <b>Mac</b>");
    assert_eq!(granted["ok"], true, "{granted}");
    assert_eq!(granted["actions"][0]["action"], "teardownPeerConnection");
    assert_eq!(granted["state"]["peerDeviceId"], Value::Null);
    unsafe { crate::skipper_session_free(session) };
}

#[test]
fn consent_answers_name_their_prompt_and_allow_waits() {
    let session = crate::skipper_session_new(crate::ROLE_HOST, 3_000, 45_000, 300_000);
    let answer = |allow: bool, id: Option<&str>, now: i64| {
        let (pointer, len) = id.map_or((std::ptr::null(), 0), text);
        session_call(
            |s| unsafe { crate::skipper_session_consent_answered(s, allow, pointer, len, now) },
            session,
        )
    };
    session_call(
        |s| unsafe { crate::skipper_session_set_consent_required(s, true) },
        session,
    );
    session_call(
        |s| unsafe {
            crate::skipper_session_granted(
                s,
                SESSION.as_ptr(),
                SESSION.len(),
                "t".as_ptr(),
                1,
                "739000587".as_ptr(),
                9,
                "481930275".as_ptr(),
                9,
                0,
            )
        },
        session,
    );
    let prompt = session_call(
        |s| unsafe { crate::skipper_session_pake_succeeded(s, 1_000) },
        session,
    );
    assert_eq!(prompt["actions"][0]["action"], "promptForConsent");
    assert_eq!(
        answer(true, Some(SESSION), 2_000)["actions"],
        serde_json::json!([])
    );
    assert_eq!(
        answer(true, Some("feedfacefeedfacefeedfacefeedface"), 2_500)["actions"],
        serde_json::json!([])
    );
    let allowed = answer(true, Some(SESSION), 2_500);
    assert_eq!(
        allowed["actions"][1]["action"], "startPeerConnection",
        "{allowed}"
    );
    unsafe { crate::skipper_session_free(session) };
}

#[test]
fn the_consent_budget_and_ledger_keys_cross_the_boundary() {
    let key = DeviceKey::generate().public_key_spki_base64();
    let canonical =
        take(unsafe { crate::consent::skipper_pubkey_canonical(key.as_ptr(), key.len()) });
    assert_eq!(canonical["key"], key.as_str());
    assert_eq!(canonical["canonical"], true);
    let refused = take(unsafe { crate::consent::skipper_pubkey_canonical("host".as_ptr(), 4) });
    assert_eq!(refused["ok"], false);

    let mut host = serde_json::json!({});
    for minute in 0..3 {
        let now = minute * 60_000;
        let new_controller = serde_json::json!({ "host": host }).to_string();
        let (pointer, len) = text(&new_controller);
        let admitted = take(unsafe { crate::consent::skipper_consent_admit(pointer, len, now) });
        assert_eq!(admitted["prompt"], true, "{admitted}");
        let opened = take(unsafe { crate::consent::skipper_consent_prompted(pointer, len, now) });
        host = opened["ledger"]["host"].clone();
    }
    let fourth = serde_json::json!({ "host": host }).to_string();
    let (pointer, len) = text(&fourth);
    let refused = take(unsafe { crate::consent::skipper_consent_admit(pointer, len, 180_000) });
    assert_eq!(refused["prompt"], false);
    assert_eq!(refused["retryAfterMs"], 420_000);

    let counters = serde_json::json!({
        key.clone(): { "failures": 1, "lastFailureMs": 1 },
        "junk": { "failures": 1, "lastFailureMs": 1 },
        "host": { "failures": 0, "lastFailureMs": 0, "lockedUntilMs": 0, "promptTimesMs": [5] },
    })
    .to_string();
    let pruned = take(unsafe {
        crate::consent::skipper_ledger_prune(counters.as_ptr(), counters.len(), 10)
    });
    let mut kept: Vec<&str> = pruned["counters"]
        .as_object()
        .unwrap()
        .keys()
        .map(String::as_str)
        .collect();
    kept.sort_unstable();
    let mut expected = vec!["host", key.as_str()];
    expected.sort_unstable();
    assert_eq!(kept, expected);
}
