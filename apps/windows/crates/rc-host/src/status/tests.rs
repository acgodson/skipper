use super::*;

const PEER: &str = "123456789";

#[test]
fn an_idle_host_is_online_only_while_signalling_is_authenticated() {
    assert_eq!(HostStatus::derive(true, &SessionPhase::Idle, None, Screen::Live), HostStatus::Online);
    assert_eq!(HostStatus::derive(false, &SessionPhase::Idle, None, Screen::Live), HostStatus::Connecting);
    let closed = SessionPhase::Closed { reason: "declined".into() };
    assert_eq!(HostStatus::derive(true, &closed, Some(PEER), Screen::Live), HostStatus::Online);
}

#[test]
fn a_session_names_the_other_computer_and_what_the_screen_is_doing() {
    let with = rc_identity::access_code::formatted_device_id(PEER);
    let live = |screen| HostStatus::derive(true, &SessionPhase::Live, Some(PEER), screen);
    assert_eq!(live(Screen::Live), HostStatus::Session { with: with.clone() });
    assert_eq!(live(Screen::Locked), HostStatus::DesktopLocked { with: with.clone() });
    assert_eq!(live(Screen::Unavailable), HostStatus::CaptureUnavailable);
    assert_eq!(
        HostStatus::derive(true, &SessionPhase::AwaitingConsent, Some(PEER), Screen::Live),
        HostStatus::AwaitingConsent { from: with.clone() }
    );
    assert_eq!(
        HostStatus::derive(false, &SessionPhase::Reconnecting, Some(PEER), Screen::Live),
        HostStatus::Reconnecting { with }
    );
}

#[test]
fn the_pill_uses_the_mac_labels_and_tones() {
    assert_eq!(HostStatus::Online.pill(), ("Online", Tone::Positive));
    assert_eq!(HostStatus::Offline.pill(), ("Offline", Tone::Neutral));
    assert_eq!(HostStatus::Connecting.pill(), ("Connecting…", Tone::Attention));
    assert_eq!(HostStatus::Reconnecting { with: String::new() }.pill(), ("Reconnecting…", Tone::Attention));
    assert_eq!(HostStatus::Session { with: String::new() }.pill(), ("Session active", Tone::Accent));
    assert_eq!(HostStatus::CaptureUnavailable.pill().1, Tone::Critical);
}

#[test]
fn not_being_signed_in_is_the_headline_only_while_idle() {
    let session = HostStatus::Session { with: "123 456 789".into() };
    assert_eq!(headline(&HostStatus::Online, &AccountView::SignedOut), "Not signed in — nobody can connect yet");
    assert_eq!(headline(&HostStatus::Offline, &AccountView::SignedOut), "Not signed in — nobody can connect yet");
    assert_eq!(headline(&session, &AccountView::SignedOut), session.line());
    assert_eq!(
        headline(&HostStatus::Online, &AccountView::SignedIn { email: "a@b.c".into() }),
        "Online — ready for connections"
    );
    assert_eq!(headline(&HostStatus::Connecting, &AccountView::SigningIn { url: "u".into() }), "Continue in your browser…");
    assert_eq!(headline(&HostStatus::Starting, &AccountView::SignedOut), "Connecting…");
}

#[test]
fn only_session_states_count_as_in_session() {
    assert!(!HostStatus::Online.in_session());
    assert!(!HostStatus::Stopping.in_session());
    assert!(!HostStatus::Request { from: String::new() }.in_session());
    assert!(HostStatus::CaptureUnavailable.in_session());
    assert!(HostStatus::Reconnecting { with: String::new() }.in_session());
}
