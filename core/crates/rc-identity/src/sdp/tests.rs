use super::*;
use crate::{DeviceKey, SigningPurpose};

const OFFER: &str = "v=0\r\n\
o=- 8175905011317297321 2 IN IP4 127.0.0.1\r\n\
s=-\r\n\
t=0 0\r\n\
a=group:BUNDLE 0 1\r\n\
a=msid-semantic: WMS\r\n\
m=application 9 UDP/DTLS/SCTP webrtc-datachannel\r\n\
c=IN IP4 0.0.0.0\r\n\
a=ice-ufrag:4ZcD\r\n\
a=ice-pwd:by/JAaPZxDJCWfRK1yBkasZM\r\n\
a=fingerprint:sha-256 7B:8C:1D:4F:2A:90:33:AE:BB:01:5C:6D:77:E8:99:0A:1B:2C:3D:4E:5F:60:71:82:93:A4:B5:C6:D7:E8:F9:0A\r\n\
a=setup:actpass\r\n\
a=mid:0\r\n\
a=sctp-port:5000\r\n\
m=video 9 UDP/TLS/RTP/SAVPF 96 97\r\n\
c=IN IP4 0.0.0.0\r\n\
a=ice-ufrag:4ZcD\r\n\
a=ice-pwd:by/JAaPZxDJCWfRK1yBkasZM\r\n\
a=fingerprint:sha-256 7B:8C:1D:4F:2A:90:33:AE:BB:01:5C:6D:77:E8:99:0A:1B:2C:3D:4E:5F:60:71:82:93:A4:B5:C6:D7:E8:F9:0A\r\n\
a=setup:actpass\r\n\
a=mid:1\r\n\
a=rtpmap:96 H264/90000\r\n";

const FP: &str = "sha-256 7B:8C:1D:4F:2A:90:33:AE:BB:01:5C:6D:77:E8:99:0A:1B:2C:3D:4E:5F:60:71:82:93:A4:B5:C6:D7:E8:F9:0A";
const SESSION: &str = "8c7f1a2b3c4d5e6f708192a3b4c5d6e7";

const MAC_KEY: [u8; MAC_KEY_LEN] = [7u8; MAC_KEY_LEN];
const OTHER_MAC_KEY: [u8; MAC_KEY_LEN] = [9u8; MAC_KEY_LEN];

struct Sent {
    pubkey: String,
    sig: String,
    mac: String,
}

fn signed(key: &DeviceKey, session: &str, sdp_type: &str, fp: &str) -> String {
    key.sign(
        SigningPurpose::Sdp,
        &payload(session, sdp_type, fp).unwrap(),
    )
    .unwrap()
}

fn sent(
    key: &DeviceKey,
    mac_key: &[u8; MAC_KEY_LEN],
    session: &str,
    sdp_type: &str,
    fp: &str,
) -> Sent {
    Sent {
        pubkey: key.public_key_spki_base64(),
        sig: signed(key, session, sdp_type, fp),
        mac: mac_base64(mac_key, &message_to_sign(session, sdp_type, fp).unwrap()),
    }
}

fn check(
    session: &str,
    sdp_type: &str,
    sdp: &str,
    fp: &str,
    sent: &Sent,
    expected: &str,
) -> Result<(), SdpAuthError> {
    verify(
        &MAC_KEY,
        session,
        sdp_type,
        sdp,
        &Presented {
            fingerprints: fp,
            pubkey: &sent.pubkey,
            sig: &sent.sig,
            mac: &sent.mac,
        },
        expected,
    )
}

#[test]
fn a_repeated_fingerprint_collapses_to_one_line() {
    assert_eq!(fingerprints(OFFER).unwrap(), FP);
}

#[test]
fn several_fingerprints_are_sorted_and_joined() {
    let sdp = "v=0\r\na=fingerprint:sha-256 BB:02\r\na=fingerprint:sha-256 AA:01\r\n";
    assert_eq!(fingerprints(sdp).unwrap(), "sha-256 AA:01\nsha-256 BB:02");
}

