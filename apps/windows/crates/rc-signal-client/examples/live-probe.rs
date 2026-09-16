//! Zero-footprint probe of the production server: pinned TLS handshake plus
//! the connect-time challenge, nothing else. Registers nothing, changes
//! nothing. Proves the Windows host's TLS stack + pin against the box the Mac
//! pair actually uses.
//!
//!   cargo run --example live-probe -p rc-signal-client [URL PIN]

use rc_signal_client::{Config, SignalConnection};

#[tokio::main(flavor = "current_thread")]
async fn main() {
    let mut args = std::env::args().skip(1);
    let url = args.next().unwrap_or_else(|| "wss://54.246.73.81:8443/ws".into());
    let pin = args
        .next()
        .unwrap_or_else(|| "E30xoxEp9t658+TJEVdaGb8Ooi7HGGMWp1kxVpeSpgk=".into());

    match SignalConnection::connect(&Config::new(&url, Some(&pin))).await {
        Ok((conn, _rx)) => {
            let nonce = conn.take_challenge_nonce().await;
            println!(
                "PASS  pinned TLS handshake OK against {url}; challenge nonce: {} bytes",
                nonce.map(|n| n.len()).unwrap_or(0)
            );
        }
        Err(e) => {
            eprintln!("FAIL  {e}");
            std::process::exit(1);
        }
    }
}
