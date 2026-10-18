//! Driven with a real controller-side [`PakeExchange`] from `rc_identity`, so
//! what is asserted is that the host's orchestration completes a genuine
//! exchange and charges the budget the way §2.17 says — not that a stub agrees
//! with itself.

use super::*;
use rc_identity::pake::{GuessDecision, GuessPolicy, HostGuessBudget};
use rc_identity::DeviceKey;

const HOST_DEVICE_ID: &str = "481930275";
const SESSION: &str = "0123456789abcdef0123456789abcdef";
const CODE: &str = "ABCD1234EFGH";

struct Scratch(std::path::PathBuf);

impl Scratch {
    fn new(tag: &str) -> Self {
        let path = std::env::temp_dir().join(format!(
            "rc-pake-{tag}-{}-{:?}",
            std::process::id(),
            std::thread::current().id()
        ));
        let _ = std::fs::remove_dir_all(&path);
        Self(path)
    }

    fn secrets(&self) -> SecretStore {
        SecretStore::open(self.0.clone()).unwrap()
    }
}

impl Drop for Scratch {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}

struct Peers {
    host: HostExchange,
    controller: PakeExchange,
    controller_pubkey: String,
}

fn arm_peers(
    guesses: &GuessStore<'_>,
    host_code: &str,
    controller_code: &str,
    now_ms: i64,
) -> Result<Peers, ExchangeError> {
    let host_key = DeviceKey::generate();
    let controller_key = DeviceKey::generate();
    let controller_pubkey = controller_key.public_key_spki_base64();
    let host = HostExchange::arm(
        guesses,
        host_code,
        HOST_DEVICE_ID,
        SESSION,
        &host_key.public_key_spki_base64(),
        &controller_pubkey,
        now_ms,
    )?;
    let controller =
        PakeExchange::controller(controller_code, HOST_DEVICE_ID, SESSION, &controller_pubkey)
            .unwrap();
    Ok(Peers {
        host,
        controller,
        controller_pubkey,
    })
}

/// Runs the three steps. `Ok(mac_key)` means the host completed; the error is
/// whichever side refused first, as the host would see it.
fn exchange(
    guesses: &GuessStore<'_>,
    host_code: &str,
    controller_code: &str,
    now_ms: i64,
) -> Result<([u8; MAC_KEY_LEN], [u8; MAC_KEY_LEN]), ExchangeError> {
    let mut peers = arm_peers(guesses, host_code, controller_code, now_ms)?;
    let step1 = peers.controller.step(None).unwrap().unwrap();
    let step2 = peers
        .host
        .step(guesses, &step1, now_ms)?
        .expect("the host answers step 1 with step 2");
    let step3 = peers
        .controller
        .step(Some(&step2))?
        .expect("the controller answers step 2 with step 3");
    assert!(peers.host.step(guesses, &step3, now_ms)?.is_none());
    assert!(peers.host.is_complete());
    Ok((
        peers.host.sdp_mac_key().unwrap(),
        peers.controller.sdp_mac_key().unwrap(),
    ))
}

#[test]
fn the_right_code_completes_and_both_sides_derive_the_same_sdp_mac_key() {
    let scratch = Scratch::new("ok");
    let secrets = scratch.secrets();
    let guesses = GuessStore::new(&secrets);
    let (host_key, controller_key) = exchange(&guesses, CODE, CODE, 1_000).unwrap();
    assert_eq!(
        host_key, controller_key,
        "a MAC the host writes must verify under the key the controller derived"
    );
}

/// A wrong code fails for the host at step 3, and §2.14 calls that
/// `auth_failed` — it is about the code, not the device key.
#[test]
fn a_wrong_code_fails_at_step_three_as_auth_failed() {
    let scratch = Scratch::new("wrong");
    let secrets = scratch.secrets();
    let guesses = GuessStore::new(&secrets);
    let error = exchange(&guesses, CODE, "ZZZZ9999ZZZZ", 1_000).expect_err("wrong code");
    assert_eq!(error.bye_reason(), rc_proto::consts::bye::AUTH_FAILED);
}

