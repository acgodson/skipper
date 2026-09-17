use base64::engine::general_purpose::STANDARD as B64;
use base64::Engine;
use rc_identity::{access_code, build_verifier, DeviceKey, SigningPurpose};
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
        "sig": key.sign(SigningPurpose::Hello, &nonce).unwrap(),
        "registerSig": key.sign(SigningPurpose::Register, &nonce).unwrap(),
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
fn an_sdp_signature_uses_the_encodings_the_go_server_accepts() {
    const SDP: &str = "v=0\r\nm=application 9 UDP/DTLS/SCTP webrtc-datachannel\r\n\
a=fingerprint:sha-256 7B:8C:1D:4F:2A:90:33:AE:BB:01:5C:6D:77:E8:99:0A\r\n";
    const SESSION: &str = "8c7f1a2b3c4d5e6f708192a3b4c5d6e7";
    let mac_key = rc_identity::sdp::mac_key(&[3u8; 32]);

    let key = DeviceKey::generate();
    let pubkey = key.public_key_spki_base64();
    let signable = rc_identity::sdp::signable(&mac_key, SESSION, "offer", SDP).unwrap();
    let payload = rc_identity::sdp::payload(SESSION, "offer", &signable.fingerprints).unwrap();
    let signature = key.sign(SigningPurpose::Sdp, &payload).unwrap();

    rc_identity::sdp::verify(
        &mac_key,
        SESSION,
        "offer",
        SDP,
        &rc_identity::sdp::Presented {
            fingerprints: &signable.fingerprints,
            pubkey: &pubkey,
            sig: &signature,
            mac: &signable.mac,
        },
        &pubkey,
    )
    .unwrap();

    let nonce: Vec<u8> = (0u8..32).collect();
    let handshake_signature = key.sign(SigningPurpose::Hello, &nonce).unwrap();
    assert_eq!(B64.decode(&pubkey).unwrap().len(), 91, "P-256 DER SPKI");
    for sig in [&signature, &handshake_signature] {
        let der = B64.decode(sig).unwrap();
        assert_eq!(der.first(), Some(&0x30), "ASN.1 DER SEQUENCE");
        assert_eq!(der.len(), der[1] as usize + 2, "DER length covers the body");
    }
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
    assert_eq!(
        loaded.device_key().unwrap().public_key_spki_base64(),
        key.public_key_spki_base64()
    );
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        let mode = std::fs::metadata(&path).unwrap().permissions().mode() & 0o777;
        assert_eq!(
            mode, 0o600,
            "identity file must be owner-only, got {mode:o}"
        );
    }
    std::fs::remove_dir_all(&dir).ok();
}
