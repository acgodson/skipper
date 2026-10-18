use super::*;

/// Enter on its own must not be an answer. The prompt's whole point is that
/// somebody decided, and a reflexive keypress at a console that was already
/// being typed into is not a decision.
#[test]
fn only_a_deliberate_answer_counts_and_everything_else_is_ignored() {
    assert_eq!(parse("y\n"), Some(ConsentAnswer::Allow));
    assert_eq!(parse("  YES  \r\n"), Some(ConsentAnswer::Allow));
    assert_eq!(parse("Allow"), Some(ConsentAnswer::Allow));
    assert_eq!(parse("n"), Some(ConsentAnswer::Decline));
    assert_eq!(parse("decline\n"), Some(ConsentAnswer::Decline));
    for ignored in ["", "\n", "   ", "yep", "ok", "1", "allow it", "trust"] {
        assert_eq!(parse(ignored), None, "{ignored:?} must not answer a prompt");
    }
}

#[test]
fn the_three_answers_allow_once_allow_and_stop_asking_or_decline() {
    let once = parse("y").unwrap();
    assert!(once.allows() && !once.turns_on_unattended());
    let always = parse(" T \r\n").unwrap();
    assert_eq!(always, ConsentAnswer::AllowAndTurnOnUnattended);
    assert!(always.allows() && always.turns_on_unattended());
    let declined = parse("n").unwrap();
    assert!(!declined.allows() && !declined.turns_on_unattended());
}
