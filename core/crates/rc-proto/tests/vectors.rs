use rc_proto::{ctrl, envelope::Envelope, relay, signaling as sig};
use serde::Serialize;
use serde_json::Value;

#[derive(serde::Deserialize)]
struct VectorFile {
    version: i32,
    #[serde(rename = "byeReasons", default)]
    bye_reasons: Vec<String>,
    #[serde(rename = "invalidByeReasons", default)]
    invalid_bye_reasons: Vec<String>,
    cases: Vec<Case>,
    #[serde(default)]
    relay: RelayVectors,
}

#[derive(serde::Deserialize, Default)]
struct RelayVectors {
    accepted: Vec<RelayAccepted>,
    rejected: Vec<RelayRejected>,
}

#[derive(serde::Deserialize)]
struct RelayAccepted {
    name: String,
    #[serde(rename = "type")]
    msg_type: String,
    input: String,
    output: String,
}

#[derive(serde::Deserialize)]
struct RelayRejected {
    name: String,
    #[serde(rename = "type")]
    msg_type: String,
    input: String,
}

#[derive(serde::Deserialize)]
struct Case {
    name: String,
    surface: String,
    #[serde(rename = "type")]
    msg_type: String,
    frame: Value,
    #[serde(default)]
    #[allow(dead_code)]
    note: String,
}

const VECTORS: &str = include_str!("../../../../protocol/vectors/vectors.json");

fn json_eq(a: &Value, b: &Value) -> bool {
    let empty_collection = |v: &Value| match v {
        Value::Array(a) => a.is_empty(),
        Value::Object(o) => o.is_empty(),
        _ => false,
    };
    if (a.is_null() && empty_collection(b)) || (b.is_null() && empty_collection(a)) {
        return true;
    }
    match (a, b) {
        (Value::Number(x), Value::Number(y)) => {
            if let (Some(x), Some(y)) = (x.as_i64(), y.as_i64()) {
                return x == y;
            }
            if let (Some(x), Some(y)) = (x.as_u64(), y.as_u64()) {
                return x == y;
            }
            match (x.as_f64(), y.as_f64()) {
                (Some(x), Some(y)) => x == y || (x.is_nan() && y.is_nan()),
                _ => false,
            }
        }
        (Value::Array(x), Value::Array(y)) => {
            x.len() == y.len() && x.iter().zip(y).all(|(x, y)| json_eq(x, y))
        }
        (Value::Object(x), Value::Object(y)) => {
            x.len() == y.len()
                && x.iter()
                    .all(|(k, xv)| y.get(k).map(|yv| json_eq(xv, yv)).unwrap_or(false))
        }
        _ => a == b,
    }
}

fn roundtrip<T>(case: &Case, env: &Envelope)
where
    T: serde::de::DeserializeOwned + Serialize,
{
    let decoded: T = env.payload_as().unwrap_or_else(|e| {
        panic!(
            "case {:?} ({}): payload did not decode as {}: {e}",
            case.name,
            case.msg_type,
            std::any::type_name::<T>()
        )
    });
    let reencoded = serde_json::to_value(&decoded).expect("re-encode");
    assert!(
        json_eq(&env.payload, &reencoded),
        "case {:?} ({}) did not round-trip through {}\n  Go produced: {}\n  Rust re-encoded: {}",
        case.name,
        case.msg_type,
        std::any::type_name::<T>(),
        serde_json::to_string(&env.payload).unwrap(),
        serde_json::to_string(&reencoded).unwrap(),
    );
}

