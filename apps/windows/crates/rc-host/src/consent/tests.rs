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
    for ignored in ["", "\n", "   ", "yep", "ok", "1", "allow it"] {
        assert_eq!(parse(ignored), None, "{ignored:?} must not answer a prompt");
    }
}
