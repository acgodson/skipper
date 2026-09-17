use super::*;
use crate::DeviceKey;

const NONCE: [u8; NONCE_LEN] = [0x5a; NONCE_LEN];

#[test]
fn each_purpose_has_its_own_prefix() {
    for purpose in SigningPurpose::ALL {
        let payload: &[u8] = &NONCE;
        let message = signing_message(purpose, payload).unwrap();
        let prefix = format!("skipperdesk/{}/v1|", purpose.label());
        assert!(message.starts_with(prefix.as_bytes()), "{purpose:?}");
        assert_eq!(&message[prefix.len()..], payload);
    }
    assert_eq!(SigningPurpose::ApiChallenge.label(), "api-challenge");
}

#[test]
fn a_nonce_purpose_refuses_anything_but_thirty_two_bytes() {
    for purpose in [
        SigningPurpose::Hello,
        SigningPurpose::Register,
        SigningPurpose::ApiChallenge,
    ] {
        for len in [0, 31, 33, 64] {
            assert_eq!(
                signing_message(purpose, &vec![1u8; len]).unwrap_err(),
                SigningError::BadNonceLength {
                    purpose: purpose.label(),
                    len
                }
            );
        }
    }
    assert_eq!(
        signing_message(SigningPurpose::Sdp, b"").unwrap_err(),
        SigningError::EmptyPayload
    );
}

#[test]
fn a_signature_verifies_only_for_the_purpose_it_was_made_for() {
    let key = DeviceKey::generate();
    let pubkey = key.public_key_spki_base64();
    for signed_as in SigningPurpose::ALL {
        let sig = key.sign(signed_as, &NONCE).unwrap();
        for checked_as in SigningPurpose::ALL {
            let outcome = verify(checked_as, &NONCE, &pubkey, &sig);
            if checked_as == signed_as {
                outcome.unwrap();
            } else {
                assert_eq!(
                    outcome.unwrap_err(),
                    VerifyError::SignatureRejected,
                    "{signed_as:?} verified as {checked_as:?}"
                );
            }
        }
    }
}

#[test]
fn purpose_codes_round_trip_and_unknown_codes_are_refused() {
    for purpose in SigningPurpose::ALL {
        assert_eq!(SigningPurpose::from_code(purpose.code()).unwrap(), purpose);
    }
    assert_eq!(
        SigningPurpose::from_code(9).unwrap_err(),
        SigningError::UnknownPurpose(9)
    );
}

#[derive(serde::Deserialize)]
struct VectorFile {
    version: i32,
    cases: Vec<VectorCase>,
}

#[derive(serde::Deserialize)]
struct VectorCase {
    name: String,
    purpose: String,
    #[serde(rename = "payloadHex")]
    payload_hex: String,
    #[serde(rename = "messageHex")]
    message_hex: Option<String>,
    valid: bool,
}

fn hex(bytes: &[u8]) -> String {
    bytes.iter().map(|b| format!("{b:02x}")).collect()
}

fn unhex(text: &str) -> Vec<u8> {
    (0..text.len())
        .step_by(2)
        .map(|i| u8::from_str_radix(&text[i..i + 2], 16).unwrap())
        .collect()
}

#[test]
fn matches_the_shared_signing_vectors() {
    let path = concat!(
        env!("CARGO_MANIFEST_DIR"),
        "/../../../protocol/vectors/signing-vectors.json"
    );
    let file: VectorFile = serde_json::from_str(&std::fs::read_to_string(path).unwrap()).unwrap();
    assert_eq!(file.version, rc_proto::VERSION);
    assert!(!file.cases.is_empty());
    for case in file.cases {
        let purpose = SigningPurpose::ALL
            .into_iter()
            .find(|p| p.label() == case.purpose)
            .unwrap_or_else(|| panic!("{}: unknown purpose {}", case.name, case.purpose));
        let produced = signing_message(purpose, &unhex(&case.payload_hex));
        match (case.valid, produced) {
            (true, Ok(message)) => {
                assert_eq!(Some(hex(&message)), case.message_hex, "{}", case.name)
            }
            (false, Err(_)) => {}
            (valid, outcome) => panic!("{}: valid={valid} but got {outcome:?}", case.name),
        }
    }
}
