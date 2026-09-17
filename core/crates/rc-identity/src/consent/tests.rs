use super::*;

const MINUTE: i64 = 60 * 1000;
const T0: i64 = 1_700_000_000_000;

#[test]
fn a_controller_nobody_declined_is_prompted() {
    assert_eq!(ConsentLedger::default().admit(T0), ConsentDecision::Prompt);
}

#[test]
fn one_decline_still_prompts() {
    let ledger = ConsentLedger::default().declined(T0);
    assert!(ledger.admit(T0 + 1).should_prompt());
}

#[test]
fn a_second_decline_inside_ten_minutes_auto_declines_for_the_rest_of_the_window() {
    let ledger = ConsentLedger::default()
        .declined(T0)
        .declined(T0 + 9 * MINUTE);
    assert_eq!(
        ledger.admit(T0 + 9 * MINUTE),
        ConsentDecision::AutoDecline {
            retry_after_ms: MINUTE
        }
    );
    assert_eq!(
        ledger.admit(T0 + 10 * MINUTE - 1),
        ConsentDecision::AutoDecline { retry_after_ms: 1 }
    );
    assert_eq!(ledger.admit(T0 + 10 * MINUTE), ConsentDecision::Prompt);
}

#[test]
fn two_declines_ten_minutes_apart_never_auto_decline() {
    let ledger = ConsentLedger::default()
        .declined(T0)
        .declined(T0 + 10 * MINUTE);
    assert!(ledger.admit(T0 + 10 * MINUTE).should_prompt());
    assert_eq!(ledger.decline_times_ms, vec![T0 + 10 * MINUTE]);
}

#[test]
fn a_decline_after_the_window_starts_a_new_window() {
    let ledger = ConsentLedger::default()
        .declined(T0)
        .declined(T0 + MINUTE)
        .declined(T0 + 11 * MINUTE);
    assert!(ledger.admit(T0 + 11 * MINUTE).should_prompt());
    let ledger = ledger.declined(T0 + 12 * MINUTE);
    assert_eq!(ledger.admit(T0 + 12 * MINUTE).retry_after_ms(), 9 * MINUTE);
}

#[test]
fn allowing_forgets_every_decline() {
    let ledger = ConsentLedger::default()
        .declined(T0)
        .declined(T0 + MINUTE)
        .allowed();
    assert!(ledger.admit(T0 + MINUTE).should_prompt());
    assert!(ledger.decline_times_ms.is_empty());
}

#[test]
fn a_decline_stamped_in_the_future_does_not_count() {
    let ledger = ConsentLedger {
        decline_times_ms: vec![T0 + 5 * MINUTE, T0 + 6 * MINUTE],
    };
    assert!(ledger.admit(T0).should_prompt());
}

#[test]
fn the_ledger_keeps_its_wire_field_names() {
    let ledger = ConsentLedger::default().declined(T0);
    let json = serde_json::to_string(&ledger).unwrap();
    assert_eq!(json, format!("{{\"declineTimesMs\":[{T0}]}}"));
    let parsed: ConsentLedger = serde_json::from_str("{}").unwrap();
    assert_eq!(parsed, ConsentLedger::default());
}
