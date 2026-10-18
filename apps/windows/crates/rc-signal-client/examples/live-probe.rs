//! Zero-footprint probe of a deployment: the TLS handshake and the
//! connect-time challenge, nothing else. Registers nothing, changes nothing.
//! Proves this host's TLS stack against the domain the Mac pair actually uses
//! — ordinary public-CA validation, no pin.
//!
//!   cargo run --example live-probe -p rc-signal-client [WSS URL]

use rc_signal_client::{Config, SignalConnection};

#[tokio::main(flavor = "current_thread")]
async fn main() {
    let url = std::env::args()
        .nth(1)
        .unwrap_or_else(|| "wss://api.skipperdesk.app/ws".into());

    match SignalConnection::connect(&Config::new(&url)).await {
        Ok((conn, _rx)) => {
            let nonce = conn.take_challenge_nonce().await;
            println!(
                "PASS  TLS handshake OK against {url}; challenge nonce: {} bytes",
                nonce.map(|n| n.len()).unwrap_or(0)
            );
        }
        Err(e) => {
            eprintln!("FAIL  {e}");
            std::process::exit(1);
        }
    }
}