/// The defect this guards: a guess counted only on a *verified* failure lets a
/// guesser hang up after step 2, check the confirmation offline and come back
/// free. §2.17 charges when step 2 leaves the host.
#[test]
fn the_guess_is_charged_when_step_two_leaves_the_host_not_when_it_fails() {
    let scratch = Scratch::new("charge");
    let secrets = scratch.secrets();
    let guesses = GuessStore::new(&secrets);
    let mut peers = arm_peers(&guesses, CODE, CODE, 1_000).unwrap();
    let step1 = peers.controller.step(None).unwrap().unwrap();

    assert_eq!(
        guesses.ledger(&peers.controller_pubkey).unwrap().controller.failures,
        0
    );
    peers.host.step(&guesses, &step1, 1_000).unwrap();
    let charged = guesses.ledger(&peers.controller_pubkey).unwrap();
    assert_eq!(
        charged.controller.failures, 1,
        "step 2 carries confirmH, so it costs a guess the moment it is sent"
    );
    assert_eq!(charged.host.failure_times_ms, vec![1_000]);

    // The exchange is abandoned here, exactly as a hang-up would. Nothing
    // withdraws the charge.
    drop(peers.host);
    assert_eq!(
        guesses.ledger(&peers.controller_pubkey).unwrap().controller.failures,
        1
    );
}

#[test]
fn a_verified_step_three_withdraws_the_charge_it_made() {
    let scratch = Scratch::new("withdraw");
    let secrets = scratch.secrets();
    let guesses = GuessStore::new(&secrets);
    let mut peers = arm_peers(&guesses, CODE, CODE, 1_000).unwrap();
    let step1 = peers.controller.step(None).unwrap().unwrap();
    let step2 = peers.host.step(&guesses, &step1, 1_000).unwrap().unwrap();
    let step3 = peers.controller.step(Some(&step2)).unwrap().unwrap();
    peers.host.step(&guesses, &step3, 1_100).unwrap();

    let after = guesses.ledger(&peers.controller_pubkey).unwrap();
    assert_eq!(after.controller.failures, 0);
    assert!(
        after.host.failure_times_ms.is_empty(),
        "the host-wide budget gets its own failure back, and only its own"
    );
}

/// A lockout is refused before SPAKE2 runs, so serving one costs the host
/// nothing — and the refusal is `auth_failed`, not `failed`.
#[test]
fn a_locked_out_controller_is_refused_without_spending_another_guess() {
    let scratch = Scratch::new("lockout");
    let secrets = scratch.secrets();
    let guesses = GuessStore::new(&secrets);
    let controller_pubkey = DeviceKey::generate().public_key_spki_base64();

    let mut ledger = GuessLedger::default();
    for failure in 0..GuessPolicy::default().threshold {
        ledger = GuessLedger {
            controller: GuessPolicy::default()
                .record_failure(&ledger.controller, 1_000 + i64::from(failure)),
            host: ledger.host,
        };
    }
    guesses.save(&ledger, &controller_pubkey, 1_000).unwrap();
    assert!(!ledger.admit(1_010).is_allowed());

    let refused = HostExchange::arm(
        &guesses,
        CODE,
        HOST_DEVICE_ID,
        SESSION,
        &DeviceKey::generate().public_key_spki_base64(),
        &controller_pubkey,
        1_010,
    )
    .err()
    .expect("a locked-out key must not start an exchange");
    assert!(matches!(refused, ExchangeError::LockedOut(_)), "{refused}");
    assert_eq!(refused.bye_reason(), rc_proto::consts::bye::AUTH_FAILED);
    assert_eq!(
        guesses.ledger(&controller_pubkey).unwrap().controller.failures,
        GuessPolicy::default().threshold,
        "refusing step 1 records no failure"
    );
}