#[test]
fn every_go_vector_round_trips_through_the_rust_types() {
    let file: VectorFile = serde_json::from_str(VECTORS).expect("vectors.json parses");
    assert_eq!(file.version, rc_proto::VERSION, "vector file version");
    assert!(
        file.cases.len() >= 60,
        "vector file looks truncated: {} cases",
        file.cases.len()
    );

    let mut seen_types = std::collections::BTreeSet::new();

    for case in &file.cases {
        let bytes = serde_json::to_vec(&case.frame).unwrap();
        let env = Envelope::decode(&bytes)
            .unwrap_or_else(|e| panic!("case {:?}: envelope did not decode: {e}", case.name));

        assert_eq!(env.v, rc_proto::VERSION, "case {:?}", case.name);
        assert_eq!(env.msg_type, case.msg_type, "case {:?}", case.name);
        assert!(
            env.payload.is_object(),
            "case {:?}: payload must be an object, never null",
            case.name
        );
        seen_types.insert(format!("{}/{}", case.surface, case.msg_type));

        use rc_proto::consts::{ctrl as c, hi as h, msg as m};
        match case.msg_type.as_str() {
            m::CHALLENGE => roundtrip::<sig::Challenge>(case, &env),
            m::REGISTER => roundtrip::<sig::Register>(case, &env),
            m::REGISTER_OK => roundtrip::<sig::RegisterOk>(case, &env),
            m::HELLO => roundtrip::<sig::Hello>(case, &env),
            m::HELLO_OK => roundtrip::<sig::HelloOk>(case, &env),
            m::HEARTBEAT => assert!(env.payload.as_object().unwrap().is_empty()),
            m::HEARTBEAT_OK => roundtrip::<sig::HeartbeatOk>(case, &env),
            m::WATCH | m::WATCH_OK | m::UNWATCH | m::UNWATCH_OK => {
                roundtrip::<sig::DeviceRef>(case, &env)
            }
            m::PRESENCE => roundtrip::<sig::Presence>(case, &env),
            m::CONNECT_REQ => roundtrip::<sig::ConnectReq>(case, &env),
            m::CONNECT_OK => roundtrip::<sig::ConnectOk>(case, &env),
            m::SESSION_START => roundtrip::<sig::SessionStart>(case, &env),
            m::RESUME | m::RENEW => roundtrip::<sig::Resume>(case, &env),
            m::RESUME_OK => roundtrip::<sig::ResumeOk>(case, &env),
            m::RENEW_OK => roundtrip::<sig::RenewOk>(case, &env),
            m::PEER_STATE => roundtrip::<sig::PeerState>(case, &env),
            m::SDP => roundtrip::<sig::Sdp>(case, &env),
            m::ICE => roundtrip::<relay::Ice>(case, &env),
            m::ICE_SERVERS => roundtrip::<sig::IceServers>(case, &env),
            m::BYE => roundtrip::<sig::Bye>(case, &env),
            m::REFRESH_CODE => roundtrip::<sig::CodeVerifier>(case, &env),
            m::REFRESH_CODE_OK => roundtrip::<sig::RefreshCodeOk>(case, &env),
            m::PAKE => roundtrip::<sig::Pake>(case, &env),
            m::ERROR => roundtrip::<sig::ErrorPayload>(case, &env),

            c::MOUSE_DOWN | c::MOUSE_UP | c::MOUSE_DRAG => {
                roundtrip::<ctrl::MouseEvent>(case, &env)
            }
            c::CLICK => roundtrip::<ctrl::Click>(case, &env),
            c::KEY_DOWN | c::KEY_UP => roundtrip::<ctrl::KeyEvent>(case, &env),
            c::SCROLL => roundtrip::<ctrl::Scroll>(case, &env),
            c::CLIPBOARD_TEXT => roundtrip::<ctrl::ClipboardText>(case, &env),
            c::GESTURE => roundtrip::<ctrl::Gesture>(case, &env),
            c::INPUT_RESET => assert!(env.payload.as_object().unwrap().is_empty()),
            c::DISPLAY_INFO => roundtrip::<ctrl::DisplayInfo>(case, &env),
            c::QUALITY => roundtrip::<ctrl::Quality>(case, &env),
            c::PING | c::PONG => roundtrip::<ctrl::Ping>(case, &env),
            c::SESSION_CLOSE => roundtrip::<ctrl::SessionClose>(case, &env),
            c::CURSOR_SHAPE => roundtrip::<ctrl::CursorShape>(case, &env),

            h::MOUSE_MOVE => roundtrip::<ctrl::MouseMove>(case, &env),

            other => panic!(
                "case {:?}: message type {other:?} has no Rust type in this test. \
                 A new protocol message must be added here, not silently skipped.",
                case.name
            ),
        }
    }

    for t in [
        "signaling/register",
        "signaling/hello_ok",
        "signaling/connect_ok",
        "signaling/resume_ok",
        "signaling/error",
        "signaling/ice",
        "signaling/sdp",
        "signaling/ice_servers",
        "signaling/pake",
        "ctrl/key_down",
        "ctrl/scroll",
        "ctrl/gesture",
        "ctrl/display_info",
        "ctrl/clipboard_text",
        "ctrl/cursor_shape",
        "hi/mouse_move",
    ] {
        assert!(seen_types.contains(t), "vectors do not cover {t}");
    }
}

