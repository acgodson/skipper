use super::*;

const PUBKEY: &str = "MFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAEa+b/Zm8wTUVTVEtFWTEyMzQ1Njc4OTBhYmNkZWZnaGlqa2xtbm9wcXJzdA==";

fn begin(now_ms: i64) -> LinkAttempt {
    LinkAttempt::begin(now_ms)
}

#[test]
fn the_nonce_is_thirty_two_bytes_as_unpadded_base64url() {
    let attempt = begin(0);
    assert_eq!(
        attempt.nonce().len(),
        43,
        "the website's own pattern accepts exactly 43 characters"
    );
    assert!(
        attempt
            .nonce()
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || b == b'-' || b == b'_'),
        "base64url, unpadded: {}",
        attempt.nonce()
    );
    assert_ne!(
        attempt.nonce(),
        begin(0).nonce(),
        "every attempt gets its own nonce"
    );
}

/// The device key is standard base64, so `+`, `/` and `=` all have to survive
/// the query string. A pubkey that arrives mangled is refused by the server
/// with `403 forbidden`, which looks like a bug in the app rather than in a URL.
#[test]
fn the_sign_in_url_carries_the_key_and_the_platform_intact() {
    let web = BaseUrl::parse("https://skipperdesk.app").unwrap();
    let url = begin(0).sign_in_url(&web, PUBKEY);

    assert!(url.starts_with("https://skipperdesk.app/link?nonce="), "{url}");
    assert!(url.contains("&platform=windows"), "{url}");
    assert!(
        !url.contains('+') && !url.contains('=') || url.contains("%2B") || url.contains("%3D"),
        "base64 punctuation must be percent-encoded: {url}"
    );

    let device = url
        .split("&device=")
        .nth(1)
        .unwrap()
        .split('&')
        .next()
        .unwrap();
    assert_eq!(
        decode_query(device).unwrap(),
        PUBKEY,
        "the key must arrive byte for byte"
    );
}

#[test]
fn the_matching_nonce_in_a_skipperdesk_link_is_accepted() {
    let attempt = begin(1_000);
    let url = format!(
        "skipperdesk://link?code=ABC123&nonce={}",
        encode_query(attempt.nonce())
    );
    assert_eq!(
        callback_verdict(&url, Some(&attempt), 1_000),
        Verdict::Accepted {
            code: "ABC123".into()
        }
    );
}

/// The nonce is the whole binding. A code that arrives with somebody else's
/// nonce — or with none — must never be redeemed, because redeeming it is what
/// would attach this PC to their account.
#[test]
fn a_code_that_arrives_with_the_wrong_nonce_is_refused() {
    let attempt = begin(1_000);
    let other = LinkAttempt::begin(1_000);
    for query in [
        format!("code=ABC123&nonce={}", encode_query(other.nonce())),
        "code=ABC123".to_string(),
        "code=ABC123&nonce=".to_string(),
        format!("code=ABC123&nonce={}x", encode_query(attempt.nonce())),
    ] {
        assert_eq!(
            callback_verdict(&format!("skipperdesk://link?{query}"), Some(&attempt), 1_000),
            Verdict::NonceMismatch,
            "{query}"
        );
    }
}

#[test]
fn a_link_for_another_scheme_or_another_action_is_not_ours() {
    let attempt = begin(1_000);
    for url in [
        "https://skipperdesk.app/link?code=A",
        "skipperdesk://pay?code=A",
        "skipperdesk-evil://link?code=A",
        "link?code=A",
    ] {
        assert_eq!(
            callback_verdict(url, Some(&attempt), 1_000),
            Verdict::NotOurs,
            "{url}"
        );
    }
}

#[test]
fn a_link_with_no_sign_in_waiting_or_a_stale_one_is_refused() {
    let attempt = begin(1_000);
    let url = format!(
        "skipperdesk://link?code=ABC123&nonce={}",
        encode_query(attempt.nonce())
    );
    assert_eq!(callback_verdict(&url, None, 1_000), Verdict::NoAttempt);
    assert_eq!(
        callback_verdict(&url, Some(&attempt), 1_000 + ATTEMPT_LIFETIME_MS + 1),
        Verdict::Expired
    );
}