/// The host-wide budget is what bounds a server that invents a fresh
/// controller key for every guess.
#[test]
fn the_host_wide_budget_locks_every_controller_out_once_it_is_spent() {
    let scratch = Scratch::new("hostwide");
    let secrets = scratch.secrets();
    let guesses = GuessStore::new(&secrets);
    let budget = HostGuessBudget::default();

    let mut host = GuessCounter::default();
    for failure in 0..budget.max_failures {
        host = budget.record_failure(&host, 1_000 + failure as i64);
    }
    let fresh_key = DeviceKey::generate().public_key_spki_base64();
    guesses
        .save(
            &GuessLedger {
                controller: GuessCounter::default(),
                host,
            },
            &fresh_key,
            1_000,
        )
        .unwrap();

    let error = HostExchange::arm(
        &guesses,
        CODE,
        HOST_DEVICE_ID,
        SESSION,
        &DeviceKey::generate().public_key_spki_base64(),
        &fresh_key,
        1_100,
    )
    .err()
    .expect("a brand-new controller key must still be refused");
    assert!(matches!(error, ExchangeError::LockedOut(_)), "{error}");
}

/// §2.17: step 1's own key prefix must be the key `session_start` named. The
/// check happens before step 2 is handed out, so the guess is not spent on it.
#[test]
fn a_step_one_whose_key_is_not_the_announced_one_is_refused() {
    let scratch = Scratch::new("substituted");
    let secrets = scratch.secrets();
    let guesses = GuessStore::new(&secrets);
    let announced = DeviceKey::generate().public_key_spki_base64();
    let impostor = DeviceKey::generate().public_key_spki_base64();

    let mut host = HostExchange::arm(
        &guesses,
        CODE,
        HOST_DEVICE_ID,
        SESSION,
        &DeviceKey::generate().public_key_spki_base64(),
        &announced,
        1_000,
    )
    .unwrap();
    let mut controller =
        PakeExchange::controller(CODE, HOST_DEVICE_ID, SESSION, &impostor).unwrap();
    let step1 = controller.step(None).unwrap().unwrap();

    let error = host
        .step(&guesses, &step1, 1_000)
        .expect_err("a substituted controller key must not get a confirmation");
    assert!(matches!(error, ExchangeError::KeyNotAnnounced), "{error}");
    assert_eq!(error.bye_reason(), rc_proto::consts::bye::AUTH_FAILED);
}

#[test]
fn an_out_of_order_step_or_the_timeout_ends_the_exchange_as_failed() {
    let scratch = Scratch::new("order");
    let secrets = scratch.secrets();
    let guesses = GuessStore::new(&secrets);

    let mut peers = arm_peers(&guesses, CODE, CODE, 1_000).unwrap();
    let confirm = PakeMessage {
        step: STEP_CONTROLLER_CONFIRM,
        payload: vec![0u8; 32],
    };
    let out_of_order = peers.host.step(&guesses, &confirm, 1_000).expect_err("step 3 first");
    assert_eq!(out_of_order.bye_reason(), rc_proto::consts::bye::FAILED);

    let mut late = arm_peers(&guesses, CODE, CODE, 1_000).unwrap();
    let step1 = late.controller.step(None).unwrap().unwrap();
    assert!(late.host.timed_out(1_000 + EXCHANGE_TIMEOUT_MS));
    let timed_out = late
        .host
        .step(&guesses, &step1, 1_000 + EXCHANGE_TIMEOUT_MS)
        .expect_err("an exchange past 10 s is over");
    assert_eq!(timed_out.bye_reason(), rc_proto::consts::bye::FAILED);
}

/// The counters are per *key*, not per base64 spelling, so one controller
/// cannot collect a fresh budget by re-encoding its own key.
#[test]
fn the_budget_is_keyed_on_the_canonical_device_key() {
    let scratch = Scratch::new("canonical");
    let secrets = scratch.secrets();
    let guesses = GuessStore::new(&secrets);
    let pubkey = DeviceKey::generate().public_key_spki_base64();

    guesses
        .save(
            &GuessLedger::default().reply_sent(1_000),
            &pubkey,
            1_000,
        )
        .unwrap();
    assert_eq!(
        guesses.ledger(&pubkey).unwrap().controller.failures,
        1,
        "the canonical spelling finds the counter it wrote"
    );
    // §0: canonical padded standard base64 is the *only* accepted spelling, so
    // a re-encoded key does not get a counter at all rather than a fresh one.
    assert!(
        matches!(
            guesses.ledger(pubkey.trim_end_matches('=')),
            Err(ExchangeError::NoControllerKey)
        ),
        "an unpadded spelling of the same key is not a device key"
    );
    assert!(
        matches!(
            guesses.ledger("not-a-key"),
            Err(ExchangeError::NoControllerKey)
        ),
        "a value that is not a device key has no budget of its own"
    );
}

