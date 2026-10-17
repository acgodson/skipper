//! The blocker this host carried: it built SDP answers with an empty `fp`,
//! `pubkey`, `sig` and `mac`, which the shipping Mac controller verifies and
//! must reject.
//!
//! What makes these tests proof rather than restatement is the verifier. The
//! Mac does not have a §2.12 implementation of its own: `SdpAuth.verify`
//! (`apps/macos/Sources/SkipperCore/SdpAuth.swift`) calls `skipper_sdp_verify`
//! in `core/crates/rc-ffi`, which calls `rc_identity::sdp::verify` — the
//! function used below. A controller-side `PakeExchange` from the same shared
//! crate derives the MAC key, so the key the answer is MACed under is the one
//! the other machine would actually hold.

use rc_identity::pake::PakeExchange;
use rc_identity::sdp::{self, Presented, SdpAuthError, MAC_KEY_LEN};
use rc_identity::{DeviceKey, SigningPurpose};

const HOST_DEVICE_ID: &str = "481930275";
const SESSION: &str = "0123456789abcdef0123456789abcdef";
const CODE: &str = "ABCD1234EFGH";

/// A realistic answer: two media sections carrying the same fingerprint, plus
/// inline candidates, because both are what a WebRTC stack actually emits and
/// both are what the de-duplicating, sorting `fp` rule has to cope with.
const ANSWER: &str = "v=0\r\n\
o=- 4611731400430051336 2 IN IP4 127.0.0.1\r\n\
s=-\r\n\
t=0 0\r\n\
a=group:BUNDLE 0 1\r\n\
m=video 9 UDP/TLS/RTP/SAVPF 96\r\n\
c=IN IP4 0.0.0.0\r\n\
a=candidate:1 1 udp 2130706431 192.0.2.7 50000 typ host\r\n\
a=mid:0\r\n\
a=fingerprint:sha-256 7B:8C:1D:2E:3F:40:51:62:73:84:95:A6:B7:C8:D9:EA:FB:0C:1D:2E:3F:40:51:62:73:84:95:A6:B7:C8:D9:EA\r\n\
a=setup:active\r\n\
a=sendonly\r\n\
m=application 9 UDP/DTLS/SCTP webrtc-datachannel\r\n\
c=IN IP4 0.0.0.0\r\n\
a=mid:1\r\n\
a=fingerprint:sha-256 7B:8C:1D:2E:3F:40:51:62:73:84:95:A6:B7:C8:D9:EA:FB:0C:1D:2E:3F:40:51:62:73:84:95:A6:B7:C8:D9:EA\r\n\
a=setup:active\r\n";

struct Scratch(std::path::PathBuf);

impl Scratch {
    fn new(tag: &str) -> Self {
        let path = std::env::temp_dir().join(format!(
            "rc-answer-{tag}-{}-{:?}",
            std::process::id(),
            std::thread::current().id()
        ));
        let _ = std::fs::remove_dir_all(&path);
        Self(path)
    }
}

impl Drop for Scratch {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}

/// What the Mac controller holds after the §2.17 exchange: the MAC key it
/// derived, and the host key the transcript bound (which it also requires to
/// equal `connect_ok.hostPubkey`).
struct Controller {
    mac_key: [u8; MAC_KEY_LEN],
    expected_host_pubkey: String,
}

/// A real three-step exchange, driven through the host's own orchestration on
/// one side and `rc_identity`'s controller on the other.
fn exchange(scratch: &Scratch, host_key: &DeviceKey, code: &str) -> (Controller, [u8; MAC_KEY_LEN]) {
    let secrets = rc_host::SecretStore::open(scratch.0.clone()).unwrap();
    let guesses = rc_host::GuessStore::new(&secrets);
    let controller_key = DeviceKey::generate();
    let controller_pubkey = controller_key.public_key_spki_base64();
    let host_pubkey = host_key.public_key_spki_base64();

    let mut host = rc_host::HostExchange::arm(
        &guesses,
        code,
        HOST_DEVICE_ID,
        SESSION,
        &host_pubkey,
        &controller_pubkey,
        1_000,
    )
    .unwrap();
    let mut controller =
        PakeExchange::controller(code, HOST_DEVICE_ID, SESSION, &controller_pubkey).unwrap();

    let step1 = controller.step(None).unwrap().unwrap();
    let step2 = host.step(&guesses, &step1, 1_000).unwrap().unwrap();
    let step3 = controller.step(Some(&step2)).unwrap().unwrap();
    host.step(&guesses, &step3, 1_000).unwrap();
    assert!(host.is_complete());

    (
        Controller {
            mac_key: controller.sdp_mac_key().unwrap(),
            expected_host_pubkey: controller.peer_public_key_base64(),
        },
        host.sdp_mac_key().unwrap(),
    )
}