#[test]
fn a_link_with_a_matching_nonce_but_no_code_says_so() {
    let attempt = begin(1_000);
    let url = format!("skipperdesk://link?nonce={}", encode_query(attempt.nonce()));
    assert_eq!(
        callback_verdict(&url, Some(&attempt), 1_000),
        Verdict::MissingCode
    );
}

#[test]
fn a_trailing_slash_on_the_authority_is_still_our_link() {
    let attempt = begin(1_000);
    let url = format!(
        "skipperdesk://link/?code=ABC123&nonce={}",
        encode_query(attempt.nonce())
    );
    assert_eq!(
        callback_verdict(&url, Some(&attempt), 1_000),
        Verdict::Accepted {
            code: "ABC123".into()
        }
    );
}

const DAY_MS: i64 = 24 * 60 * 60 * 1000;

#[test]
fn a_token_is_refreshed_inside_the_last_week_of_its_life() {
    let record = TokenRecord {
        device_token: "t".into(),
        device_id: "481930275".into(),
        account_id: "a".into(),
        account_email: "you@example.com".into(),
        expires_at_ms: 90 * DAY_MS,
    };
    assert!(!record.needs_refresh(0));
    assert!(!record.needs_refresh(90 * DAY_MS - REFRESH_WINDOW_MS - 1));
    assert!(record.needs_refresh(90 * DAY_MS - REFRESH_WINDOW_MS + 1));
    assert!(
        record.needs_refresh(91 * DAY_MS),
        "an expired token still asks to be refreshed rather than giving up"
    );
}

/// API.md §4.2: an unknown `status` fails closed, and an unknown `maxQuality`
/// clamps to `auto` rather than to the most permissive mode.
#[test]
fn an_entitlement_from_a_newer_backend_is_read_conservatively() {
    let decode = |json: &str| serde_json::from_str::<crate::api::Entitlement>(json).unwrap();

    let trial = decode(
        r#"{"status":"trial","tier":"base","balanceCents":50,"minutesRemaining":300,
            "trialEndsAt":1756000000000,"concurrency":{"maxActivePairs":1},
            "limits":{"maxQuality":"auto"},"refreshAfterSec":60}"#,
    );
    assert!(trial.may_connect());
    assert_eq!(trial.max_quality(), "auto");
    assert_eq!(trial.balance_cents, Some(50));

    let sparse = decode(r#"{"status":"active"}"#);
    assert!(sparse.may_connect());
    assert_eq!(sparse.concurrency.max_active_pairs, 1);
    assert_eq!(sparse.refresh_after_sec, 60);
    assert_eq!(sparse.balance_cents, None, "absent is not zero");
    assert_eq!(sparse.max_quality(), "auto");

    let unknown = decode(r#"{"status":"pending_review","limits":{"maxQuality":"ultra"}}"#);
    assert!(
        !unknown.may_connect(),
        "a status this build does not know must not open a session"
    );
    assert_eq!(unknown.max_quality(), "auto");

    assert!(!decode(r#"{"status":"unlinked"}"#).may_connect());
    assert!(!decode(r#"{"status":"exhausted"}"#).may_connect());
    assert_eq!(
        decode(r#"{"status":"active","limits":{"maxQuality":"sharp"}}"#).max_quality(),
        "sharp"
    );
    assert!(
        decode(r#"{"status":"active","aFieldFromTheFuture":7}"#).may_connect(),
        "unknown response fields are ignored"
    );
}

#[test]
fn percent_encoding_round_trips_every_byte_a_key_or_a_code_can_hold() {
    for raw in [
        PUBKEY,
        "a+b/c=",
        "plain",
        "spaces and &ampersands=equals?question#hash",
        "",
    ] {
        assert_eq!(decode_query(&encode_query(raw)).unwrap(), raw, "{raw}");
    }
}
