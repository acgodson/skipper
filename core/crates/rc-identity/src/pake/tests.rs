use super::*;
use rand_core::{CryptoRng, RngCore};
use sha2::Digest;

const CODE: &str = "K7FM-3Q8P-W2XY";
const DEVICE: &str = "482719351";
const SESSION: &str = "sess-0001";

/// Device keys for the vectors, from a fixed scalar so the pinned transcript is
/// reproducible. Production keys come from the OS CSPRNG or the Secure Enclave.
fn vector_key(seed: u8) -> crate::DeviceKey {
    let mut raw = [1u8; 32];
    raw[31] = seed;
    crate::DeviceKey::from_raw(&raw).unwrap()
}

fn pubkey(seed: u8) -> String {
    vector_key(seed).public_key_spki_base64()
}

/// A SHA-256 counter stream, so `protocol/vectors/pake-vectors.json` can pin the
/// key schedule. Test-only: the product always uses `OsRng`.
pub(crate) struct SeededRng {
    seed: u8,
    counter: u64,
}

impl SeededRng {
    pub(crate) fn new(seed: u8) -> Self {
        Self { seed, counter: 0 }
    }
}

impl RngCore for SeededRng {
    fn next_u32(&mut self) -> u32 {
        let mut bytes = [0u8; 4];
        self.fill_bytes(&mut bytes);
        u32::from_le_bytes(bytes)
    }

    fn next_u64(&mut self) -> u64 {
        let mut bytes = [0u8; 8];
        self.fill_bytes(&mut bytes);
        u64::from_le_bytes(bytes)
    }

    fn fill_bytes(&mut self, dest: &mut [u8]) {
        for chunk in dest.chunks_mut(32) {
            let mut hasher = sha2::Sha256::new();
            hasher.update(b"skipperdesk-pake-test-rng");
            hasher.update([self.seed]);
            hasher.update(self.counter.to_be_bytes());
            let block = hasher.finalize();
            chunk.copy_from_slice(&block[..chunk.len()]);
            self.counter += 1;
        }
    }

    fn try_fill_bytes(&mut self, dest: &mut [u8]) -> Result<(), rand_core::Error> {
        self.fill_bytes(dest);
        Ok(())
    }
}

impl CryptoRng for SeededRng {}

struct Pair {
    controller: PakeExchange,
    host: PakeExchange,
}

fn pair(controller_code: &str, host_code: &str) -> Pair {
    Pair {
        controller: PakeExchange::controller(controller_code, DEVICE, SESSION, &pubkey(1))
            .unwrap(),
        host: PakeExchange::host(host_code, DEVICE, SESSION, &pubkey(2)).unwrap(),
    }
}

#[test]
fn happy_path_agrees_on_a_session_key() {
    let mut pair = pair(CODE, "k7fm3q8pw2xy");

    let step1 = pair.controller.step(None).unwrap().unwrap();
    assert_eq!(step1.step, STEP_CONTROLLER_START);

    let step2 = pair.host.step(Some(&step1)).unwrap().unwrap();
    assert_eq!(step2.step, STEP_HOST_REPLY);
    assert!(step2.to_base64().len() <= MAX_PAYLOAD_BASE64);

    let step3 = pair.controller.step(Some(&step2)).unwrap().unwrap();
    assert_eq!(step3.step, STEP_CONTROLLER_CONFIRM);
    assert_eq!(step3.payload.len(), CONFIRM_LEN);

    assert!(pair.host.step(Some(&step3)).unwrap().is_none());

    assert!(pair.controller.is_complete() && pair.host.is_complete());
    let key = pair.controller.session_key().unwrap();
    assert_eq!(key, pair.host.session_key().unwrap());
    assert_eq!(key.len(), SESSION_KEY_LEN);
    assert_ne!(key, [0u8; SESSION_KEY_LEN]);
}

#[test]
fn a_wrong_code_is_rejected_by_the_host() {
    let mut pair = pair("00000000000W", CODE);
    let step1 = pair.controller.step(None).unwrap().unwrap();
    let step2 = pair.host.step(Some(&step1)).unwrap().unwrap();

    assert_eq!(
        pair.controller.step(Some(&step2)).unwrap_err(),
        PakeError::ConfirmationFailed
    );

    let forged = PakeMessage { step: STEP_CONTROLLER_CONFIRM, payload: vec![0u8; CONFIRM_LEN] };
    assert_eq!(pair.host.step(Some(&forged)).unwrap_err(), PakeError::ConfirmationFailed);
    assert!(!pair.host.is_complete());
    assert_eq!(pair.host.session_key().unwrap_err(), PakeError::NotComplete);
}

