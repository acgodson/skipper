//! The browser leg against a stand-in for rc-api, so the one field the server
//! checks the device for — which nonce it presents when redeeming the code —
//! is pinned. A Windows host once sent the server's own challenge here and was
//! refused every time as "issued for a different link attempt".

use std::sync::{Arc, Mutex};

use rc_host::account::{Account, AccountState, CALLBACK_HOST, CALLBACK_SCHEME};
use rc_host::api::{ApiClient, PLATFORM};
use rc_host::backend::BaseUrl;
use rc_host::SecretStore;
use rc_identity::DeviceKey;
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::{TcpListener, TcpStream};

const CHALLENGE_NONCE: &str = "BwcHBwcHBwcHBwcHBwcHBwcHBwcHBwcHBwcHBwcHBwc=";

type TokenBody = Arc<Mutex<Option<serde_json::Value>>>;

async fn answer(mut socket: TcpStream, seen: TokenBody) {
    let mut raw = Vec::new();
    let mut chunk = [0u8; 4096];
    let head_end = loop {
        let n = socket.read(&mut chunk).await.unwrap();
        if n == 0 {
            return;
        }
        raw.extend_from_slice(&chunk[..n]);
        if let Some(pos) = raw.windows(4).position(|w| w == b"\r\n\r\n") {
            break pos + 4;
        }
    };
    let head = String::from_utf8_lossy(&raw[..head_end]).to_string();
    let path = head.split_whitespace().nth(1).unwrap_or_default().to_string();
    let length = head
        .lines()
        .find_map(|l| l.to_ascii_lowercase().strip_prefix("content-length:").map(|v| v.trim().parse::<usize>().unwrap()))
        .unwrap_or(0);
    while raw.len() < head_end + length {
        let n = socket.read(&mut chunk).await.unwrap();
        if n == 0 {
            break;
        }
        raw.extend_from_slice(&chunk[..n]);
    }
    let body = &raw[head_end..head_end + length];
    let (status, reply) = match path.as_str() {
        "/v1/auth/device/challenge" => ("200 OK", format!(r#"{{"nonce":"{CHALLENGE_NONCE}","expiresAt":0}}"#)),
        "/v1/auth/device/token" => {
            *seen.lock().unwrap() = Some(serde_json::from_slice(body).unwrap());
            (
                "200 OK",
                r#"{"deviceToken":"granted","expiresAt":9999999999999,"deviceId":"466120015","accountId":"acct","accountEmail":"owner@example.com"}"#.to_string(),
            )
        }
        _ => ("404 Not Found", r#"{"error":{"code":"not_found","message":"no such route"}}"#.to_string()),
    };
    let response = format!(
        "HTTP/1.1 {status}\r\ncontent-type: application/json\r\ncontent-length: {}\r\nconnection: close\r\n\r\n{reply}",
        reply.len()
    );
    socket.write_all(response.as_bytes()).await.unwrap();
    let _ = socket.shutdown().await;
}

async fn stand_in_api(listener: TcpListener, seen: TokenBody) {
    loop {
        let (socket, _) = listener.accept().await.unwrap();
        tokio::spawn(answer(socket, seen.clone()));
    }
}

#[tokio::test]
async fn the_token_request_presents_the_link_nonce_not_the_challenge() {
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let port = listener.local_addr().unwrap().port();
    let seen: TokenBody = Arc::new(Mutex::new(None));
    tokio::spawn(stand_in_api(listener, seen.clone()));

    let scratch = std::env::temp_dir().join(format!("rc-sign-in-{}", std::process::id()));
    let secrets = SecretStore::open(scratch.clone()).unwrap();
    let key = DeviceKey::generate();
    let api = ApiClient::new(BaseUrl::parse(&format!("http://127.0.0.1:{port}")).unwrap(), "0.0.0-test").unwrap();
    let mut account = Account::new(api, &secrets, &key, "Test PC".into(), "hw-test".into());

    let web = BaseUrl::parse("https://skipperdesk.app").unwrap();
    let url = account.begin_sign_in(&web, 1_000).await.unwrap();
    let link_nonce = url.split("nonce=").nth(1).unwrap().split('&').next().unwrap().to_string();
    assert_eq!(link_nonce.len(), 43, "{url}");

    let callback = format!("{CALLBACK_SCHEME}://{CALLBACK_HOST}?code=one-time-code&nonce={link_nonce}");
    let record = account.complete_sign_in(&callback, 2_000).await.unwrap();
    assert_eq!(record.account_email, "owner@example.com");
    assert!(matches!(account.state(), AccountState::Linked { .. }));

    let body = seen.lock().unwrap().clone().expect("the token endpoint was called");
    assert_eq!(body["nonce"], link_nonce, "the nonce the app put in the /link URL");
    assert_ne!(body["nonce"], CHALLENGE_NONCE, "never the server's challenge nonce");
    assert_eq!(body["code"], "one-time-code");
    assert_eq!(body["pubkey"], key.public_key_spki_base64());
    assert_eq!(body["platform"], PLATFORM);
    assert!(body["sig"].as_str().map(|s| !s.is_empty()).unwrap_or(false), "the challenge is signed");

    let _ = std::fs::remove_dir_all(scratch);
}