#[test]
fn an_sdp_without_a_fingerprint_is_refused() {
    assert_eq!(
        fingerprints("v=0\r\ns=-\r\n").unwrap_err(),
        SdpAuthError::NoFingerprint
    );
}

#[test]
fn a_signature_over_the_offer_verifies() {
    let key = DeviceKey::generate();
    let sent = sent(&key, &MAC_KEY, SESSION, "offer", FP);
    check(SESSION, "offer", OFFER, FP, &sent, &sent.pubkey).unwrap();
}

#[test]
fn a_fingerprint_swapped_by_the_relay_is_caught() {
    let key = DeviceKey::generate();
    let sent = sent(&key, &MAC_KEY, SESSION, "offer", FP);
    let tampered = OFFER.replace("7B:8C", "7B:8D");
    assert_eq!(
        check(SESSION, "offer", &tampered, FP, &sent, &sent.pubkey).unwrap_err(),
        SdpAuthError::FingerprintMismatch
    );
}

#[test]
fn a_relay_that_signs_the_swapped_fingerprint_with_its_own_key_is_caught() {
    let peer = DeviceKey::generate();
    let relay = DeviceKey::generate();
    let tampered = OFFER.replace("7B:8C", "7B:8D");
    let tampered_fp = fingerprints(&tampered).unwrap();
    let sent = sent(&relay, &MAC_KEY, SESSION, "offer", &tampered_fp);
    assert_eq!(
        check(
            SESSION,
            "offer",
            &tampered,
            &tampered_fp,
            &sent,
            &peer.public_key_spki_base64(),
        )
        .unwrap_err(),
        SdpAuthError::UnexpectedPeer
    );
}

#[test]
fn a_signature_from_another_session_does_not_verify() {
    let key = DeviceKey::generate();
    let mut sent = sent(&key, &MAC_KEY, SESSION, "offer", FP);
    sent.sig = signed(&key, "0000000000000000000000000000dead", "offer", FP);
    assert_eq!(
        check(SESSION, "offer", OFFER, FP, &sent, &sent.pubkey).unwrap_err(),
        SdpAuthError::SignatureRejected
    );
}

#[test]
fn an_offer_signature_cannot_be_replayed_as_an_answer() {
    let key = DeviceKey::generate();
    let mut sent = sent(&key, &MAC_KEY, SESSION, "offer", FP);
    sent.mac = mac_base64(&MAC_KEY, &message_to_sign(SESSION, "answer", FP).unwrap());
    assert_eq!(
        check(SESSION, "answer", OFFER, FP, &sent, &sent.pubkey).unwrap_err(),
        SdpAuthError::SignatureRejected
    );
}

#[test]
fn a_malformed_pubkey_or_signature_is_rejected_rather_than_panicking() {
    let key = DeviceKey::generate();
    let bad_pubkey = Sent {
        pubkey: "not base64!".to_string(),
        ..sent(&key, &MAC_KEY, SESSION, "offer", FP)
    };
    assert_eq!(
        check(
            SESSION,
            "offer",
            OFFER,
            FP,
            &bad_pubkey,
            &key.public_key_spki_base64()
        )
        .unwrap_err(),
        SdpAuthError::BadPubkey
    );
    let bad_sig = Sent {
        sig: "///not a signature".to_string(),
        ..sent(&key, &MAC_KEY, SESSION, "offer", FP)
    };
    assert_eq!(
        check(
            SESSION,
            "offer",
            OFFER,
            FP,
            &bad_sig,
            &key.public_key_spki_base64()
        )
        .unwrap_err(),
        SdpAuthError::BadSignature
    );
}

const RELAY_FP: &str = "sha-256 00:11:22:33:44:55:66:77:88:99:AA:BB:CC:DD:EE:FF:00:11:22:33:44:55:66:77:88:99:AA:BB:CC:DD:EE:FF";

fn nul_padded(sdp: &str) -> String {
    let session_level_real = format!("a=fingerprint:{FP}\r\na=x-pad:\0\r\n");
    sdp.replace(FP, RELAY_FP).replacen(
        "a=group:BUNDLE",
        &format!("{session_level_real}a=group:BUNDLE"),
        1,
    )
}