#[test]
fn a_tampered_host_message_is_rejected() {
    let mut pair = pair(CODE, CODE);
    let step1 = pair.controller.step(None).unwrap().unwrap();
    let mut step2 = pair.host.step(Some(&step1)).unwrap().unwrap();
    let body = step2.payload.len() - CONFIRM_LEN - 1;
    step2.payload[body] ^= 0x40;

    assert!(pair.controller.step(Some(&step2)).is_err());
    assert!(!pair.controller.is_complete());
}

#[test]
fn a_tampered_controller_message_never_reaches_a_shared_key() {
    let mut pair = pair(CODE, CODE);
    let mut step1 = pair.controller.step(None).unwrap().unwrap();
    let body = step1.payload.len() - 1;
    step1.payload[body] ^= 0x11;

    match pair.host.step(Some(&step1)) {
        Err(_) => {}
        Ok(reply) => {
            let step2 = reply.unwrap();
            assert_eq!(
                pair.controller.step(Some(&step2)).unwrap_err(),
                PakeError::ConfirmationFailed
            );
        }
    }
}

#[test]
fn the_exchange_is_bound_to_the_device_and_session() {
    let mut controller = PakeExchange::controller(CODE, DEVICE, SESSION, &pubkey(1)).unwrap();
    let mut host = PakeExchange::host(CODE, DEVICE, "sess-0002", &pubkey(2)).unwrap();

    let step1 = controller.step(None).unwrap().unwrap();
    let step2 = host.step(Some(&step1)).unwrap().unwrap();
    assert_eq!(controller.step(Some(&step2)).unwrap_err(), PakeError::ConfirmationFailed);

    let mut controller = PakeExchange::controller(CODE, DEVICE, SESSION, &pubkey(1)).unwrap();
    let mut host = PakeExchange::host(CODE, "999999999", SESSION, &pubkey(2)).unwrap();
    let step1 = controller.step(None).unwrap().unwrap();
    let step2 = host.step(Some(&step1)).unwrap().unwrap();
    assert_eq!(controller.step(Some(&step2)).unwrap_err(), PakeError::ConfirmationFailed);
}

#[test]
fn steps_must_arrive_in_order() {
    let mut host = PakeExchange::host(CODE, DEVICE, SESSION, &pubkey(2)).unwrap();
    let stray = PakeMessage { step: STEP_CONTROLLER_CONFIRM, payload: vec![0u8; CONFIRM_LEN] };
    assert_eq!(
        host.step(Some(&stray)).unwrap_err(),
        PakeError::UnexpectedStep { got: STEP_CONTROLLER_CONFIRM, expected: STEP_CONTROLLER_START }
    );
    assert_eq!(host.step(None).unwrap_err(), PakeError::Abandoned);
}

#[test]
fn payload_limits_are_enforced() {
    assert_eq!(
        PakeMessage::from_base64(1, &"A".repeat(MAX_PAYLOAD_BASE64 + 1)).unwrap_err(),
        PakeError::PayloadTooLarge
    );
    assert_eq!(PakeMessage::from_base64(1, "not base64!!").unwrap_err(), PakeError::BadBase64);
    let message = PakeMessage { step: 1, payload: vec![1, 2, 3] };
    assert_eq!(
        PakeMessage::from_base64(1, &message.to_base64()).unwrap().payload,
        message.payload
    );
}

#[test]
fn an_empty_code_is_refused() {
    assert!(matches!(
        PakeExchange::controller("---", DEVICE, SESSION, &pubkey(1)).err(),
        Some(PakeError::EmptyCode)
    ));
    assert!(matches!(
        PakeExchange::host(CODE, "", SESSION, &pubkey(2)).err(),
        Some(PakeError::MissingContext)
    ));
    assert!(matches!(
        PakeExchange::host(CODE, DEVICE, SESSION, "").err(),
        Some(PakeError::MissingContext)
    ));
}