/// Exactly what `Host::send_signed_sdp` puts on the wire.
fn signed_answer(
    host_key: &DeviceKey,
    mac_key: &[u8; MAC_KEY_LEN],
    session_id: &str,
    sdp_type: &str,
    body: &str,
) -> rc_proto::signaling::Sdp {
    let signable = sdp::signable(mac_key, session_id, sdp_type, body).unwrap();
    let payload = sdp::payload(session_id, sdp_type, &signable.fingerprints).unwrap();
    rc_proto::signaling::Sdp {
        session_id: session_id.to_string(),
        sdp_type: sdp_type.to_string(),
        sdp: body.to_string(),
        restart: false,
        fp: signable.fingerprints,
        pubkey: host_key.public_key_spki_base64(),
        sig: host_key.sign(SigningPurpose::Sdp, &payload).unwrap(),
        mac: signable.mac,
    }
}

fn verify(controller: &Controller, answer: &rc_proto::signaling::Sdp) -> Result<(), SdpAuthError> {
    sdp::verify(
        &controller.mac_key,
        &answer.session_id,
        &answer.sdp_type,
        &answer.sdp,
        &Presented {
            fingerprints: &answer.fp,
            pubkey: &answer.pubkey,
            sig: &answer.sig,
            mac: &answer.mac,
        },
        &controller.expected_host_pubkey,
    )
}

#[test]
fn the_answer_this_host_signs_passes_the_check_the_mac_performs() {
    let scratch = Scratch::new("accepted");
    let host_key = DeviceKey::generate();
    let (controller, host_mac_key) = exchange(&scratch, &host_key, CODE);

    let answer = signed_answer(&host_key, &host_mac_key, SESSION, "answer", ANSWER);
    assert!(!answer.fp.is_empty(), "fp is required (§2.12)");
    assert!(!answer.pubkey.is_empty(), "pubkey is required (§2.12)");
    assert!(!answer.sig.is_empty(), "sig is required (§2.12)");
    assert!(!answer.mac.is_empty(), "mac is required (§2.12, v3)");

    verify(&controller, &answer).expect("the Mac's own verifier must accept this answer");
}

/// The exact state this host shipped in. If `rc_identity::sdp::verify` ever
/// stopped refusing these, the Mac's verification would have been weakened —
/// which is the one thing that must never happen to make a host work.
#[test]
fn the_empty_fields_this_host_used_to_send_are_still_refused() {
    let scratch = Scratch::new("empty");
    let host_key = DeviceKey::generate();
    let (controller, host_mac_key) = exchange(&scratch, &host_key, CODE);

    let unsigned = rc_proto::signaling::Sdp {
        session_id: SESSION.to_string(),
        sdp_type: "answer".to_string(),
        sdp: ANSWER.to_string(),
        restart: false,
        fp: String::new(),
        pubkey: String::new(),
        sig: String::new(),
        mac: String::new(),
    };
    assert_eq!(verify(&controller, &unsigned), Err(SdpAuthError::NoFingerprint));

    let signed = signed_answer(&host_key, &host_mac_key, SESSION, "answer", ANSWER);
    for (field, broken) in [
        ("fp", rc_proto::signaling::Sdp { fp: String::new(), ..signed.clone() }),
        ("pubkey", rc_proto::signaling::Sdp { pubkey: String::new(), ..signed.clone() }),
        ("sig", rc_proto::signaling::Sdp { sig: String::new(), ..signed.clone() }),
        ("mac", rc_proto::signaling::Sdp { mac: String::new(), ..signed.clone() }),
    ] {
        assert!(
            verify(&controller, &broken).is_err(),
            "an answer with an empty {field} must be refused"
        );
    }
}

/// The MAC is the channel binding: a signature proves which device signed, the
/// MAC proves it was the device that proved the code **in this session**. A
/// relay that holds the host's public key cannot produce it.
#[test]
fn an_answer_macd_under_another_sessions_key_is_refused() {
    let scratch = Scratch::new("binding");
    let host_key = DeviceKey::generate();
    let (controller, _) = exchange(&scratch, &host_key, CODE);
    let (_, other_session_key) = exchange(&scratch, &host_key, CODE);

    let answer = signed_answer(&host_key, &other_session_key, SESSION, "answer", ANSWER);
    assert_eq!(verify(&controller, &answer), Err(SdpAuthError::MacRejected));
}

/// §2.12 step 5: the controller requires the host key the exchange bound. A
/// correctly signed answer from a *different* device is still refused.
#[test]
fn an_answer_from_another_device_key_is_refused() {
    let scratch = Scratch::new("impostor");
    let host_key = DeviceKey::generate();
    let (controller, host_mac_key) = exchange(&scratch, &host_key, CODE);

    let impostor = DeviceKey::generate();
    let answer = signed_answer(&impostor, &host_mac_key, SESSION, "answer", ANSWER);
    assert_eq!(verify(&controller, &answer), Err(SdpAuthError::UnexpectedPeer));
}