#[test]
fn c1_a_nul_padded_sdp_with_swapped_media_fingerprints_is_refused() {
    let peer = DeviceKey::generate();
    let answer = OFFER.replace("a=setup:actpass", "a=setup:active");
    for (sdp_type, body) in [("offer", OFFER.to_string()), ("answer", answer)] {
        let genuine = sent(&peer, &MAC_KEY, SESSION, sdp_type, FP);
        let attack = nul_padded(&body);
        let truncated = attack.split('\0').next().unwrap();
        assert_eq!(
            fingerprints(truncated).unwrap(),
            FP,
            "a verifier that stops at the NUL sees only the genuine fingerprint"
        );
        assert!(
            attack.contains(RELAY_FP),
            "the media sections carry the relay's"
        );
        assert_eq!(
            check(SESSION, sdp_type, &attack, FP, &genuine, &genuine.pubkey).unwrap_err(),
            SdpAuthError::MalformedSdp,
            "{sdp_type}"
        );
        let unpadded = attack.replace('\0', "");
        assert_eq!(
            check(SESSION, sdp_type, &unpadded, FP, &genuine, &genuine.pubkey).unwrap_err(),
            SdpAuthError::FingerprintMismatch,
            "{sdp_type}: the full body shows the relay's fingerprints"
        );
    }
}

#[test]
fn a_lone_carriage_return_is_refused() {
    let hidden = OFFER.replacen(
        "a=setup:actpass\r\n",
        &format!("a=setup:actpass\ra=fingerprint:{RELAY_FP}\r\n"),
        1,
    );
    assert_eq!(
        fingerprints(&hidden).unwrap_err(),
        SdpAuthError::MalformedSdp
    );
    assert_eq!(
        fingerprints("v=0\r").unwrap_err(),
        SdpAuthError::MalformedSdp
    );
    assert!(
        fingerprints(&format!("a=fingerprint:{FP}\n")).is_ok(),
        "bare LF is fine"
    );
}

#[test]
fn an_sdp_without_a_mac_is_refused() {
    let key = DeviceKey::generate();
    let unmacked = Sent {
        mac: String::new(),
        ..sent(&key, &MAC_KEY, SESSION, "offer", FP)
    };
    assert_eq!(
        check(SESSION, "offer", OFFER, FP, &unmacked, &unmacked.pubkey).unwrap_err(),
        SdpAuthError::MissingMac
    );
}

#[test]
fn a_mac_under_another_exchange_key_is_refused_even_with_a_valid_signature() {
    let key = DeviceKey::generate();
    let relayed = sent(&key, &OTHER_MAC_KEY, SESSION, "offer", FP);
    assert_eq!(
        check(SESSION, "offer", OFFER, FP, &relayed, &relayed.pubkey).unwrap_err(),
        SdpAuthError::MacRejected
    );
    let garbage = Sent {
        mac: "@@@".to_string(),
        ..sent(&key, &MAC_KEY, SESSION, "offer", FP)
    };
    assert_eq!(
        check(SESSION, "offer", OFFER, FP, &garbage, &garbage.pubkey).unwrap_err(),
        SdpAuthError::MacRejected
    );
}

#[test]
fn c2_a_server_chosen_nonce_cannot_become_an_sdp_signature() {
    let key = DeviceKey::generate();
    let wanted = message_to_sign(SESSION, "answer", RELAY_FP).unwrap();
    assert!(
        key.sign(SigningPurpose::Hello, &wanted).is_err(),
        "the SDP message is not a 32-byte nonce"
    );
    let short_fp = "sha-256 AB";
    let wanted = message_to_sign(SESSION, "answer", short_fp).unwrap();
    let nonce: [u8; 32] = wanted[..32].try_into().unwrap();
    let harvested = Sent {
        sig: key.sign(SigningPurpose::Hello, &nonce).unwrap(),
        ..sent(&key, &MAC_KEY, SESSION, "answer", short_fp)
    };
    let sdp = format!("v=0\r\na=fingerprint:{short_fp}\r\n");
    assert_eq!(
        check(
            SESSION,
            "answer",
            &sdp,
            short_fp,
            &harvested,
            &harvested.pubkey
        )
        .unwrap_err(),
        SdpAuthError::SignatureRejected
    );
}