#[test]
fn bye_reasons_are_the_same_closed_set_as_go() {
    let file: VectorFile = serde_json::from_str(VECTORS).unwrap();
    let go: Vec<&str> = file.bye_reasons.iter().map(String::as_str).collect();
    assert_eq!(go, rc_proto::consts::bye::ALL.to_vec());
    assert!(!file.invalid_bye_reasons.is_empty());
    for reason in &file.invalid_bye_reasons {
        assert!(
            !rc_proto::consts::bye::is_valid(reason),
            "{reason:?} must be refused"
        );
    }
    for case in &file.cases {
        if case.msg_type == rc_proto::consts::msg::BYE {
            let bye: sig::Bye = serde_json::from_value(case.frame["payload"].clone()).unwrap();
            assert!(
                rc_proto::consts::bye::is_valid(&bye.reason),
                "{}",
                case.name
            );
            assert!(rc_proto::valid_session_id(&bye.session_id), "{}", case.name);
        }
    }
}

#[test]
fn session_ids_are_32_lowercase_hex() {
    assert!(rc_proto::valid_session_id(
        "8c7f1a2b3c4d5e6f708192a3b4c5d6e7"
    ));
    for bad in [
        "",
        "8C7F1A2B3C4D5E6F708192A3B4C5D6E7",
        "8c7f1a2b3c4d5e6f708192a3b4c5d6e",
        "8c7f1a2b3c4d5e6f708192a3b4c5|d6e",
    ] {
        assert!(!rc_proto::valid_session_id(bad), "{bad:?}");
    }
}

#[test]
fn v5_turn_arrives_only_in_ice_servers_and_metered_renewals() {
    let file: VectorFile = serde_json::from_str(VECTORS).unwrap();
    let find = |name: &str| {
        let case = file.cases.iter().find(|c| c.name == name).unwrap();
        Envelope::decode(&serde_json::to_vec(&case.frame).unwrap()).unwrap()
    };
    let no_credentials = |servers: &[sig::IceServer]| {
        servers
            .iter()
            .all(|s| s.credential.is_empty() && s.username.is_empty())
    };
    let ok: sig::ConnectOk = find("connect_ok_with_ice_servers").payload_as().unwrap();
    assert!(!ok.ice_servers.is_empty() && no_credentials(&ok.ice_servers));
    let start: sig::SessionStart = find("session_start").payload_as().unwrap();
    assert!(no_credentials(&start.session.ice_servers));

    let env = find("ice_servers");
    let push: sig::IceServers = env.payload_as().unwrap();
    let turn = push
        .ice_servers
        .iter()
        .find(|s| !s.credential.is_empty())
        .unwrap();
    assert!(turn.username.ends_with(&format!(":{}", push.session_id)));
    assert_eq!(
        turn.expires_at - env.ts,
        i64::from(rc_proto::consts::tunable::TURN_CRED_TTL_SEC) * 1000
    );
    let renew: sig::RenewOk = find("renew_ok").payload_as().unwrap();
    assert_eq!(renew.ice_servers, push.ice_servers);
    let unmetered: sig::RenewOk = find("renew_ok_no_ice_servers").payload_as().unwrap();
    assert!(unmetered.ice_servers.is_empty());

    let hello: sig::HelloOk = find("hello_ok_with_active_session").payload_as().unwrap();
    assert!(no_credentials(&hello.ice_servers));
    assert!(!hello.id_cert.is_empty());
    let registered: sig::RegisterOk = find("register_ok_existing").payload_as().unwrap();
    assert!(!registered.id_cert.is_empty());
    let register: sig::Register = find("register_with_id_cert").payload_as().unwrap();
    assert!(!register.id_cert.is_empty() && !register.preferred_device_id.is_empty());
}

#[test]
fn relay_vectors_decode_strictly_and_reencode_exactly_as_go() {
    let file: VectorFile = serde_json::from_str(VECTORS).unwrap();
    assert!(!file.relay.accepted.is_empty() && file.relay.rejected.len() >= 30);
    for case in &file.relay.accepted {
        let decoded = relay::decode(&case.msg_type, &case.input)
            .unwrap_or_else(|e| panic!("{}: refused: {e}", case.name));
        assert_eq!(decoded.encode(), case.output, "{}", case.name);
    }
    for case in &file.relay.rejected {
        assert!(
            relay::decode(&case.msg_type, &case.input).is_err(),
            "{}: accepted {:.80}",
            case.name,
            case.input
        );
    }
    use rc_proto::consts::msg as m;
    let mut relayed = 0;
    for case in &file.cases {
        if ![m::SDP, m::ICE, m::PAKE].contains(&case.msg_type.as_str()) {
            continue;
        }
        relayed += 1;
        let payload = serde_json::to_string(&case.frame["payload"]).unwrap();
        let decoded = relay::decode(&case.msg_type, &payload)
            .unwrap_or_else(|e| panic!("{}: refused: {e}", case.name));
        let reencoded: Value = serde_json::from_str(&decoded.encode()).unwrap();
        assert_eq!(reencoded, case.frame["payload"], "{}", case.name);
    }
    assert!(relayed >= 8);
}