#[test]
fn each_side_learns_the_other_device_public_key() {
    let mut pair = pair(CODE, CODE);
    assert!(pair.controller.peer_public_key_base64().is_empty());

    let step1 = pair.controller.step(None).unwrap().unwrap();
    assert_eq!(pair.host.peer_public_key_base64(), String::new());
    let step2 = pair.host.step(Some(&step1)).unwrap().unwrap();
    assert_eq!(pair.host.peer_public_key_base64(), pubkey(1));

    let step3 = pair.controller.step(Some(&step2)).unwrap().unwrap();
    assert_eq!(pair.controller.peer_public_key_base64(), pubkey(2));
    assert!(pair.host.step(Some(&step3)).unwrap().is_none());
}

/// The reason the key is in the transcript rather than merely alongside it: a
/// relay that forwards a genuine exchange untouched but swaps the announced
/// public key would otherwise be trusted to sign the peer's SDP.
#[test]
fn a_swapped_public_key_breaks_the_confirmation() {
    let mut controller = PakeExchange::controller(CODE, DEVICE, SESSION, &pubkey(1)).unwrap();
    let mut host = PakeExchange::host(CODE, DEVICE, SESSION, &pubkey(2)).unwrap();

    let step1 = controller.step(None).unwrap().unwrap();
    let relayed = PakeMessage {
        step: step1.step,
        payload: prefix_public_key(
            &B64.decode(pubkey(9)).unwrap(),
            split_public_key(&step1.payload).unwrap().1,
        ),
    };
    let step2 = host.step(Some(&relayed)).unwrap().unwrap();
    assert_eq!(host.peer_public_key_base64(), pubkey(9));
    assert_eq!(controller.step(Some(&step2)).unwrap_err(), PakeError::ConfirmationFailed);
}

#[test]
fn a_public_key_prefix_that_does_not_fit_is_refused() {
    let mut host = PakeExchange::host(CODE, DEVICE, SESSION, &pubkey(2)).unwrap();
    let nonsense = PakeMessage {
        step: STEP_CONTROLLER_START,
        payload: vec![0xff, 0xff, 0xff, 0xff, 0x01, 0x02],
    };
    assert_eq!(host.step(Some(&nonsense)).unwrap_err(), PakeError::BadPayload);
}

const MINUTE: i64 = 60_000;

#[test]
fn four_failures_still_allow_another_attempt() {
    let policy = GuessPolicy::default();
    let mut counter = GuessCounter::default();
    let mut now = 0;
    for _ in 0..4 {
        counter = policy.record_failure(&counter, now);
        now += 1000;
        assert_eq!(policy.check(&counter, now), GuessDecision::Allowed);
    }
    assert_eq!(counter.failures, 4);
}

#[test]
fn the_fifth_failure_locks_for_a_minute_and_then_doubles() {
    let policy = GuessPolicy::default();
    let mut counter = GuessCounter::default();
    for _ in 0..5 {
        counter = policy.record_failure(&counter, 0);
    }
    assert_eq!(policy.check(&counter, 0), GuessDecision::Locked { retry_after_ms: MINUTE });
    assert_eq!(policy.check(&counter, MINUTE - 1), GuessDecision::Locked { retry_after_ms: 1 });
    assert_eq!(policy.check(&counter, MINUTE), GuessDecision::Allowed);

    let mut at = MINUTE;
    for minutes in [2, 4, 8, 16, 32, 60, 60] {
        counter = policy.record_failure(&counter, at);
        assert_eq!(
            policy.check(&counter, at),
            GuessDecision::Locked { retry_after_ms: minutes * MINUTE },
            "failure {} at {at}",
            counter.failures
        );
        at += minutes * MINUTE;
    }
}

#[test]
fn failures_expire_after_the_window() {
    let policy = GuessPolicy::default();
    let mut counter = GuessCounter::default();
    for index in 0..3 {
        counter = policy.record_failure(&counter, index * MINUTE);
    }
    assert_eq!(counter.failures, 3);

    let on_the_boundary = 2 * MINUTE + policy.window_ms;
    counter = policy.record_failure(&counter, on_the_boundary);
    assert_eq!(counter.failures, 4, "exactly a window later still counts");
    assert_eq!(policy.check(&counter, on_the_boundary), GuessDecision::Allowed);

    let later = on_the_boundary + policy.window_ms + 1;
    counter = policy.record_failure(&counter, later);
    assert_eq!(counter.failures, 1, "the window has passed, the count restarts");
    assert_eq!(policy.check(&counter, later), GuessDecision::Allowed);
}

