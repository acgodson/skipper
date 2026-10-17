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

use rc_host::{Backend, Host, HostConfig, RecordingInjector, SecretStore, SyntheticBackend};
use rc_identity::{access_code, DeviceKey, IdentityRecord};

fn env_or(key: &str, default: &str) -> String {
    std::env::var(key).unwrap_or_else(|_| default.to_string())
}

fn identity_directory() -> PathBuf {
    if let Ok(dir) = std::env::var("RC_IDENTITY_DIR") {
        return PathBuf::from(dir);
    }
    dirs_config_dir().join("SkipperDesk")
}

/// Minimal per-OS config dir without pulling the `dirs` crate. `LOCALAPPDATA`
/// is preferred over `APPDATA`: a roaming profile would copy this PC's device
/// key to another machine, and two machines with one key fight over the id.
fn dirs_config_dir() -> PathBuf {
    #[cfg(windows)]
    {
        for key in ["LOCALAPPDATA", "APPDATA"] {
            if let Ok(dir) = std::env::var(key) {
                return PathBuf::from(dir);
            }
        }
    }
    if let Ok(home) = std::env::var("HOME") {
        return PathBuf::from(home).join(".config");
    }
    std::env::temp_dir()
}

/// Everything the host needs that comes off disk, loaded once.
struct Startup {
    identity: IdentityRecord,
    key: DeviceKey,
    identity_path: PathBuf,
    secrets: SecretStore,
    backend: Backend,
}

/// Loads this PC's identity, or creates one on a first run.
///
/// A file that exists but cannot be read is an **error**, never a reason to
/// generate a new key: a new key means a new Device ID and a new access code,
/// and every computer that saved them stops connecting. The user is told to
/// restore it or to reset deliberately.
fn startup() -> Result<Startup, String> {
    let backend = Backend::from_environment().map_err(|e| e.to_string())?;
    let directory = identity_directory();
    let identity_path = directory.join("identity.json");
    let secrets = SecretStore::open(directory.join("secrets")).map_err(|e| e.to_string())?;

    let loaded = match std::fs::metadata(&identity_path) {
        Ok(_) => Some(IdentityRecord::load(&identity_path).map_err(|e| {
            format!(
                "{e}\nIt has NOT been replaced: that would change this PC's Device ID and access \
                 code. Restore it from a backup, or delete it to start over deliberately."
            )
        })?),
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => None,
        Err(e) => return Err(format!("{} could not be read: {e}", identity_path.display())),
    };
    let (identity, key) = match loaded {
        Some(record) => {
            let key = record.device_key().map_err(|e| e.to_string())?;
            (record, key)
        }
        None => {
            let key = DeviceKey::generate();
            let record =
                IdentityRecord::new_unregistered(&key, access_code::generate(), now_iso8601());
            record
                .save(&identity_path)
                .map_err(|e| format!("a new identity could not be saved: {e}"))?;
            (record, key)
        }
    };
    Ok(Startup {
        identity,
        key,
        identity_path,
        secrets,
        backend,
    })
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

fn config(backend: &Backend) -> HostConfig {
    HostConfig {
        signaling_url: backend.api.signaling_url(),
        label: env_or("RC_DEVICE_LABEL", "Windows Host"),
        // §2.17 Consent: off on a new install. The access code says a
        // controller *may* connect; whoever is at this PC says whether it
        // connects now.
        unattended: env_or("RC_UNATTENDED", "0") == "1",
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
    let startup = match startup() {
        Ok(startup) => startup,
        Err(e) => {
            eprintln!("rc-host: {e}");
            std::process::exit(1);
        }
    };
    print_banner(&startup.identity);

    if let Err(e) = run(startup, synthetic).await {
        eprintln!("rc-host: exited with error: {e}");
        std::process::exit(1);
    }
}

/// The diagnostic path: a synthetic screen and an injector that records instead
/// of acting. Available on every OS, and the only configuration in which a
/// synthetic screen is ever used.
async fn run_synthetic(startup: Startup) -> Result<(), String> {
    eprintln!("rc-host: --synthetic mode — test pattern, no input is applied to this machine");
    let (host, events) = Host::with_identity_path(
        config(&startup.backend),
        startup.identity,
        startup.key,
        RecordingInjector::default(),
        SyntheticBackend { width: 1280, height: 720 },
        startup.secrets,
        Some(startup.identity_path),
    );
    host.run(events).await
}

#[cfg(windows)]
async fn run(startup: Startup, synthetic: bool) -> Result<(), String> {
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
        return run_synthetic(startup).await;
    }
    let (host, events) = Host::with_identity_path(
        config(&startup.backend),
        startup.identity,
        startup.key,
        WindowsInjector::new(),
        DxgiBackend::primary_display(),
        startup.secrets,
        Some(startup.identity_path),
    );
    host.run(events).await
}

#[cfg(not(windows))]
async fn run(startup: Startup, _synthetic: bool) -> Result<(), String> {
    // There is no real capture or injection to offer here, so this build is the
    // diagnostic one whether or not --synthetic was passed.
    eprintln!("rc-host: non-Windows build — diagnostic mode only");
    run_synthetic(startup).await
}
