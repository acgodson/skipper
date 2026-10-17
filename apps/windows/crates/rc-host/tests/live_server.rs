//! Drives a REAL `rc-signal` — the same Go code that runs in production —
//! through the v5 lifecycle with two Rust clients: register, hello, watch,
//! connect, the §2.17 exchange relayed by the server, a §2.12 signed answer,
//! ICE, renew and bye.
//!
//! Nothing is mocked. The server decodes `sdp`, `ice` and `pake` strictly and
//! relays its own re-encoding (v5 change 2), so a frame this host gets wrong in
//! any way is refused by the server rather than by a test's idea of the rules.
//! The controller side is `rc_identity`, which is what the Mac runs through
//! `rc-ffi` — so "the Mac would accept this" is checked by the Mac's code.
//!
//! Needs `go` on PATH; skips loudly otherwise. WebRTC is deliberately absent:
//! this is the signalling and authentication path, and the media path cannot be
//! brought up between two processes on one machine inside a unit test.

use std::process::{Child, Command, Stdio};
use std::time::Duration;

use rc_host::{GuessStore, HostExchange, SecretStore};
use rc_identity::pake::PakeExchange;
use rc_identity::sdp::{self, Presented};
use rc_identity::{access_code, DeviceKey, SigningPurpose};
use rc_proto::consts::{msg, role};
use rc_proto::signaling as sig;
use rc_signal_client::{Config, Push, PushReceiver, SignalConnection};

