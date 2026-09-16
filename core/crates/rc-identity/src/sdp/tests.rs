use super::*;
use crate::DeviceKey;

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

fn signed(key: &DeviceKey, session: &str, sdp_type: &str, fp: &str) -> String {
    key.sign_base64(&message_to_sign(session, sdp_type, fp).unwrap())
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
    let sig = signed(&key, SESSION, "offer", FP);
    let pubkey = key.public_key_spki_base64();
    verify(SESSION, "offer", OFFER, FP, &pubkey, &sig, Some(&pubkey)).unwrap();
}

#[test]
fn a_fingerprint_swapped_by_the_relay_is_caught() {
    let key = DeviceKey::generate();
    let sig = signed(&key, SESSION, "offer", FP);
    let pubkey = key.public_key_spki_base64();
    let tampered = OFFER.replace("7B:8C", "7B:8D");
    assert_eq!(
        verify(
            SESSION,
            "offer",
            &tampered,
            FP,
            &pubkey,
            &sig,
            Some(&pubkey)
        )
        .unwrap_err(),
        SdpAuthError::FingerprintMismatch
    );
}

#[test]
fn a_relay_that_signs_the_swapped_fingerprint_with_its_own_key_is_caught() {
    let peer = DeviceKey::generate();
    let relay = DeviceKey::generate();
    let tampered = OFFER.replace("7B:8C", "7B:8D");
    let tampered_fp = fingerprints(&tampered).unwrap();
    let sig = signed(&relay, SESSION, "offer", &tampered_fp);
    assert_eq!(
        verify(
            SESSION,
            "offer",
            &tampered,
            &tampered_fp,
            &relay.public_key_spki_base64(),
            &sig,
            Some(&peer.public_key_spki_base64()),
        )
        .unwrap_err(),
        SdpAuthError::UnexpectedPeer
    );
}

#[test]
fn a_signature_from_another_session_does_not_verify() {
    let key = DeviceKey::generate();
    let sig = signed(&key, "0000000000000000000000000000dead", "offer", FP);
    let pubkey = key.public_key_spki_base64();
    assert_eq!(
        verify(SESSION, "offer", OFFER, FP, &pubkey, &sig, Some(&pubkey)).unwrap_err(),
        SdpAuthError::SignatureRejected
    );
}

#[test]
fn an_offer_signature_cannot_be_replayed_as_an_answer() {
    let key = DeviceKey::generate();
    let sig = signed(&key, SESSION, "offer", FP);
    let pubkey = key.public_key_spki_base64();
    assert_eq!(
        verify(SESSION, "answer", OFFER, FP, &pubkey, &sig, Some(&pubkey)).unwrap_err(),
        SdpAuthError::SignatureRejected
    );
}

#[test]
fn a_malformed_pubkey_or_signature_is_rejected_rather_than_panicking() {
    let key = DeviceKey::generate();
    let sig = signed(&key, SESSION, "offer", FP);
    assert_eq!(
        verify(SESSION, "offer", OFFER, FP, "not base64!", &sig, None).unwrap_err(),
        SdpAuthError::BadPubkey
    );
    assert_eq!(
        verify(
            SESSION,
            "offer",
            OFFER,
            FP,
            &key.public_key_spki_base64(),
            "///not a signature",
            None
        )
        .unwrap_err(),
        SdpAuthError::BadSignature
    );
}