#[test]
fn ice_candidate_grammar_matches_go() {
    for ok in [
        "candidate:1 1 udp 2130706431 192.0.2.1 54321 typ host",
        "candidate:a+/Z 256 UDP 0 ::1 0 typ relay raddr 198.51.100.1 rport 3478",
        "candidate:1 1 tcp 1 3F1C6E0A-9B2D-4C5E-8F7A-1D2E3F4A5B6C.local 9 typ host tcptype passive",
    ] {
        assert!(relay::valid_ice_candidate(ok), "{ok}");
    }
    let too_many = format!(
        "candidate:1 1 udp 1 192.0.2.1 1 typ host{}",
        " a b".repeat(rc_proto::consts::relay::MAX_CANDIDATE_EXTENSIONS + 1)
    );
    let long_foundation = format!("candidate:{} 1 udp 1 192.0.2.1 1 typ host", "a".repeat(33));
    for bad in [
        "",
        "candidate:",
        "candidate:1 0 udp 1 192.0.2.1 1 typ host",
        "candidate:1 257 udp 1 192.0.2.1 1 typ host",
        "candidate:1 1 sctp 1 192.0.2.1 1 typ host",
        "candidate:1 1 udp 4294967296 192.0.2.1 1 typ host",
        "candidate:1 1 udp 1 192.0.2.1 65536 typ host",
        "candidate:1 1 udp 1 192.0.2.1 1 type host",
        "candidate:1 1 udp 1 fe80::1%en0 1 typ host",
        "candidate:1 1 udp 1 01.2.3.4 1 typ host",
        "candidate:1 1 udp 1 3f1c6e0a9b2d4c5e8f7a1d2e3f4a5b6c0000.local 1 typ host",
        "candidate:1 1 udp 1 192.0.2.1 1 typ host Generation 0",
        "candidate:1 1 udp 1 192.0.2.1 1 typ host ufrag a\tb",
        long_foundation.as_str(),
        too_many.as_str(),
    ] {
        assert!(!relay::valid_ice_candidate(bad), "{bad:?}");
    }
}

#[test]
fn vectors_cover_every_gesture() {
    let file: VectorFile = serde_json::from_str(VECTORS).unwrap();
    let mut found = std::collections::BTreeSet::new();
    for case in &file.cases {
        if case.msg_type == rc_proto::consts::ctrl::GESTURE {
            let g: ctrl::Gesture = serde_json::from_value(case.frame["payload"].clone()).unwrap();
            let name = ctrl::GestureName::from_wire(&g.name)
                .unwrap_or_else(|| panic!("unknown gesture {:?} in vectors", g.name));
            found.insert(name.as_wire());
        }
    }
    for g in ctrl::GestureName::ALL {
        assert!(
            found.contains(g.as_wire()),
            "no vector for gesture {:?}",
            g.as_wire()
        );
    }
}

#[test]
fn vectors_cover_every_cursor_shape_and_nothing_else() {
    let file: VectorFile = serde_json::from_str(VECTORS).unwrap();
    let mut found = std::collections::BTreeSet::new();
    for case in &file.cases {
        if case.msg_type == rc_proto::consts::ctrl::CURSOR_SHAPE {
            let c: ctrl::CursorShape =
                serde_json::from_value(case.frame["payload"].clone()).unwrap();
            let name = ctrl::CursorShapeName::from_wire(&c.shape);
            assert_eq!(
                name.as_wire(),
                c.shape,
                "unknown cursor shape {:?} in vectors",
                c.shape
            );
            found.insert(name.as_wire());
        }
    }
    for shape in ctrl::CursorShapeName::ALL {
        assert!(
            found.contains(shape.as_wire()),
            "no vector for cursor shape {:?}",
            shape.as_wire()
        );
    }
}

#[test]
fn an_unknown_cursor_shape_is_drawn_as_the_arrow() {
    assert_eq!(
        ctrl::CursorShapeName::from_wire("zoom_in"),
        ctrl::CursorShapeName::Arrow
    );
}
