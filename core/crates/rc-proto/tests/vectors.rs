use rc_proto::{ctrl, envelope::Envelope, signaling as sig};
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
            m::ICE => roundtrip::<sig::Ice>(case, &env),
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
    assert!(rc_proto::valid_session_id("8c7f1a2b3c4d5e6f708192a3b4c5d6e7"));
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
fn v4_session_messages_carry_session_scoped_ice_servers() {
    let file: VectorFile = serde_json::from_str(VECTORS).unwrap();
    let find = |name: &str| {
        let case = file.cases.iter().find(|c| c.name == name).unwrap();
        Envelope::decode(&serde_json::to_vec(&case.frame).unwrap()).unwrap()
    };
    let ok: sig::ConnectOk = find("connect_ok_with_ice_servers").payload_as().unwrap();
    let turn = ok.ice_servers.iter().find(|s| !s.credential.is_empty()).unwrap();
    assert!(turn.username.ends_with(&format!(":{}", ok.session_id)));
    let start: sig::SessionStart = find("session_start").payload_as().unwrap();
    assert_eq!(start.session.ice_servers, ok.ice_servers);
    let renew: sig::RenewOk = find("renew_ok").payload_as().unwrap();
    assert!(!renew.ice_servers.is_empty());
    let hello: sig::HelloOk = find("hello_ok_with_active_session").payload_as().unwrap();
    assert!(hello.ice_servers.iter().all(|s| s.credential.is_empty()));
    assert!(!hello.id_cert.is_empty());
    let registered: sig::RegisterOk = find("register_ok_existing").payload_as().unwrap();
    assert!(!registered.id_cert.is_empty());
    let register: sig::Register = find("register_with_id_cert").payload_as().unwrap();
    assert!(!register.id_cert.is_empty() && !register.preferred_device_id.is_empty());
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