#[test]
fn the_peer_pin_is_required_and_must_be_a_canonical_key() {
    let key = DeviceKey::generate();
    let sent = sent(&key, &MAC_KEY, SESSION, "offer", FP);
    for missing in ["", "host", "not a key"] {
        assert_eq!(
            check(SESSION, "offer", OFFER, FP, &sent, missing).unwrap_err(),
            SdpAuthError::NoExpectedPeer,
            "{missing:?}"
        );
    }
    let respelled = crate::signing::tests::compressed_spki(&key);
    assert_eq!(
        check(SESSION, "offer", OFFER, FP, &sent, &respelled).unwrap_err(),
        SdpAuthError::NoExpectedPeer
    );
    let presented_respelled = Sent {
        pubkey: respelled,
        ..sent
    };
    assert_eq!(
        check(
            SESSION,
            "offer",
            OFFER,
            FP,
            &presented_respelled,
            &key.public_key_spki_base64()
        )
        .unwrap_err(),
        SdpAuthError::BadPubkey
    );
}

#[test]
fn a_host_answer_reflected_back_to_the_host_is_refused() {
    let host = DeviceKey::generate();
    let controller = DeviceKey::generate();
    let answer = OFFER.replace("a=setup:actpass", "a=setup:active");
    let fp = fingerprints(&answer).unwrap();
    let reflected = sent(&host, &MAC_KEY, SESSION, "answer", &fp);
    assert_eq!(
        check(
            SESSION,
            "answer",
            &answer,
            &fp,
            &reflected,
            &controller.public_key_spki_base64()
        )
        .unwrap_err(),
        SdpAuthError::UnexpectedPeer
    );
}

#[test]
fn a_malformed_session_id_or_sdp_type_never_reaches_a_signature() {
    for (session, sdp_type, error) in [
        ("S|offer", "x", InputError::SessionId),
        ("sess-0001", "offer", InputError::SessionId),
        (SESSION, "pranswer", InputError::SdpType),
        (SESSION, "offer|x", InputError::SdpType),
    ] {
        assert_eq!(
            message_to_sign(session, sdp_type, FP).unwrap_err(),
            SdpAuthError::BadContext(error),
            "{session:?} {sdp_type:?}"
        );
        assert_eq!(
            signable(&MAC_KEY, session, sdp_type, OFFER).err(),
            Some(SdpAuthError::BadContext(error))
        );
    }
}

#[test]
fn every_candidate_line_is_stripped_and_nothing_else() {
    let with_candidates = OFFER
        .replace(
            "a=mid:0\r\n",
            "a=mid:0\r\na=candidate:1 1 udp 2122260223 203.0.113.9 50000 typ host\r\n  a=candidate:2 1 tcp 1 198.51.100.1 9 typ host\r\na=end-of-candidates\r\n",
        )
        .replace(
            "a=mid:1\r\n",
            "a=mid:1\r\na=candidate:3 1 udp 1 192.0.2.1 3478 typ relay\na=end-of-candidates \r\n",
        );
    let stripped = without_candidates(&with_candidates).unwrap();
    assert_eq!(stripped, OFFER);
    assert_eq!(fingerprints(&stripped).unwrap(), FP);
    assert_eq!(without_candidates(OFFER).unwrap(), OFFER);
    assert_eq!(
        without_candidates("a=candidate:1\ra=fingerprint:x\r\n").unwrap_err(),
        SdpAuthError::MalformedSdp
    );
    assert_eq!(
        without_candidates("v=0\r\na=candidate:1 1 udp 1 192.0.2.1 1 typ host").unwrap(),
        "v=0\r\n"
    );
}

#[test]
fn the_signed_message_is_the_documented_string() {
    assert_eq!(
        message_to_sign(SESSION, "offer", "sha-256 AA").unwrap(),
        format!("skipperdesk/sdp/v1|{SESSION}|offer|sha-256 AA").into_bytes()
    );
}
