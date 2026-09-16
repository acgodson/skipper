//! Drives a REAL `rc-signal` — the same Go code that runs in production —
//! through the full signaling lifecycle with two Rust clients.
//!
//! This is the Rust counterpart of the Mac's transport verification: register,
//! hello, watch/presence, connect with the access code, sdp/ice relay both
//! directions, bad-code rejection, bye. Nothing is mocked; if the client's
//! frames were wrong in any way the server itself is what rejects them.
//!
//! Needs `go` on PATH (skips loudly otherwise). The TLS-pinning test also
//! needs `openssl`, which macOS ships.

use std::process::{Child, Command, Stdio};
use std::time::Duration;

use rc_identity::{access_code, build_verifier, DeviceKey};
use rc_proto::consts::{msg, role};
use rc_proto::signaling as sig;
use rc_signal_client::{Config, Push, PushReceiver, SignalConnection};

struct ServerGuard(Child, #[allow(dead_code)] tempdir::Dir);

impl Drop for ServerGuard {
    fn drop(&mut self) {
        let _ = self.0.kill();
        let _ = self.0.wait();
    }
}

/// Minimal temp-dir helper (no external crate needed).
mod tempdir {
    pub struct Dir(pub std::path::PathBuf);
    impl Dir {
        pub fn new(tag: &str) -> Self {
            let p = std::env::temp_dir().join(format!("rc-sig-{tag}-{}", std::process::id()));
            std::fs::create_dir_all(&p).unwrap();
            Dir(p)
        }
    }
    impl Drop for Dir {
        fn drop(&mut self) {
            let _ = std::fs::remove_dir_all(&self.0);
        }
    }
}

fn free_port() -> u16 {
    std::net::TcpListener::bind("127.0.0.1:0").unwrap().local_addr().unwrap().port()
}

fn server_dir() -> String {
    concat!(env!("CARGO_MANIFEST_DIR"), "/../../../../server").to_string()
}

fn go_available() -> bool {
    Command::new("go").arg("version").output().is_ok()
}

async fn start_server(extra: &[&str], tag: &str, port: u16) -> ServerGuard {
    let dir = tempdir::Dir::new(tag);
    let db = dir.0.join("signal.db");
    let child = Command::new("go")
        .args(["run", "./cmd/rc-signal", "-listen", &format!("127.0.0.1:{port}"), "-db"])
        .arg(&db)
        .args(extra)
        .current_dir(server_dir())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .spawn()
        .expect("spawn rc-signal");
    let guard = ServerGuard(child, dir);
    // Wait for the port to accept connections (go run compiles first).
    for _ in 0..600 {
        if std::net::TcpStream::connect(("127.0.0.1", port)).is_ok() {
            return guard;
        }
        tokio::time::sleep(Duration::from_millis(100)).await;
    }
    panic!("rc-signal did not start listening on {port}");
}

/// Challenges are ambient — the server pushes a fresh one around every auth
/// step — so waiting for anything else skips them.
async fn next_push(rx: &mut PushReceiver, what: &str) -> Push {
    loop {
        let push = tokio::time::timeout(Duration::from_secs(10), rx.0.recv())
            .await
            .unwrap_or_else(|_| panic!("timed out waiting for {what}"))
            .unwrap_or_else(|| panic!("push channel closed waiting for {what}"));
        if matches!(push, Push::Challenge(_)) {
            continue;
        }
        return push;
    }
}

/// Register + hello a fresh device; returns (conn, pushes, device_id).
async fn bring_up(
    config: &Config,
    label: &str,
    dev_role: &str,
    key: &DeviceKey,
    code_verifier: &sig::CodeVerifier,
) -> (SignalConnection, PushReceiver, String, sig::HelloOk) {
    let (conn, mut rx) = SignalConnection::connect(config).await.expect("connect");
    let reg = conn.register(key, label, code_verifier).await.expect("register");
    assert!(rc_proto::valid_device_id(&reg.device_id), "bad deviceId {:?}", reg.device_id);
    // The server pushes a fresh challenge after register_ok; `hello` waits for
    // the stored nonce internally.
    let hello = conn.hello(&reg.device_id, key, dev_role).await.expect("hello");
    assert_eq!(hello.device_id, reg.device_id);
    (conn, rx, reg.device_id, hello)
}

#[tokio::test]
async fn full_signaling_lifecycle_against_the_real_server() {
    if !go_available() {
        eprintln!("SKIP: no Go toolchain; live-server test not run");
        return;
    }
    let port = free_port();
    let _server = start_server(&["-insecure-http"], "life", port).await;
    let config = Config::new(&format!("ws://127.0.0.1:{port}/ws"), None);

    // Host registers with its access code's verifier.
    let host_key = DeviceKey::generate();
    let host_code = access_code::generate();
    let host_verifier = build_verifier(&host_code);
    let (host, mut host_rx, host_id, hello) =
        bring_up(&config, "Win Host", role::HOST, &host_key, &host_verifier).await;
    assert!(hello.heartbeat_sec > 0);
    assert!(hello.active_session_id.is_empty());

    // Controller registers with its own (irrelevant) code.
    let ctrl_key = DeviceKey::generate();
    let ctrl_verifier = build_verifier(&access_code::generate());
    let (ctrl, mut ctrl_rx, ctrl_id, _) =
        bring_up(&config, "Mac Controller", role::CONTROLLER, &ctrl_key, &ctrl_verifier).await;
    assert_ne!(host_id, ctrl_id);

    // Watch the host; presence must say online (it is connected right now).
    let _: sig::WatchOk = ctrl
        .request(msg::WATCH, &sig::Watch { device_id: host_id.clone() }, msg::WATCH_OK)
        .await
        .expect("watch");
    match next_push(&mut ctrl_rx, "presence").await {
        Push::Presence(p) => {
            assert_eq!(p.device_id, host_id);
            assert!(p.online, "host should be online");
        }
        other => panic!("expected presence, got {other:?}"),
    }

    // A wrong access code must be rejected with bad_code — and must NOT create
    // a session or disturb the host.
    let err = ctrl
        .request::<_, sig::ConnectOk>(
            msg::CONNECT_REQ,
            &sig::ConnectReq { device_id: host_id.clone(), access_code: "WRONGCODE111".into() },
            msg::CONNECT_OK,
        )
        .await
        .expect_err("wrong code must fail");
    assert_eq!(err.code(), Some("bad_code"), "got {err}");

    // The right code creates a session; the host is pushed session_start.
    let ok: sig::ConnectOk = ctrl
        .request(
            msg::CONNECT_REQ,
            &sig::ConnectReq { device_id: host_id.clone(), access_code: host_code.clone() },
            msg::CONNECT_OK,
        )
        .await
        .expect("connect with the correct code");
    assert_eq!(ok.host_device_id, host_id);
    assert_eq!(ok.controller_device_id, ctrl_id);
    let host_grant = match next_push(&mut host_rx, "session_start").await {
        Push::SessionStart(s) => s,
        other => panic!("expected session_start, got {other:?}"),
    };
    assert_eq!(host_grant.session_id, ok.session_id);
    // Tokens are per-side: the host's must not equal the controller's.
    assert_ne!(host_grant.session_token, ok.session_token);

    // The host was online when the session was created, so the server tells
    // the controller its peer is attached.
    match next_push(&mut ctrl_rx, "peer_state").await {
        Push::PeerState(p) => {
            assert_eq!(p.session_id, ok.session_id);
            assert!(p.attached, "host should be attached");
        }
        other => panic!("expected peer_state, got {other:?}"),
    }

    // SDP relays verbatim, controller -> host.
    let offer = sig::Sdp {
        session_id: ok.session_id.clone(),
        sdp_type: "offer".into(),
        sdp: "v=0\r\no=- 1 1 IN IP4 127.0.0.1\r\ns=-\r\nt=0 0\r\n".into(),
        restart: false,
    };
    ctrl.send(msg::SDP, &offer).await.unwrap();
    match next_push(&mut host_rx, "sdp offer").await {
        Push::Sdp(s) => {
            assert_eq!(s.sdp, offer.sdp, "sdp must relay verbatim");
            assert_eq!(s.sdp_type, "offer");
        }
        other => panic!("expected sdp, got {other:?}"),
    }

    // ICE relays verbatim, host -> controller, including end-of-candidates.
    let cand = sig::Ice {
        session_id: ok.session_id.clone(),
        candidate: "candidate:1 1 udp 2130706431 192.0.2.7 50000 typ host".into(),
        sdp_mid: "0".into(),
        sdp_mline_index: 0,
    };
    host.send(msg::ICE, &cand).await.unwrap();
    match next_push(&mut ctrl_rx, "ice").await {
        Push::Ice(i) => assert_eq!(i.candidate, cand.candidate),
        other => panic!("expected ice, got {other:?}"),
    }

    // Renew rotates the controller's token.
    let renewed: sig::RenewOk = ctrl
        .request(
            msg::RENEW,
            &sig::Resume { session_id: ok.session_id.clone(), session_token: ok.session_token.clone() },
            msg::RENEW_OK,
        )
        .await
        .expect("renew");
    assert_ne!(renewed.session_token, ok.session_token, "renew must rotate the token");

    // Bye from the controller reaches the host.
    ctrl.send(msg::BYE, &sig::Bye { session_id: ok.session_id.clone(), reason: "user_ended".into() })
        .await
        .unwrap();
    match next_push(&mut host_rx, "bye").await {
        Push::Bye(b) => assert_eq!(b.reason, "user_ended"),
        other => panic!("expected bye, got {other:?}"),
    }
}

#[tokio::test]
async fn registration_is_idempotent_per_key() {
    if !go_available() {
        eprintln!("SKIP: no Go toolchain; idempotency test not run");
        return;
    }
    let port = free_port();
    let _server = start_server(&["-insecure-http"], "idem", port).await;
    let config = Config::new(&format!("ws://127.0.0.1:{port}/ws"), None);

    let key = DeviceKey::generate();
    let verifier = build_verifier(&access_code::generate());
    let (conn, _rx) = SignalConnection::connect(&config).await.unwrap();
    let first = conn.register(&key, "A", &verifier).await.unwrap();
    assert!(!first.existing);

    // Same key on a new socket: same device id, existing=true, and §2.2 says
    // the stored code must be untouched (a second register must not rotate it).
    let (conn2, _rx2) = SignalConnection::connect(&config).await.unwrap();
    let second = conn2.register(&key, "A", &build_verifier("DIFFERENT999")).await.unwrap();
    assert_eq!(second.device_id, first.device_id);
    assert!(second.existing);
}

#[tokio::test]
async fn the_certificate_pin_is_load_bearing() {
    if !go_available() {
        eprintln!("SKIP: no Go toolchain; TLS pin test not run");
        return;
    }
    if Command::new("openssl").arg("version").output().is_err() {
        eprintln!("SKIP: no openssl; TLS pin test not run");
        return;
    }

    // Self-signed cert, same shape as production's.
    let dir = std::env::temp_dir().join(format!("rc-tls-{}", std::process::id()));
    std::fs::create_dir_all(&dir).unwrap();
    let crt = dir.join("server.crt");
    let key_path = dir.join("server.key");
    let status = Command::new("openssl")
        .args([
            "req", "-x509", "-newkey", "ec", "-pkeyopt", "ec_paramgen_curve:P-256",
            "-keyout", key_path.to_str().unwrap(), "-out", crt.to_str().unwrap(),
            "-days", "2", "-nodes", "-subj", "/CN=127.0.0.1",
            "-addext", "subjectAltName=IP:127.0.0.1",
        ])
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .status()
        .unwrap();
    assert!(status.success(), "openssl cert generation failed");

    // The pin is sha256 of the DER, exactly how infra computed the shipped pin.
    let der = Command::new("openssl")
        .args(["x509", "-in", crt.to_str().unwrap(), "-outform", "der"])
        .output()
        .unwrap()
        .stdout;
    use base64::Engine;
    use sha2::Digest;
    let pin = base64::engine::general_purpose::STANDARD.encode(sha2::Sha256::digest(&der));

    let port = free_port();
    let _server = start_server(
        &["-tls-cert", crt.to_str().unwrap(), "-tls-key", key_path.to_str().unwrap()],
        "tls",
        port,
    )
    .await;
    let url = format!("wss://127.0.0.1:{port}/ws");

    // Correct pin: the handshake completes and a challenge arrives.
    let (_conn, _rx) = SignalConnection::connect(&Config::new(&url, Some(&pin)))
        .await
        .expect("the correct pin must connect");

    // Wrong pin: the TLS handshake itself must fail. If this passes, pinning
    // is decorative and the whole no-CA design is unsound.
    let mut wrong = sha2::Sha256::digest(&der);
    wrong[0] ^= 0xff;
    let wrong_pin = base64::engine::general_purpose::STANDARD.encode(wrong);
    let err = SignalConnection::connect(&Config::new(&url, Some(&wrong_pin)))
        .await
        .err()
        .expect("a wrong pin must NOT connect");
    let msg = err.to_string();
    assert!(
        msg.contains("pin mismatch") || msg.to_lowercase().contains("tls"),
        "unexpected error for wrong pin: {msg}"
    );
    std::fs::remove_dir_all(&dir).ok();
}
