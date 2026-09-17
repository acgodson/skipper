use super::*;
use crate::pake::GuessCounter;

const MINUTE: i64 = 60 * 1000;
const T0: i64 = 1_700_000_000_000;

fn for_new_key(host: &GuessLedger) -> GuessLedger {
    GuessLedger {
        controller: GuessCounter::default(),
        host: host.host.clone(),
    }
}

#[test]
fn a_controller_nobody_declined_is_prompted() {
    assert_eq!(admit(&GuessLedger::default(), T0), ConsentDecision::Prompt);
}

#[test]
fn a_prompt_counts_as_a_decline_until_it_is_allowed() {
    let open = prompted(&GuessLedger::default(), T0);
    assert_eq!(open.controller.decline_times_ms, vec![T0]);
    assert_eq!(open.host.prompt_times_ms, vec![T0]);
    let allowed = allowed(&open, T0 + MINUTE);
    assert!(allowed.controller.decline_times_ms.is_empty());
    assert!(allowed.host.prompt_times_ms.is_empty());
}

#[test]
fn a_second_unanswered_or_hung_up_prompt_auto_declines_for_the_rest_of_the_window() {
    let ledger = prompted(&prompted(&GuessLedger::default(), T0), T0 + 9 * MINUTE);
    assert_eq!(
        admit(&ledger, T0 + 9 * MINUTE),
        ConsentDecision::AutoDecline {
            retry_after_ms: MINUTE
        }
    );
    assert_eq!(
        admit(&ledger, T0 + 10 * MINUTE - 1),
        ConsentDecision::AutoDecline { retry_after_ms: 1 }
    );
    assert_eq!(admit(&ledger, T0 + 10 * MINUTE), ConsentDecision::Prompt);
}

#[test]
fn two_prompts_ten_minutes_apart_never_auto_decline() {
    let ledger = prompted(&prompted(&GuessLedger::default(), T0), T0 + 10 * MINUTE);
    assert!(admit(&ledger, T0 + 10 * MINUTE).should_prompt());
    assert_eq!(ledger.controller.decline_times_ms, vec![T0 + 10 * MINUTE]);
}

#[test]
fn three_prompts_from_three_keys_exhaust_the_host_for_ten_minutes() {
    let mut host = GuessLedger::default();
    for minute in 0..3 {
        let now = T0 + minute * MINUTE;
        let fresh = for_new_key(&host);
        assert!(admit(&fresh, now).should_prompt(), "prompt {minute}");
        host = prompted(&fresh, now);
    }
    let fourth = for_new_key(&host);
    assert_eq!(
        admit(&fourth, T0 + 3 * MINUTE),
        ConsentDecision::AutoDecline {
            retry_after_ms: 7 * MINUTE
        }
    );
    assert!(!admit(&fourth, T0 + 10 * MINUTE - 1).should_prompt());
    assert!(admit(&fourth, T0 + 10 * MINUTE).should_prompt());
}

#[test]
fn an_allowed_prompt_gives_its_slot_back() {
    let mut host = GuessLedger::default();
    for minute in 0..2 {
        host = prompted(&for_new_key(&host), T0 + minute * MINUTE);
    }
    let owner = allowed(
        &prompted(&for_new_key(&host), T0 + 2 * MINUTE),
        T0 + 2 * MINUTE,
    );
    assert_eq!(owner.host.prompt_times_ms, vec![T0, T0 + MINUTE]);
    assert!(admit(&for_new_key(&owner), T0 + 3 * MINUTE).should_prompt());
}

#[test]
fn the_budget_is_the_stricter_of_the_two_limits() {
    let mut host = GuessLedger::default();
    for minute in 0..3 {
        host = prompted(&for_new_key(&host), T0 + minute * MINUTE);
    }
    let declined_twice = GuessLedger {
        controller: GuessCounter {
            decline_times_ms: vec![T0 + 8 * MINUTE, T0 + 9 * MINUTE],
            ..GuessCounter::default()
        },
        host: host.host,
    };
    assert_eq!(
        admit(&declined_twice, T0 + 9 * MINUTE).retry_after_ms(),
        9 * MINUTE
    );
}

#[test]
fn a_decline_stamped_in_the_future_does_not_count() {
    let ledger = GuessLedger {
        controller: GuessCounter {
            decline_times_ms: vec![T0 + 5 * MINUTE, T0 + 6 * MINUTE],
            ..GuessCounter::default()
        },
        host: GuessCounter {
            prompt_times_ms: vec![T0 + MINUTE; 3],
            ..GuessCounter::default()
        },
    };
    assert!(admit(&ledger, T0).should_prompt());
}

#[test]
fn guess_bookkeeping_keeps_the_consent_history() {
    let open = prompted(&GuessLedger::default(), T0);
    let guessed = open.reply_sent(T0 + 1).confirmed().reply_sent(T0 + 2);
    assert_eq!(guessed.controller.decline_times_ms, vec![T0]);
    assert_eq!(guessed.host.prompt_times_ms, vec![T0]);
    assert!(!admit(&prompted(&guessed, T0 + 3), T0 + 3).should_prompt());
}

#[test]
fn the_counter_keeps_its_wire_field_names_and_old_records_still_parse() {
    let open = prompted(&GuessLedger::default(), T0);
    let json = serde_json::to_value(&open).unwrap();
    assert_eq!(json["controller"]["declineTimesMs"][0], T0);
    assert_eq!(json["host"]["promptTimesMs"][0], T0);
    assert!(json["host"].get("declineTimesMs").is_none());
    let legacy: GuessCounter =
        serde_json::from_str(r#"{"failures":2,"lastFailureMs":5,"lockedUntilMs":0}"#).unwrap();
    assert_eq!(legacy.failures, 2);
    assert!(legacy.decline_times_ms.is_empty() && legacy.prompt_times_ms.is_empty());
}
