use super::*;

const SESSION: &str = "8c7f1a2b3c4d5e6f708192a3b4c5d6e7";
const CANDIDATE: &str = "candidate:1 1 udp 2122260223 192.168.1.20 61234 typ host";

fn pake(payload: &str) -> String {
    format!(r#"{{"v":5,"type":"pake","id":"s-1","ts":1,"payload":{payload}}}"#)
}

fn ice(payload: &str) -> String {
    format!(r#"{{"v":5,"type":"ice","payload":{payload}}}"#)
}

fn sdp(payload: &str) -> String {
    format!(r#"{{"type":"sdp","v":5,"payload":{payload}}}"#)
}

#[test]
fn well_formed_frames_pass_and_report_their_type() {
    assert_eq!(
        check(&pake(&format!(
            r#"{{"sessionId":"{SESSION}","step":2,"payload":"QUJD"}}"#
        ))),
        Ok(json!({ "type": "pake", "step": 2 }))
    );
    assert_eq!(
        check(&ice(&format!(
            r#"{{"sessionId":"{SESSION}","candidate":"{CANDIDATE}","sdpMid":"0","sdpMLineIndex":0}}"#
        ))),
        Ok(json!({ "type": "ice" }))
    );
    assert_eq!(
        check(&ice(&format!(
            r#"{{"sessionId":"{SESSION}","candidate":"{CANDIDATE}"}}"#
        ))),
        Ok(json!({ "type": "ice" }))
    );
    assert_eq!(
        check(&ice(&format!(
            r#"{{"sessionId":"{SESSION}","candidate":""}}"#
        ))),
        Ok(json!({ "type": "ice" })),
        "the end-of-candidates marker"
    );
    assert_eq!(
        check(&sdp(&format!(
            r#"{{"sessionId":"{SESSION}","sdpType":"offer","sdp":"v=0\r\n","restart":true,"fp":"sha-256 AA\nsha-256 BB","pubkey":"cHVi","sig":"c2ln","mac":"bWFj"}}"#
        ))),
        Ok(json!({ "type": "sdp" }))
    );
}

#[test]
fn the_review_crash_step_and_every_other_bad_step_is_refused() {
    for step in [
        "4294967296",
        "0",
        "4",
        "-1",
        "2.0",
        "1e3",
        "\"2\"",
        "null",
        "9223372036854775808",
        "18446744073709551616",
    ] {
        let frame = pake(&format!(
            r#"{{"sessionId":"{SESSION}","step":{step},"payload":"QUJD"}}"#
        ));
        assert!(check(&frame).is_err(), "step {step}");
    }
}

#[test]
fn unknown_miscased_duplicate_or_missing_keys_are_refused() {
    for payload in [
        format!(r#"{{"sessionId":"{SESSION}","step":1,"payload":"QUJD","extra":1}}"#),
        format!(r#"{{"SESSIONID":"{SESSION}","step":1,"payload":"QUJD"}}"#),
        format!(r#"{{"sessionid":"{SESSION}","step":1,"payload":"QUJD"}}"#),
        format!(r#"{{"sessionId":"{SESSION}","sessionId":"{SESSION}","step":1,"payload":"QUJD"}}"#),
        format!(r#"{{"sessionId":"{SESSION}","step":1,"step":2,"payload":"QUJD"}}"#),
        format!(r#"{{"sessionId":"{SESSION}","payload":"QUJD"}}"#),
        format!(r#"{{"sessionId":"{SESSION}","step":1}}"#),
        r#"{"step":1,"payload":"QUJD"}"#.to_string(),
        format!(r#"{{"sessionId":"{SESSION}","step":1,"payload":null}}"#),
        "[]".to_string(),
        "null".to_string(),
    ] {
        assert!(check(&pake(&payload)).is_err(), "{payload}");
    }
    let ice_extra = ice(&format!(
        r#"{{"sessionId":"{SESSION}","candidate":"{CANDIDATE}","sdp":"v=0"}}"#
    ));
    assert!(check(&ice_extra).is_err());
    let sdp_extra = sdp(&format!(
        r#"{{"sessionId":"{SESSION}","sdpType":"offer","sdp":"v=0","Fp":"x"}}"#
    ));
    assert!(check(&sdp_extra).is_err());
}

#[test]
fn a_frame_that_is_not_a_relayed_type_is_refused() {
    for frame in [
        format!(r#"{{"v":5,"type":"bye","payload":{{"sessionId":"{SESSION}","reason":"x"}}}}"#),
        format!(
            r#"{{"v":5,"type":"PAKE","payload":{{"sessionId":"{SESSION}","step":1,"payload":"QUJD"}}}}"#
        ),
        format!(r#"{{"v":5,"payload":{{"sessionId":"{SESSION}","step":1,"payload":"QUJD"}}}}"#),
        "not json".to_string(),
    ] {
        assert!(check(&frame).is_err(), "{frame}");
    }
}

#[test]
fn field_bounds_apply_inside_each_schema() {
    let long_sdp = format!("v=0{}", "a".repeat(rc_proto::consts::relay::MAX_SDP_BYTES));
    for payload in [
        format!(r#"{{"sessionId":"{SESSION}","sdpType":"offer","sdp":"{long_sdp}"}}"#),
        format!(r#"{{"sessionId":"{SESSION}","sdpType":"offer","sdp":"o=-"}}"#),
        format!(r#"{{"sessionId":"{SESSION}","sdpType":"pranswer","sdp":"v=0"}}"#),
        r#"{"sessionId":"S|x","sdpType":"offer","sdp":"v=0"}"#.to_string(),
        format!(
            r#"{{"sessionId":"{SESSION}","sdpType":"offer","sdp":"v=0","mac":"{}"}}"#,
            "A".repeat(rc_proto::consts::relay::MAX_MAC_CHARS + 1)
        ),
        format!(r#"{{"sessionId":"{SESSION}","sdpType":"offer","sdp":"v=0","restart":"yes"}}"#),
    ] {
        assert!(check(&sdp(&payload)).is_err(), "{payload:.120}");
    }
    for payload in [
        format!(r#"{{"sessionId":"{SESSION}","candidate":"c"}}"#),
        format!(r#"{{"sessionId":"{SESSION}","candidate":"{CANDIDATE}","sdpMid":null}}"#),
        format!(r#"{{"sessionId":"{SESSION}","candidate":"{CANDIDATE}\r\na=x"}}"#),
        format!(
            r#"{{"sessionId":"{SESSION}","candidate":"{CANDIDATE}","sdpMLineIndex":2147483648}}"#
        ),
        format!(r#"{{"sessionId":"{SESSION}","candidate":"{CANDIDATE}","sdpMLineIndex":0.5}}"#),
        format!(r#"{{"sessionId":"{SESSION}","candidate":"{CANDIDATE}","sdpMLineIndex":-1}}"#),
        format!(r#"{{"sessionId":"{SESSION}","candidate":"{CANDIDATE}","sdpMid":"a b"}}"#),
    ] {
        assert!(check(&ice(&payload)).is_err(), "{payload}");
    }
    let big_payload = "A".repeat(rc_proto::consts::MAX_PAKE_PAYLOAD_BYTES + 1);
    let frame = pake(&format!(
        r#"{{"sessionId":"{SESSION}","step":1,"payload":"{big_payload}"}}"#
    ));
    assert!(check(&frame).is_err());
}

#[test]
fn the_c_entry_point_answers_with_the_same_verdict() {
    let good = pake(&format!(
        r#"{{"sessionId":"{SESSION}","step":3,"payload":"QUJD"}}"#
    ));
    let bad = pake(&format!(
        r#"{{"sessionId":"{SESSION}","step":4294967296,"payload":"QUJD"}}"#
    ));
    for (frame, ok) in [(good, true), (bad, false)] {
        let raw = unsafe { skipper_relayed_check(frame.as_ptr(), frame.len()) };
        let text = unsafe { std::ffi::CStr::from_ptr(raw) }
            .to_str()
            .unwrap()
            .to_string();
        unsafe { crate::skipper_string_free(raw) };
        let value: serde_json::Value = serde_json::from_str(&text).unwrap();
        assert_eq!(value["ok"], json!(ok), "{text}");
    }
}
