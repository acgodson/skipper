use super::*;

#[test]
fn an_idempotency_key_is_within_the_documented_length_and_never_repeats() {
    let first = ApiClient::idempotency_key();
    assert!(
        (16..=64).contains(&first.len()),
        "API.md §1.2 wants 16-64 characters, got {}",
        first.len()
    );
    assert_ne!(first, ApiClient::idempotency_key());
}

/// The server base64-std-decodes the nonce exactly as it sent it, so what is
/// signed is the decoded 32 bytes and what is echoed is the original string.
/// A nonce of any other length is refused here rather than signed.
#[test]
fn a_challenge_nonce_is_thirty_two_bytes_or_it_is_not_signed() {
    use base64::engine::general_purpose::STANDARD as B64;

    let good = Challenge {
        nonce: B64.encode([7u8; 32]),
        expires_at: 0,
    };
    assert_eq!(good.raw_nonce().unwrap(), vec![7u8; 32]);

    for bad in [B64.encode([1u8; 31]), B64.encode([1u8; 33]), "not base64!".into()] {
        let challenge = Challenge {
            nonce: bad.clone(),
            expires_at: 0,
        };
        assert!(challenge.raw_nonce().is_err(), "{bad}");
    }
}

/// `forbidden` with `unlinked` or `revoked` means this device was signed out
/// elsewhere; `revoked` is not in API.md's table but the server sends it.
#[test]
fn being_signed_out_elsewhere_is_told_apart_from_an_ordinary_refusal() {
    let refusal = |code: &str, reason: &str| {
        ApiFailure::Refused(ApiError {
            code: code.into(),
            message: "m".into(),
            reason: reason.into(),
            retry_after_sec: 0,
        })
    };
    assert!(refusal("forbidden", "unlinked").means_signed_out());
    assert!(refusal("forbidden", "revoked").means_signed_out());
    assert!(!refusal("forbidden", "").means_signed_out());
    assert!(!refusal("unauthenticated", "unlinked").means_signed_out());
    assert!(!refusal("rate_limited", "").means_signed_out());
    assert_eq!(
        ApiFailure::Transport("down".into()).code(),
        "network",
        "a client branches on a code, so a transport failure needs one too"
    );
}

/// An error envelope is what every refusal looks like, and the message is for
/// a human — never the thing to branch on.
#[test]
fn an_error_envelope_decodes_to_its_code_and_reason() {
    let error: ApiError = serde_json::from_str(
        r#"{"code":"entitlement","message":"trial has ended","requestId":"r-1",
            "reason":"trial_expired","retryAfterSec":0}"#,
    )
    .unwrap();
    assert_eq!(error.code, "entitlement");
    assert_eq!(error.reason, "trial_expired");

    let sparse: ApiError =
        serde_json::from_str(r#"{"code":"internal","message":"oops","requestId":"r-2"}"#).unwrap();
    assert_eq!(sparse.reason, "");
    assert_eq!(sparse.retry_after_sec, 0);
}

#[test]
fn a_device_token_answer_keeps_the_email_and_the_expiry() {
    let granted: DeviceToken = serde_json::from_str(
        r#"{"deviceToken":"dt","expiresAt":1756000000000,"ttlSec":7776000,
            "deviceId":"481930275","accountId":"acc","accountEmail":"you@example.com"}"#,
    )
    .unwrap();
    assert_eq!(granted.device_id, "481930275");
    assert_eq!(granted.account_email, "you@example.com");
    assert_eq!(granted.expires_at, 1_756_000_000_000);

    let anonymous: DeviceToken = serde_json::from_str(
        r#"{"deviceToken":"dt","expiresAt":1,"deviceId":"481930275","accountId":"acc"}"#,
    )
    .unwrap();
    assert!(
        anonymous.account_email.is_empty(),
        "accountEmail is omitted when the IdP gave none"
    );
}

/// The one request shape the server is strictest about: it refuses unknown
/// fields, and it refuses both `code` and `deviceId` together.
#[test]
fn a_challenge_request_carries_exactly_one_of_code_and_device_id() {
    let for_code = serde_json::to_value(ChallengeRequest {
        code: Some("abc"),
        device_id: None,
    })
    .unwrap();
    assert_eq!(for_code, serde_json::json!({"code": "abc"}));

    let for_device = serde_json::to_value(ChallengeRequest {
        code: None,
        device_id: Some("481930275"),
    })
    .unwrap();
    assert_eq!(for_device, serde_json::json!({"deviceId": "481930275"}));
}

#[test]
fn a_token_request_names_windows_and_omits_an_empty_label() {
    let body = serde_json::to_value(TokenRequest {
        code: "c",
        nonce: "n",
        pubkey: "p",
        sig: "s",
        platform: PLATFORM,
        hardware_id: "h",
        label: "",
    })
    .unwrap();
    assert_eq!(
        body,
        serde_json::json!({
            "code": "c", "nonce": "n", "pubkey": "p", "sig": "s",
            "platform": "windows", "hardwareId": "h"
        }),
        "the device record's platform comes from this body, not from the sign-in URL"
    );
}