/// `sessionId` and `sdpType` are in the signed string, so a captured answer
/// cannot be replayed into another session or passed off as an offer.
#[test]
fn the_signature_does_not_carry_to_another_session_or_another_sdp_type() {
    let scratch = Scratch::new("replay");
    let host_key = DeviceKey::generate();
    let (controller, host_mac_key) = exchange(&scratch, &host_key, CODE);
    let answer = signed_answer(&host_key, &host_mac_key, SESSION, "answer", ANSWER);

    let other_session = rc_proto::signaling::Sdp {
        session_id: "fedcba9876543210fedcba9876543210".to_string(),
        ..answer.clone()
    };
    assert!(verify(&controller, &other_session).is_err());

    let as_offer = rc_proto::signaling::Sdp { sdp_type: "offer".to_string(), ..answer };
    assert!(verify(&controller, &as_offer).is_err());
}

/// §2.12 step 2: the signed fingerprints must be the ones in the body. A body
/// swapped after signing — what a compromised relay would do to read the
/// media — fails here.
#[test]
fn an_answer_whose_body_was_swapped_after_signing_is_refused() {
    let scratch = Scratch::new("swapped");
    let host_key = DeviceKey::generate();
    let (controller, host_mac_key) = exchange(&scratch, &host_key, CODE);
    let answer = signed_answer(&host_key, &host_mac_key, SESSION, "answer", ANSWER);

    let swapped = rc_proto::signaling::Sdp {
        sdp: ANSWER.replace("7B:8C:1D", "AA:BB:CC"),
        ..answer
    };
    assert_eq!(
        verify(&controller, &swapped),
        Err(SdpAuthError::FingerprintMismatch)
    );
}

/// A wrong code never reaches an `sdp` at all, because the host has no MAC key
/// to sign with: the exchange is what produces it.
#[test]
fn a_wrong_code_yields_no_mac_key_so_no_answer_can_be_sent() {
    let scratch = Scratch::new("wrongcode");
    let host_key = DeviceKey::generate();
    let secrets = rc_host::SecretStore::open(scratch.0.clone()).unwrap();
    let guesses = rc_host::GuessStore::new(&secrets);
    let controller_key = DeviceKey::generate();
    let controller_pubkey = controller_key.public_key_spki_base64();

    let mut host = rc_host::HostExchange::arm(
        &guesses,
        CODE,
        HOST_DEVICE_ID,
        SESSION,
        &host_key.public_key_spki_base64(),
        &controller_pubkey,
        1_000,
    )
    .unwrap();
    let mut controller =
        PakeExchange::controller("ZZZZ9999ZZZZ", HOST_DEVICE_ID, SESSION, &controller_pubkey)
            .unwrap();
    let step1 = controller.step(None).unwrap().unwrap();
    host.step(&guesses, &step1, 1_000).unwrap();

    assert!(
        host.sdp_mac_key().is_err(),
        "an incomplete exchange must not hand out a MAC key"
    );
}

/// An ICE restart is an ordinary re-offer: the answer to it is signed again,
/// over its own fingerprints.
#[test]
fn a_renegotiated_answer_is_signed_over_its_own_fingerprints() {
    let scratch = Scratch::new("restart");
    let host_key = DeviceKey::generate();
    let (controller, host_mac_key) = exchange(&scratch, &host_key, CODE);

    let restarted = ANSWER.replace("7B:8C:1D", "0A:1B:2C");
    let first = signed_answer(&host_key, &host_mac_key, SESSION, "answer", ANSWER);
    let second = signed_answer(&host_key, &host_mac_key, SESSION, "answer", &restarted);
    assert_ne!(first.fp, second.fp);
    assert_ne!(first.sig, second.sig);
    assert_ne!(first.mac, second.mac);
    verify(&controller, &first).unwrap();
    verify(&controller, &second).unwrap();
}

/// `fp` is every `a=fingerprint` value, de-duplicated and sorted — not the
/// first one. The two-m-line answer above is the case that catches a host that
/// signed only one of them.
#[test]
fn fp_covers_every_fingerprint_in_the_body() {
    let two = ANSWER.replacen(
        "a=fingerprint:sha-256 7B:8C:1D:2E:3F:40:51:62:73:84:95:A6:B7:C8:D9:EA:FB:0C:1D:2E:3F:40:51:62:73:84:95:A6:B7:C8:D9:EA\r\na=setup:active\r\na=sendonly",
        "a=fingerprint:sha-256 0A:0B:0C:0D:0E:0F:00:01:02:03:04:05:06:07:08:09:0A:0B:0C:0D:0E:0F:00:01:02:03:04:05:06:07:08:09\r\na=setup:active\r\na=sendonly",
        1,
    );
    let fp = sdp::fingerprints(&two).unwrap();
    let lines: Vec<&str> = fp.split('\n').collect();
    assert_eq!(lines.len(), 2, "both fingerprints must be signed: {fp}");
    assert!(lines.windows(2).all(|w| w[0] <= w[1]), "sorted: {fp}");
    assert_eq!(
        sdp::fingerprints(ANSWER).unwrap().split('\n').count(),
        1,
        "the same value twice is one entry"
    );
}
