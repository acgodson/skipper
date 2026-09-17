use super::*;

const LIBWEBRTC_CANDIDATE: &str =
    "candidate:842163049 1 udp 1677729535 192.0.2.10 50000 typ srflx raddr 10.0.0.2 rport 50000 generation 0 ufrag Ab12 network-cost 999";

#[test]
fn only_steps_one_to_three_are_accepted() {
    for step in 1..=3 {
        assert_eq!(pake_step(step), Ok(step as u8));
    }
    for bad in [
        0,
        -1,
        4,
        4_294_967_296,
        i64::MAX,
        i64::MIN,
        i64::from(u32::MAX) + 1,
    ] {
        assert_eq!(pake_step(bad), Err(RelayError::PakeStep), "{bad}");
    }
}

#[test]
fn a_pake_payload_is_bounded_padded_base64() {
    for good in ["QUJD", "QUI=", "QQ==", &"A".repeat(PAKE_PAYLOAD_MAX_BASE64)] {
        assert!(pake_payload(good).is_ok(), "{good:.20}");
    }
    for bad in [
        String::new(),
        "A".repeat(PAKE_PAYLOAD_MAX_BASE64 + 4),
        "QUJ".into(),
        "Q===".into(),
        "QU=D".into(),
        "QU JD".into(),
        "QUJD\n".into(),
        "QUJD-_==".into(),
    ] {
        assert_eq!(pake_payload(&bad), Err(RelayError::PakePayload), "{bad:?}");
    }
}

#[test]
fn an_sdp_starts_with_the_version_line_and_is_capped() {
    assert!(sdp_body("v=0\r\no=- 1 2 IN IP4 127.0.0.1\r\n").is_ok());
    let at_cap = format!("v=0{}", "a".repeat(SDP_MAX_BYTES - 3));
    assert!(sdp_body(&at_cap).is_ok());
    for bad in [
        String::new(),
        "o=- 1 2 IN IP4 127.0.0.1\r\n".into(),
        " v=0\r\n".into(),
        "v=0\r\n\0".into(),
        format!("{at_cap}a"),
    ] {
        assert_eq!(sdp_body(&bad), Err(RelayError::Sdp));
    }
}

#[test]
fn real_candidate_lines_and_the_end_marker_parse() {
    for line in [
        "",
        LIBWEBRTC_CANDIDATE,
        "candidate:1 1 UDP 2122260223 192.168.1.20 61234 typ host",
        "candidate:3 1 tcp 1518280447 192.168.1.20 9 typ host tcptype active generation 0",
        "candidate:4 1 udp 41885439 203.0.113.9 3478 typ relay raddr 198.51.100.4 rport 60000",
        "candidate:5 1 udp 2122262783 2001:db8::1 51000 typ host",
        "candidate:6 1 udp 2122260223 0b1e7c1a-2f7d-4b8e-9a3c-4f1d2e3c4b5a.local 55000 typ host",
        "candidate:a+b/c 256 udp 4294967295 192.0.2.1 65535 typ prflx",
    ] {
        assert_eq!(candidate(line), Ok(()), "{line}");
    }
}

