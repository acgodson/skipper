use super::*;

#[test]
fn the_default_domain_derives_the_signaling_url_and_the_sign_in_site() {
    let backend = Backend::resolve(None, None).unwrap();
    assert_eq!(backend.api.signaling_url(), "wss://api.skipperdesk.app/ws");
    assert_eq!(backend.web.origin(), "https://skipperdesk.app");
    assert_eq!(
        backend.api.url("/v1/entitlement"),
        "https://api.skipperdesk.app/v1/entitlement"
    );
}

/// The shipping path must not be reachable by IP or by a pinned certificate.
/// An https URL whose host is a bare address is still refused as a *scheme*
/// decision only — what this asserts is that nothing in the config carries an
/// address or a pin of its own.
#[test]
fn a_plain_http_backend_is_refused_unless_it_is_localhost() {
    assert_eq!(
        BaseUrl::parse("http://54.246.73.81:8443"),
        Err(BackendUrlError::Insecure {
            scheme: "http".into(),
            host: "54.246.73.81".into()
        })
    );
    assert_eq!(
        BaseUrl::parse("ws://api.skipperdesk.app"),
        Err(BackendUrlError::Insecure {
            scheme: "ws".into(),
            host: "api.skipperdesk.app".into()
        })
    );
    let local = BaseUrl::parse("http://127.0.0.1:8443").unwrap();
    assert_eq!(local.signaling_url(), "ws://127.0.0.1:8443/ws");
}

#[test]
fn an_overridden_api_domain_derives_its_own_sign_in_site() {
    let backend = Backend::resolve(Some("https://api.staging.skipperdesk.app"), None).unwrap();
    assert_eq!(
        backend.api.signaling_url(),
        "wss://api.staging.skipperdesk.app/ws"
    );
    assert_eq!(backend.web.origin(), "https://staging.skipperdesk.app");
}

/// A host with no `api.` label to drop, or one whose remainder is not a
/// domain, keeps its own: silently producing `https://app/link` would send the
/// user's browser nowhere.
#[test]
fn a_domain_that_cannot_be_derived_from_keeps_itself_and_can_be_overridden() {
    let derived = Backend::resolve(Some("https://skipper.internal"), None).unwrap();
    assert_eq!(derived.web.origin(), "https://skipper.internal");
    let explicit = Backend::resolve(
        Some("https://skipper.internal"),
        Some("https://sign-in.internal"),
    )
    .unwrap();
    assert_eq!(explicit.api.origin(), "https://skipper.internal");
    assert_eq!(explicit.web.origin(), "https://sign-in.internal");
}

#[test]
fn a_path_or_a_trailing_slash_on_the_base_url_changes_nothing() {
    for raw in [
        "https://api.skipperdesk.app",
        "https://api.skipperdesk.app/",
        "https://API.SkipperDesk.app/ignored/path?q=1",
    ] {
        let parsed = BaseUrl::parse(raw).unwrap();
        assert_eq!(parsed.origin(), "https://api.skipperdesk.app", "{raw}");
        assert_eq!(parsed.signaling_url(), "wss://api.skipperdesk.app/ws");
    }
}

#[test]
fn malformed_configuration_is_refused_rather_than_guessed_at() {
    for raw in ["", "api.skipperdesk.app", "https://", "https://user@host"] {
        assert_eq!(
            BaseUrl::parse(raw),
            Err(BackendUrlError::Malformed(raw.to_string())),
            "{raw}"
        );
    }
}