struct ServerGuard(Child, #[allow(dead_code)] Scratch);

impl Drop for ServerGuard {
    fn drop(&mut self) {
        let _ = self.0.kill();
        let _ = self.0.wait();
    }
}

struct Scratch(std::path::PathBuf);

impl Scratch {
    fn new(tag: &str) -> Self {
        let path = std::env::temp_dir().join(format!("rc-live-{tag}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&path);
        std::fs::create_dir_all(&path).unwrap();
        Self(path)
    }
}

impl Drop for Scratch {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}

fn free_port() -> u16 {
    std::net::TcpListener::bind("127.0.0.1:0")
        .unwrap()
        .local_addr()
        .unwrap()
        .port()
}

fn server_dir() -> String {
    concat!(env!("CARGO_MANIFEST_DIR"), "/../../../../server").to_string()
}

fn go_available() -> bool {
    Command::new("go").arg("version").output().is_ok()
}

/// `-insecure-http` with no `-entitlement` is rc-signal's stand-alone mode:
/// `connect_req` is authorised without an account, which is what lets the
/// signalling and authentication path be tested without rc-api.
async fn start_server(tag: &str, port: u16) -> ServerGuard {
    let scratch = Scratch::new(tag);
    // A TURN secret and URL so §2.18 and §2.11 have credentials to mint; the
    // relay is never contacted, only the issuing path is exercised.
    let turn_secret = scratch.0.join("turn.secret");
    std::fs::write(&turn_secret, b"a-local-turn-secret").unwrap();
    let child = Command::new("go")
        .args(["run", "./cmd/rc-signal", "-insecure-http", "-listen"])
        .arg(format!("127.0.0.1:{port}"))
        .arg("-db")
        .arg(scratch.0.join("signal.db"))
        .arg("-turn-urls")
        .arg("turn:127.0.0.1:3478?transport=udp")
        .arg("-turn-secret-file")
        .arg(&turn_secret)
        .current_dir(server_dir())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .spawn()
        .expect("spawn rc-signal");
    let guard = ServerGuard(child, scratch);
    for _ in 0..900 {
        if std::net::TcpStream::connect(("127.0.0.1", port)).is_ok() {
            return guard;
        }
        tokio::time::sleep(Duration::from_millis(100)).await;
    }
    panic!("rc-signal did not start listening on {port}");
}

/// Some pushes are ambient: the server issues a fresh `challenge` around every
/// auth step and a `peer_state` whenever the other side attaches. Waiting for
/// anything else skips them, exactly as the host's own loop does.
async fn next_push(rx: &mut PushReceiver, what: &str) -> Push {
    loop {
        let push = tokio::time::timeout(Duration::from_secs(10), rx.0.recv())
            .await
            .unwrap_or_else(|_| panic!("timed out waiting for {what}"))
            .unwrap_or_else(|| panic!("push channel closed waiting for {what}"));
        match push {
            Push::Challenge(_) | Push::PeerState(_) => continue,
            other => return other,
        }
    }
}

struct Device {
    conn: SignalConnection,
    pushes: PushReceiver,
    device_id: String,
    key: DeviceKey,
    hello: sig::HelloOk,
}

/// Register and hello a fresh device. The register carries **no** access-code
/// verifier: a v5 server answers `bad_request` to one, so this call succeeding
/// is itself the proof of that half of the fix.
async fn bring_up(config: &Config, label: &str, dev_role: &str) -> Device {
    let key = DeviceKey::generate();
    let (conn, pushes) = SignalConnection::connect(config).await.expect("connect");
    let registered = conn
        .register(&key, label, "", "")
        .await
        .expect("register must be accepted without a code verifier");
    assert!(
        rc_proto::valid_device_id(&registered.device_id),
        "bad deviceId {:?}",
        registered.device_id
    );
    assert!(
        !registered.id_cert.is_empty(),
        "v4: register_ok always carries idCert"
    );
    let hello = conn
        .hello(&registered.device_id, &key, dev_role)
        .await
        .expect("hello");
    assert_eq!(hello.device_id, registered.device_id);
    Device {
        conn,
        pushes,
        device_id: registered.device_id,
        key,
        hello,
    }
}

#[tokio::test]
async fn the_host_completes_a_v5_session_the_mac_controller_would_accept() {
    if !go_available() {
        eprintln!("SKIP: no Go toolchain; live-server test not run");
        return;
    }
    let port = free_port();
    let _server = start_server("life", port).await;
    let config = Config::new(&format!("ws://127.0.0.1:{port}/ws"));

    let mut host = bring_up(&config, "Windows Host", role::HOST).await;
    assert!(host.hello.heartbeat_sec > 0);
    assert!(host.hello.active_session_id.is_empty());
    assert!(
        host.hello
            .ice_servers
            .iter()
            .all(|s| s.username.is_empty() && s.credential.is_empty()),
        "v5: hello_ok carries STUN only"
    );
    let mut controller = bring_up(&config, "Mac Controller", role::CONTROLLER).await;
    assert_ne!(host.device_id, controller.device_id);

    let code = access_code::generate();
    let scratch = Scratch::new("secrets");
    let secrets = SecretStore::open(scratch.0.join("secrets")).unwrap();

    // Presence.
    let _: sig::WatchOk = controller
        .conn
        .request(
            msg::WATCH,
            &sig::Watch { device_id: host.device_id.clone() },
            msg::WATCH_OK,
        )
        .await
        .expect("watch");
    match next_push(&mut controller.pushes, "presence").await {
        Push::Presence(p) => {
            assert_eq!(p.device_id, host.device_id);
            assert!(p.online, "the host is connected right now");
        }
        other => panic!("expected presence, got {other:?}"),
    }

    // §2.9: connect_req carries only the deviceId; the code is not the
    // server's business any more.
    let granted: sig::ConnectOk = controller
        .conn
        .request(
            msg::CONNECT_REQ,
            &sig::ConnectReq {
                device_id: host.device_id.clone(),
                access_code: String::new(),
            },
            msg::CONNECT_OK,
        )
        .await
        .expect("connect_req");
    assert_eq!(granted.host_device_id, host.device_id);
    assert_eq!(
        granted.host_pubkey,
        host.key.public_key_spki_base64(),
        "v2: connect_ok names the host key the controller will pin"
    );
    assert!(
        granted.ice_servers.iter().all(|s| s.credential.is_empty()),
        "v5: connect_ok is STUN only; TURN arrives with ice_servers"
    );

    let start = match next_push(&mut host.pushes, "session_start").await {
        Push::SessionStart(s) => s,
        other => panic!("expected session_start, got {other:?}"),
    };
    assert_eq!(start.session.session_id, granted.session_id);
    assert_ne!(
        start.session.session_token, granted.session_token,
        "each side gets its own token"
    );
    assert_eq!(
        start.controller_pubkey,
        controller.key.public_key_spki_base64(),
        "v2: session_start names the controller key the host pins"
    );
    let session = granted.session_id.clone();

    // ---- §2.17, relayed by the real server ----
    let guesses = GuessStore::new(&secrets);
    let mut host_exchange = HostExchange::arm(
        &guesses,
        &code,
        &host.device_id,
        &session,
        &host.key.public_key_spki_base64(),
        &start.controller_pubkey,
        now_ms(),
    )
    .expect("arm the host exchange");
    let mut controller_exchange = PakeExchange::controller(
        &code,
        &host.device_id,
        &session,
        &controller.key.public_key_spki_base64(),
    )
    .unwrap();

    let step1 = controller_exchange.step(None).unwrap().unwrap();
    controller.conn.send_pake(&session, &step1).await.unwrap();
    let relayed1 = expect_pake(&mut host.pushes, 1).await;
    let step2 = host_exchange
        .step(&guesses, &relayed1, now_ms())
        .expect("the host answers step 1")
        .expect("step 2");
    host.conn.send_pake(&session, &step2).await.unwrap();

    let relayed2 = expect_pake(&mut controller.pushes, 2).await;
    let step3 = controller_exchange
        .step(Some(&relayed2))
        .expect("the controller's confirmation of step 2 must verify")
        .expect("step 3");
    controller.conn.send_pake(&session, &step3).await.unwrap();
    let relayed3 = expect_pake(&mut host.pushes, 3).await;
    host_exchange
        .step(&guesses, &relayed3, now_ms())
        .expect("step 3 verifies");
    assert!(host_exchange.is_complete());

    // §2.17: the key the transcript bound is the one session_start named, and
    // the controller's is the one connect_ok named.
    assert_eq!(
        controller_exchange.peer_public_key_base64(),
        granted.host_pubkey
    );
    assert_eq!(host_exchange.controller_pubkey(), start.controller_pubkey);

    // ---- §2.12: the host's first sdp ----
    let mac_key = host_exchange.sdp_mac_key().unwrap();
    let body = "v=0\r\no=- 1 2 IN IP4 127.0.0.1\r\ns=-\r\nt=0 0\r\n\
m=video 9 UDP/TLS/RTP/SAVPF 96\r\nc=IN IP4 0.0.0.0\r\na=mid:0\r\n\
a=fingerprint:sha-256 7B:8C:1D:2E:3F:40:51:62:73:84:95:A6:B7:C8:D9:EA:FB:0C:1D:2E:3F:40:51:62:73:84:95:A6:B7:C8:D9:EA\r\n\
a=setup:active\r\n";
    let signable = sdp::signable(&mac_key, &session, "answer", body).unwrap();
    let payload = sdp::payload(&session, "answer", &signable.fingerprints).unwrap();
    host.conn
        .send(
            msg::SDP,
            &sig::Sdp {
                session_id: session.clone(),
                sdp_type: "answer".into(),
                sdp: body.into(),
                restart: false,
                fp: signable.fingerprints.clone(),
                pubkey: host.key.public_key_spki_base64(),
                sig: host.key.sign(SigningPurpose::Sdp, &payload).unwrap(),
                mac: signable.mac.clone(),
            },
        )
        .await
        .unwrap();

    // §3.4/§2.18: the host's first relayed sdp starts metering, and
    // ice_servers is pushed to both peers *before* that sdp reaches the
    // controller. So the controller sees ice_servers first.
    let mut answer = None;
    let mut saw_ice_servers = false;
    for _ in 0..4 {
        match next_push(&mut controller.pushes, "ice_servers then sdp").await {
            Push::IceServers(servers) => {
                assert_eq!(servers.session_id, session);
                let turn = servers
                    .ice_servers
                    .iter()
                    .find(|s| !s.credential.is_empty())
                    .expect("v5 §2.18: the session's list carries TURN");
                assert!(
                    turn.username.ends_with(&format!(":{session}")),
                    "the credential names the one session it was issued for: {:?}",
                    turn.username
                );
                saw_ice_servers = true;
            }
            Push::Sdp(relayed) => {
                answer = Some(relayed);
                break;
            }
            other => panic!("unexpected push {other:?}"),
        }
    }
    let answer = answer.expect("the server must relay the host's answer");
    assert!(
        saw_ice_servers,
        "v5 §2.18: metering pushes this session's ICE servers before the sdp"
    );

    // The server relays fp, pubkey, sig and mac unchanged and never checks
    // them; the controller does. This is the Mac's own verifier.
    let controller_mac_key = controller_exchange.sdp_mac_key().unwrap();
    sdp::verify(
        &controller_mac_key,
        &answer.session_id,
        &answer.sdp_type,
        &answer.sdp,
        &Presented {
            fingerprints: &answer.fp,
            pubkey: &answer.pubkey,
            sig: &answer.sig,
            mac: &answer.mac,
        },
        &granted.host_pubkey,
    )
    .expect("the answer that came back through the real server must verify");

    // ---- ICE, renew, bye ----
    let candidate = sig::Ice {
        session_id: session.clone(),
        candidate: "candidate:1 1 udp 2130706431 192.0.2.7 50000 typ host".into(),
        sdp_mid: "0".into(),
        sdp_mline_index: 0,
    };
    host.conn.send(msg::ICE, &candidate).await.unwrap();
    match next_push(&mut controller.pushes, "ice").await {
        Push::Ice(relayed) => assert_eq!(relayed.candidate, candidate.candidate),
        other => panic!("expected ice, got {other:?}"),
    }

    let renewed: sig::RenewOk = host
        .conn
        .request(
            msg::RENEW,
            &sig::Resume {
                session_id: session.clone(),
                session_token: start.session.session_token.clone(),
            },
            msg::RENEW_OK,
        )
        .await
        .expect("renew");
    assert_ne!(renewed.session_token, start.session.session_token);
    assert!(
        renewed.ice_servers.iter().any(|s| !s.credential.is_empty()),
        "v5 §2.11: a metered session's renew_ok carries fresh TURN"
    );

    host.conn
        .send(
            msg::BYE,
            &sig::Bye {
                session_id: session.clone(),
                reason: rc_proto::consts::bye::HOST_ENDED.into(),
                relay_used: Some(false),
                bytes_relayed: None,
            },
        )
        .await
        .unwrap();
    match next_push(&mut controller.pushes, "bye").await {
        Push::Bye(ended) => assert_eq!(ended.reason, rc_proto::consts::bye::HOST_ENDED),
        other => panic!("expected bye, got {other:?}"),
    }
}

/// §2.2: the certificate from `register_ok` is what makes this PC keep its
/// Device ID when the registry no longer knows the key — and `preferredDeviceId`
/// without one is ignored, so the certificate is the load-bearing half.
#[tokio::test]
async fn the_stored_certificate_is_what_reclaims_this_pcs_device_id() {
    if !go_available() {
        eprintln!("SKIP: no Go toolchain; certificate test not run");
        return;
    }
    let port = free_port();
    let _server = start_server("idcert", port).await;
    let config = Config::new(&format!("ws://127.0.0.1:{port}/ws"));

    let key = DeviceKey::generate();
    let (first, _rx) = SignalConnection::connect(&config).await.unwrap();
    let original = first.register(&key, "Windows Host", "", "").await.unwrap();
    assert!(!original.existing);
    assert!(!original.id_cert.is_empty());

    // Same key again: registration is idempotent per key, id unchanged.
    let (again, _rx) = SignalConnection::connect(&config).await.unwrap();
    let repeat = again.register(&key, "Windows Host", "", "").await.unwrap();
    assert_eq!(repeat.device_id, original.device_id);
    assert!(repeat.existing);

    // A different key asking for that id *without* a certificate for it gets a
    // fresh one — which is why a host that loses its certificate loses its id.
    let stranger = DeviceKey::generate();
    let (third, _rx) = SignalConnection::connect(&config).await.unwrap();
    let refused = third
        .register(&stranger, "Impostor", &original.device_id, "not-a-certificate")
        .await
        .unwrap();
    assert_ne!(
        refused.device_id, original.device_id,
        "an id is never given to a second key"
    );
}

async fn expect_pake(rx: &mut PushReceiver, step: u32) -> rc_identity::pake::PakeMessage {
    match next_push(rx, "pake").await {
        Push::Pake(frame) => {
            assert_eq!(frame.step, step as i32, "the server relays steps in order");
            rc_identity::pake::PakeMessage::from_base64(step, &frame.payload).unwrap()
        }
        other => panic!("expected pake step {step}, got {other:?}"),
    }
}

fn now_ms() -> i64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_millis() as i64)
        .unwrap_or(0)
}