#[test]
fn anything_that_is_not_a_candidate_line_is_refused() {
    let too_many = format!(
        "candidate:1 1 udp 1 192.0.2.1 1 typ host{}",
        " a 1".repeat(CANDIDATE_MAX_EXTENSIONS + 1)
    );
    let too_long = format!(
        "candidate:1 1 udp 1 192.0.2.1 1 typ host k {}",
        "v".repeat(CANDIDATE_MAX_BYTES)
    );
    for bad in [
        "candidate:",
        "a=candidate:1 1 udp 2122260223 192.168.1.20 61234 typ host",
        "candidate:1 1 udp 2122260223 192.168.1.20 61234 typ",
        "candidate:1 1 udp 2122260223 192.168.1.20 61234 type host",
        "candidate:1 1 udp 2122260223 192.168.1.20 61234 typ bogus",
        "candidate:1 0 udp 2122260223 192.168.1.20 61234 typ host",
        "candidate:1 257 udp 2122260223 192.168.1.20 61234 typ host",
        "candidate:1 1 sctp 2122260223 192.168.1.20 61234 typ host",
        "candidate:1 1 udp 4294967296 192.168.1.20 61234 typ host",
        "candidate:1 1 udp 2122260223 192.168.1.20 65536 typ host",
        "candidate:1 1 udp -1 192.168.1.20 61234 typ host",
        "candidate:1 1 udp 2122260223 192.168.1.20 61234 typ host\r\na=evil",
        "candidate:1  1 udp 2122260223 192.168.1.20 61234 typ host",
        "candidate:1 1 udp 2122260223 192.168.1.20 61234 typ host ",
        "candidate:1 1 udp 2122260223 evil.example 61234 typ host",
        "candidate:1 1 udp 2122260223 not-a-uuid.local 61234 typ host",
        "candidate:1 1 udp 2122260223 192.168.1.20 61234 typ host generation",
        "candidate:1 1 udp 2122260223 192.168.1.20 61234 typ host Generation 0",
        "candidate:1 1 udp 2122260223 192.168.1.20 61234 typ host ufrag caf\u{e9}",
        "candidate:123456789012345678901234567890123 1 udp 1 192.0.2.1 1 typ host",
        too_many.as_str(),
        too_long.as_str(),
    ] {
        assert_eq!(candidate(bad), Err(RelayError::Candidate), "{bad:?}");
    }
}

#[test]
fn media_ids_and_indices_are_bounded() {
    for good in [String::new(), "0".into(), "m".repeat(SDP_MID_MAX_BYTES)] {
        assert!(sdp_mid(&good).is_ok(), "{good:?}");
    }
    for bad in [
        "m".repeat(SDP_MID_MAX_BYTES + 1),
        "a b".into(),
        "a|b".into(),
        "\u{e9}".into(),
    ] {
        assert_eq!(sdp_mid(&bad), Err(RelayError::SdpMid), "{bad:?}");
    }
    assert_eq!(m_line_index(0), Ok(0));
    assert_eq!(m_line_index(65_535), Ok(65_535));
    for bad in [-1, 65_536, 4_294_967_296, i64::MAX] {
        assert_eq!(m_line_index(bad), Err(RelayError::MLineIndex), "{bad}");
    }
}

#[test]
fn signature_fields_are_bounded_base64() {
    assert!(base64_field("mac", "", MAC_MAX_BYTES).is_ok());
    assert!(base64_field("mac", &"A".repeat(MAC_MAX_BYTES), MAC_MAX_BYTES).is_ok());
    for bad in [
        "A".repeat(MAC_MAX_BYTES + 1),
        "MEUC IQ".into(),
        "MEUC\nIQ".into(),
        "MEUC-_".into(),
    ] {
        assert_eq!(
            base64_field("mac", &bad, MAC_MAX_BYTES),
            Err(RelayError::Field("mac")),
            "{bad:?}"
        );
    }
}

#[test]
fn a_fingerprint_list_keeps_its_spaces_and_newlines_but_nothing_else() {
    assert!(fingerprint_list("sha-256 AA:BB\nsha-384 CC:DD").is_ok());
    assert!(fingerprint_list(&"A".repeat(FINGERPRINTS_MAX_BYTES)).is_ok());
    for bad in [
        "A".repeat(FINGERPRINTS_MAX_BYTES + 1),
        "sha-256 AA\r\nsha-256 BB".into(),
        "sha-256 AA\t".into(),
        "sha-256 AA|x".into(),
        "sha-256 \u{e9}".into(),
    ] {
        assert_eq!(
            fingerprint_list(&bad),
            Err(RelayError::Field("fp")),
            "{bad:?}"
        );
    }
}