#[test]
fn a_lockout_does_not_hand_back_a_fresh_window() {
    let policy = GuessPolicy::default();
    let mut counter = GuessCounter::default();
    for _ in 0..5 {
        counter = policy.record_failure(&counter, 0);
    }
    let after_the_lock = MINUTE + policy.window_ms;
    counter = policy.record_failure(&counter, after_the_lock);
    assert_eq!(counter.failures, 6, "waiting out a lockout is not a clean slate");

    let much_later = after_the_lock + 2 * MINUTE + policy.window_ms + 1;
    counter = policy.record_failure(&counter, much_later);
    assert_eq!(counter.failures, 1, "a quiet window after the lockout does clear it");

    assert_eq!(policy.record_success(&counter), GuessCounter::default());
}

#[derive(serde::Serialize, serde::Deserialize, PartialEq, Debug)]
struct VectorFile {
    version: i32,
    note: String,
    cases: Vec<VectorCase>,
}

#[derive(serde::Serialize, serde::Deserialize, PartialEq, Debug)]
struct VectorCase {
    name: String,
    #[serde(rename = "accessCode")]
    access_code: String,
    #[serde(rename = "deviceId")]
    device_id: String,
    #[serde(rename = "sessionId")]
    session_id: String,
    #[serde(rename = "controllerSeed")]
    controller_seed: u8,
    #[serde(rename = "hostSeed")]
    host_seed: u8,
    #[serde(rename = "controllerPubkey")]
    controller_pubkey: String,
    #[serde(rename = "hostPubkey")]
    host_pubkey: String,
    step1: String,
    step2: String,
    step3: String,
    #[serde(rename = "sessionKey")]
    session_key: String,
}

fn vector_case(name: &str, code: &str, device: &str, session: &str, seeds: (u8, u8)) -> VectorCase {
    let (controller_pubkey, host_pubkey) = (pubkey(seeds.0), pubkey(seeds.1));
    let mut controller = PakeExchange::controller(code, device, session, &controller_pubkey)
        .unwrap()
        .with_seed(seeds.0);
    let mut host = PakeExchange::host(code, device, session, &host_pubkey)
        .unwrap()
        .with_seed(seeds.1);
    let step1 = controller.step(None).unwrap().unwrap();
    let step2 = host.step(Some(&step1)).unwrap().unwrap();
    let step3 = controller.step(Some(&step2)).unwrap().unwrap();
    assert!(host.step(Some(&step3)).unwrap().is_none());
    VectorCase {
        name: name.to_string(),
        access_code: code.to_string(),
        device_id: device.to_string(),
        session_id: session.to_string(),
        controller_seed: seeds.0,
        host_seed: seeds.1,
        controller_pubkey,
        host_pubkey,
        step1: step1.to_base64(),
        step2: step2.to_base64(),
        step3: step3.to_base64(),
        session_key: B64.encode(controller.session_key().unwrap()),
    }
}

/// The key schedule, pinned. Regenerate with `PAKE_VECTORS=write cargo test -p
/// rc-identity` when the schedule changes on purpose — and then say so in
/// PROTOCOL.md §2.17.
#[test]
fn matches_the_shared_vectors() {
    let produced = VectorFile {
        version: 1,
        note: "SPAKE2 access-code exchange, PROTOCOL.md 2.17. Ephemeral scalars come from a \
               test-only SHA-256 counter stream seeded with controllerSeed / hostSeed; \
               production uses the OS CSPRNG. step1 and step2 carry the sender's device \
               pubkey as a len32-prefixed DER SPKI blob, and both pubkeys are in the \
               transcript."
            .to_string(),
        cases: vec![
            vector_case("typical", "K7FM3Q8PW2XY", "482719351", "sess-0001", (1, 2)),
            vector_case("other-session", "K7FM3Q8PW2XY", "482719351", "sess-0002", (3, 4)),
            vector_case("all-zero-code", "000000000000", "100000009", "s", (5, 6)),
        ],
    };
    let path = concat!(env!("CARGO_MANIFEST_DIR"), "/../../../protocol/vectors/pake-vectors.json");
    if std::env::var("PAKE_VECTORS").as_deref() == Ok("write") {
        std::fs::write(path, format!("{}\n", serde_json::to_string_pretty(&produced).unwrap()))
            .unwrap();
    }
    let committed: VectorFile =
        serde_json::from_str(&std::fs::read_to_string(path).unwrap()).unwrap();
    assert_eq!(committed, produced);
}
