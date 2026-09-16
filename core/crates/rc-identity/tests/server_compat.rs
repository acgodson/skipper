//! Proves the production Go server accepts what this crate produces.
//!
//! Runs `go run ./cmd/rustcompat` from `server/`, which checks the emitted
//! material with the very functions the deployed rc-signal uses:
//! `auth.VerifyDeviceSig` (registration signature) and `auth.VerifyCode`
//! (Argon2id access-code verifier) — including the negative directions.
//!
//! Requires a Go toolchain; the test is skipped (with a loud message) when
//! `go` is not on PATH, so CI environments without Go do not silently pass —
//! they visibly skip.

use base64::engine::general_purpose::STANDARD as B64;
use base64::Engine;
use rc_identity::{access_code, build_verifier, DeviceKey};
use std::process::{Command, Stdio};

#[test]
fn the_go_server_accepts_rust_identity_material() {
    if Command::new("go").arg("version").output().is_err() {
        eprintln!("SKIP: no Go toolchain on PATH; server-compat not verified in this run");
        return;
    }

    let key = DeviceKey::generate();
    let nonce: Vec<u8> = (0u8..32).collect();
    let code = access_code::generate();
    let verifier = build_verifier(&code);

    let payload = serde_json::json!({
        "pubkey": key.public_key_spki_base64(),
        "nonce": B64.encode(&nonce),
        "sig": key.sign_nonce_base64(&nonce),
        "plaintextCode": code,
        "code": verifier,
    });

    let server_dir = concat!(env!("CARGO_MANIFEST_DIR"), "/../../../server");
    let mut child = Command::new("go")
        .args(["run", "./cmd/rustcompat"])
        .current_dir(server_dir)
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .expect("spawn go run");
    use std::io::Write;
    child
        .stdin
        .take()
        .unwrap()
        .write_all(payload.to_string().as_bytes())
        .unwrap();
    let out = child.wait_with_output().unwrap();
    let stdout = String::from_utf8_lossy(&out.stdout);
    let stderr = String::from_utf8_lossy(&out.stderr);
    assert!(
        out.status.success() && stdout.contains("rustcompat OK"),
        "Go rejected the Rust identity material:\n{stdout}\n{stderr}"
    );
}

#[test]
fn access_codes_have_the_documented_shape() {
    for _ in 0..50 {
        let code = access_code::generate();
        assert_eq!(code.len(), 12);
        assert!(
            code.bytes().all(|b| rc_identity::CROCKFORD.contains(&b)),
            "{code} contains a non-Crockford symbol"
        );
    }
    // Two consecutive codes colliding would mean the RNG is broken.
    assert_ne!(access_code::generate(), access_code::generate());
    assert_eq!(access_code::formatted("K7M2QX9PW2XY"), "K7M2-QX9P-W2XY");
}

#[test]
fn the_identity_file_round_trips_and_is_owner_only() {
    let dir = std::env::temp_dir().join(format!("rc-id-test-{}", std::process::id()));
    let path = dir.join("identity.json");
    let key = DeviceKey::generate();
    let rec = rc_identity::IdentityRecord::new_unregistered(
        &key,
        access_code::generate(),
        "2026-09-02T00:00:00Z".into(),
    );
    rec.save(&path).unwrap();

    let loaded = rc_identity::IdentityRecord::load(&path).unwrap();
    assert_eq!(loaded.access_code, rec.access_code);
    // The key must survive the round trip byte-for-byte: a re-derived key that
    // differs would silently change the device's identity server-side.
    assert_eq!(
        loaded.device_key().unwrap().public_key_spki_base64(),
        key.public_key_spki_base64()
    );
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        let mode = std::fs::metadata(&path).unwrap().permissions().mode() & 0o777;
        assert_eq!(mode, 0o600, "identity file must be owner-only, got {mode:o}");
    }
    std::fs::remove_dir_all(&dir).ok();
}
