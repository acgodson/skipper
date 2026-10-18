use super::*;

const SESSION_PHASES: [SessionPhase; 4] = [
    SessionPhase::Connecting,
    SessionPhase::AwaitingConsent,
    SessionPhase::Live,
    SessionPhase::Reconnecting,
];

fn closed() -> SessionPhase {
    SessionPhase::Closed { reason: "bye".into() }
}

#[test]
fn a_reachable_host_holds_off_idle_sleep_but_lets_the_display_sleep() {
    for phase in [SessionPhase::Idle, closed()] {
        let state = StayAwake::for_host(true, &phase);
        assert_eq!(state, StayAwake::ReachableHost);
        assert!(state.holds_system());
        assert!(!state.holds_display());
    }
}

#[test]
fn a_session_holds_the_system_and_the_display_even_while_signalling_is_down() {
    for online in [true, false] {
        for phase in &SESSION_PHASES {
            let state = StayAwake::for_host(online, phase);
            assert_eq!(state, StayAwake::Session, "{phase:?} online={online}");
            assert!(state.holds_system() && state.holds_display());
        }
    }
}

#[test]
fn an_unreachable_host_with_no_session_holds_nothing() {
    for phase in [SessionPhase::Idle, closed()] {
        let state = StayAwake::for_host(false, &phase);
        assert_eq!(state, StayAwake::Idle);
        assert!(!state.holds_system() && !state.holds_display());
    }
}

#[test]
fn the_holder_thread_follows_updates_and_ends_with_the_guard() {
    let mut keep = KeepAwake::new();
    keep.update(StayAwake::ReachableHost);
    keep.update(StayAwake::Session);
    keep.update(StayAwake::Idle);
    drop(keep);
}
