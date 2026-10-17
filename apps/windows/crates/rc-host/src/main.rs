//! `rc-host` entry point.
//!
//!   rc-host --synthetic         diagnostic mode: a synthetic screen and a
//!                               recording injector, on any OS
//!   rc-host                     the real host (Windows: Desktop Duplication +
//!                               SendInput)
//!
//! The two are never mixed. A synthetic screen with the real injector would put
//! the controller's clicks onto whatever is actually on the host's desktop while
//! showing a test pattern, which is worse than showing nothing: when capture
//! cannot start, the host comes online, says capture is unavailable, and
//! suspends remote input.

use std::path::PathBuf;

use rc_host::{Host, HostConfig, RecordingInjector, SyntheticBackend};
use rc_identity::{access_code, DeviceKey, IdentityRecord};

fn env_or(key: &str, default: &str) -> String {
    std::env::var(key).unwrap_or_else(|_| default.to_string())
}

fn identity_path() -> PathBuf {
    if let Ok(dir) = std::env::var("RC_IDENTITY_DIR") {
        return PathBuf::from(dir).join("identity.json");
    }
    let base = dirs_config_dir();
    base.join("RemoteControl").join("identity.json")
}

/// Minimal per-OS config dir without pulling the `dirs` crate.
fn dirs_config_dir() -> PathBuf {
    #[cfg(windows)]
    {
        if let Ok(app) = std::env::var("APPDATA") {
            return PathBuf::from(app);
        }
    }
    if let Ok(home) = std::env::var("HOME") {
        return PathBuf::from(home).join(".config");
    }
    std::env::temp_dir()
}

fn load_or_create_identity() -> (IdentityRecord, DeviceKey) {
    let path = identity_path();
    if let Ok(rec) = IdentityRecord::load(&path) {
        if let Ok(key) = rec.device_key() {
            return (rec, key);
        }
    }
    let key = DeviceKey::generate();
    let code = access_code::generate();
    let created = format!("{}", now_iso8601());
    let rec = IdentityRecord::new_unregistered(&key, code, created);
    let _ = rec.save(&path);
    (rec, key)
}

fn now_iso8601() -> String {
    // Good enough for a createdAt stamp without a date crate.
    let secs = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0);
    format!("unix:{secs}")
}

/// The at-a-glance panel the user reads to pair from their Mac: the Device ID
/// and the access code, formatted the same way the Mac host window shows them.
fn print_banner(identity: &IdentityRecord) {
    let id = if identity.device_id.is_empty() {
        "registering…".to_string()
    } else {
        access_code::formatted_device_id(&identity.device_id)
    };
    println!("\n  RemoteControl — Windows host");
    println!("  ---------------------------------------------");
    println!("  Device ID     {id}");
    println!("  Access code   {}", access_code::formatted(&identity.access_code));
    println!("  ---------------------------------------------");
    println!("  Enter these on your Mac's controller to connect.");
    println!("  Keep this window open. Closing it ends the host.\n");
}

fn config() -> HostConfig {
    HostConfig {
        server_url: env_or("RC_SERVER_URL", "wss://54.246.73.81:8443/ws"),
        cert_pin: {
            let pin = env_or("RC_CERT_PIN", "E30xoxEp9t658+TJEVdaGb8Ooi7HGGMWp1kxVpeSpgk=");
            if pin == "off" { None } else { Some(pin) }
        },
        label: env_or("RC_DEVICE_LABEL", "Windows Host"),
        unattended: env_or("RC_UNATTENDED", "1") == "1",
        force_relay: std::env::var("RC_ICE_POLICY").map(|v| v == "relay").unwrap_or(false),
        bitrate_bps: env_or("RC_BITRATE", "4000000").parse().unwrap_or(4_000_000),
        fps: env_or("RC_FPS", "30").parse().unwrap_or(30.0),
        max_dimension: std::env::var("RC_MAX_DIMENSION")
            .ok()
            .and_then(|v| v.parse().ok())
            .unwrap_or(rc_host::Pacing::DEFAULT_MAX_DIMENSION),
    }
}

#[tokio::main]
async fn main() {
    let synthetic = std::env::args().any(|a| a == "--synthetic");
    let id_path = identity_path();
    let (identity, key) = load_or_create_identity();
    print_banner(&identity);

    if let Err(e) = run(identity, key, id_path, synthetic).await {
        eprintln!("rc-host: exited with error: {e}");
        std::process::exit(1);
    }
}

/// The diagnostic path: a synthetic screen and an injector that records instead
/// of acting. Available on every OS, and the only configuration in which a
/// synthetic screen is ever used.
async fn run_synthetic(
    identity: IdentityRecord,
    key: DeviceKey,
    id_path: PathBuf,
) -> Result<(), String> {
    eprintln!("rc-host: --synthetic mode — test pattern, no input is applied to this machine");
    let (host, events) = Host::with_identity_path(
        config(),
        identity,
        key,
        RecordingInjector::default(),
        SyntheticBackend { width: 1280, height: 720 },
        Some(id_path),
    );
    host.run(events).await
}

#[cfg(windows)]
async fn run(
    identity: IdentityRecord,
    key: DeviceKey,
    id_path: PathBuf,
    synthetic: bool,
) -> Result<(), String> {
    use rc_host::capture_windows::DxgiBackend;
    use rc_host::inject_windows::WindowsInjector;

    // Per-monitor DPI awareness in code, so a build without the manifest (the
    // no-elevation test build) still captures real pixels and maps clicks
    // correctly on a scaled display. Safe to call once at startup; ignore the
    // result (it fails harmlessly if already set by a manifest).
    unsafe {
        use windows::Win32::UI::HiDpi::*;
        let _ = SetProcessDpiAwarenessContext(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2);
    }

    if synthetic {
        return run_synthetic(identity, key, id_path).await;
    }
    let (host, events) = Host::with_identity_path(
        config(),
        identity,
        key,
        WindowsInjector::new(),
        DxgiBackend::primary_display(),
        Some(id_path),
    );
    host.run(events).await
}

#[cfg(not(windows))]
async fn run(
    identity: IdentityRecord,
    key: DeviceKey,
    id_path: PathBuf,
    _synthetic: bool,
) -> Result<(), String> {
    // There is no real capture or injection to offer here, so this build is the
    // diagnostic one whether or not --synthetic was passed.
    eprintln!("rc-host: non-Windows build — diagnostic mode only");
    run_synthetic(identity, key, id_path).await
}