#[test]
fn an_unstorable_charge_refuses_the_exchange_rather_than_running_it_uncounted() {
    let scratch = Scratch::new("unstorable");
    let secrets = scratch.secrets();
    let guesses = GuessStore::new(&secrets);
    let mut peers = arm_peers(&guesses, CODE, CODE, 1_000).unwrap();
    let step1 = peers.controller.step(None).unwrap().unwrap();

    // A counter file that is not readable is not writable either: the whole
    // read-modify-write of the charge fails.
    let path = scratch.0.join("guess-counters.bin");
    std::fs::write(&path, b"wreckage").unwrap();
    let error = peers
        .host
        .step(&guesses, &step1, 1_000)
        .expect_err("a charge that cannot be stored must not buy a confirmation");
    assert!(matches!(error, ExchangeError::Storage(_)), "{error}");
    assert_eq!(error.bye_reason(), rc_proto::consts::bye::FAILED);
}

#[test]
fn a_frame_names_the_session_the_exchange_was_armed_for() {
    let scratch = Scratch::new("session");
    let secrets = scratch.secrets();
    let guesses = GuessStore::new(&secrets);
    let peers = arm_peers(&guesses, CODE, CODE, 1_000).unwrap();
    assert_eq!(peers.host.session_id(), SESSION);
    assert_eq!(peers.host.controller_pubkey(), peers.controller_pubkey);
}

#[test]
fn an_empty_controller_key_never_arms_an_exchange() {
    let scratch = Scratch::new("nokey");
    let secrets = scratch.secrets();
    let guesses = GuessStore::new(&secrets);
    let error = HostExchange::arm(
        &guesses,
        CODE,
        HOST_DEVICE_ID,
        SESSION,
        &DeviceKey::generate().public_key_spki_base64(),
        "",
        1_000,
    )
    .err()
    .expect("session_start without a controller key is unusable");
    assert!(matches!(error, ExchangeError::NoControllerKey), "{error}");
}

/// The derived key is bound to the session and the host, so a transcript
/// captured against one cannot be replayed into another.
#[test]
fn the_mac_key_differs_between_two_sessions_with_the_same_code() {
    let scratch = Scratch::new("binding");
    let secrets = scratch.secrets();
    let guesses = GuessStore::new(&secrets);
    let (first, _) = exchange(&guesses, CODE, CODE, 1_000).unwrap();
    let (second, _) = exchange(&guesses, CODE, CODE, 2_000).unwrap();
    assert_ne!(
        first, second,
        "the SPAKE2 output is fresh per exchange, so every session MACs under its own key"
    );
}

#[test]
fn the_access_code_is_normalised_before_it_becomes_the_password() {
    let scratch = Scratch::new("normalise");
    let secrets = scratch.secrets();
    let guesses = GuessStore::new(&secrets);
    exchange(&guesses, CODE, "abcd-1234-efgh", 1_000)
        .expect("the code the user types is the code with separators and case ignored");
}

/// `GuessDecision` is what the host branches on; a spent budget must report a
/// wait, not merely refuse.
#[test]
fn a_lockout_reports_how_long_it_has_left() {
    let ledger = GuessLedger {
        controller: GuessPolicy::default().record_failure(
            &GuessPolicy::default().record_failure(
                &GuessPolicy::default().record_failure(
                    &GuessPolicy::default().record_failure(
                        &GuessPolicy::default().record_failure(&GuessCounter::default(), 0),
                        0,
                    ),
                    0,
                ),
                0,
            ),
            0,
        ),
        host: GuessCounter::default(),
    };
    match ledger.admit(0) {
        GuessDecision::Locked { retry_after_ms } => assert!(retry_after_ms > 0),
        GuessDecision::Allowed => panic!("five failures must lock the key out"),
    }
}
