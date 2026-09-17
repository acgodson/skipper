use super::*;

const LIBWEBRTC_CANDIDATE: &str =
    "candidate:842163049 1 udp 1677729535 192.0.2.10 50000 typ srflx raddr 10.0.0.2 rport 50000 generation 0 ufrag Ab12 network-cost 999";

#[test]
fn real_candidate_lines_parse() {
    for line in [
        LIBWEBRTC_CANDIDATE,
        "candidate:1 1 UDP 2122260223 192.168.1.20 61234 typ host",
        "candidate:3 1 tcp 1518280447 192.168.1.20 9 typ host tcptype active generation 0",
        "candidate:4 1 udp 41885439 203.0.113.9 3478 typ relay raddr 198.51.100.4 rport 60000",
        "candidate:5 1 udp 2122262783 2001:db8::1 51000 typ host",
        "candidate:6 1 udp 2122260223 0b1e7c1a-2f7d-4b8e-9a3c-4f1d2e3c4b5a.local 55000 typ host",
        "candidate:a+b/c 256 udp 4294967295 192.0.2.1 65535 typ prflx",
    ] {
        assert!(valid_ice_candidate(line), "{line}");
    }
}

#[test]
fn anything_that_is_not_a_candidate_line_is_refused() {
    let too_many = format!(
        "candidate:1 1 udp 1 192.0.2.1 1 typ host{}",
        " a 1".repeat(lim::MAX_CANDIDATE_EXTENSIONS + 1)
    );
    let too_long = format!(
        "candidate:1 1 udp 1 192.0.2.1 1 typ host k {}",
        "v".repeat(lim::MAX_CANDIDATE_BYTES)
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
        assert!(!valid_ice_candidate(bad), "{bad:?}");
    }
}
