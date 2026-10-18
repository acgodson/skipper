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

use rc_host::account::{Account, AccountState};
use rc_host::api::ApiClient;
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

/// How long `--sign-in` waits for the browser. The attempt itself expires at
/// `ATTEMPT_LIFETIME_MS`; this is just how long the console stays blocked.
const SIGN_IN_WAIT: std::time::Duration = std::time::Duration::from_secs(300);

enum Command {
    Run { synthetic: bool },
    SignIn,
    SignOut,
    /// The shell handing this process a `skipperdesk://link` URL.
    LinkCallback(String),
}

fn command() -> Command {
    let args: Vec<String> = std::env::args().skip(1).collect();
    if let Some(index) = args.iter().position(|a| a == "--link-callback") {
        return match args.get(index + 1) {
            Some(url) => Command::LinkCallback(url.clone()),
            None => Command::Run { synthetic: false },
        };
    }
    // The shell may also pass the URL on its own, depending on how the handler
    // was registered by an earlier build.
    if let Some(url) = args
        .iter()
        .find(|a| a.starts_with(&format!("{}://", rc_host::account::CALLBACK_SCHEME)))
    {
        return Command::LinkCallback(url.clone());
    }
    if args.iter().any(|a| a == "--sign-in") {
        return Command::SignIn;
    }
    if args.iter().any(|a| a == "--sign-out") {
        return Command::SignOut;
    }
    Command::Run {
        synthetic: args.iter().any(|a| a == "--synthetic"),
    }
}

#[tokio::main]
async fn main() {
    let command = command();
    let startup = match startup() {
        Ok(startup) => startup,
        Err(e) => {
            eprintln!("rc-host: {e}");
            std::process::exit(1);
        }
    };

    let outcome = match command {
        Command::LinkCallback(url) => rc_host::urlhandler::deliver(&startup.secrets, &url),
        Command::SignIn => sign_in(&startup).await,
        Command::SignOut => sign_out(&startup).await,
        Command::Run { synthetic } => {
            print_banner(&startup.identity);
            run(startup, synthetic).await
        }
    };
    if let Err(e) = outcome {
        eprintln!("rc-host: {e}");
        std::process::exit(1);
    }
}

fn account<'a>(startup: &'a Startup) -> Result<Account<'a>, String> {
    let api = ApiClient::new(startup.backend.api.clone(), env!("CARGO_PKG_VERSION"))
        .map_err(|e| e.to_string())?;
    Ok(Account::new(
        api,
        &startup.secrets,
        &startup.key,
        env_or("RC_DEVICE_LABEL", "Windows Host"),
        hardware_id(),
    ))
}

/// Sent once, to `/v1/auth/device/token`, and never again: the server keeps
/// only an HMAC of it. `MachineGuid` is per-installation, which is what the
/// field is for; its absence is not fatal.
fn hardware_id() -> String {
    #[cfg(windows)]
    {
        let read = std::process::Command::new("reg")
            .args([
                "query",
                r"HKLM\SOFTWARE\Microsoft\Cryptography",
                "/v",
                "MachineGuid",
            ])
            .output();
        if let Ok(output) = read {
            let text = String::from_utf8_lossy(&output.stdout);
            if let Some(guid) = text.split_whitespace().last() {
                if guid.len() >= 32 {
                    return guid.to_string();
                }
            }
        }
    }
    // A stable fallback that is still this machine rather than this run.
    format!(
        "{}-{}",
        std::env::var("COMPUTERNAME")
            .or_else(|_| std::env::var("HOSTNAME"))
            .unwrap_or_else(|_| "unknown".into()),
        std::env::consts::OS
    )
}

/// The browser leg. Registration comes first: `/v1/auth/device/token` refuses a
/// key the device registry does not know, with the sign-in code left unspent.
async fn sign_in(startup: &Startup) -> Result<(), String> {
    if let Ok(executable) = std::env::current_exe() {
        if let Err(e) = rc_host::urlhandler::register(&executable) {
            eprintln!("rc-host: the sign-in return handler could not be registered ({e})");
        }
    }
    if startup.identity.device_id.is_empty() || !startup.identity.server_registered {
        return Err(
            "this PC has no Device ID yet. Start the host once so it can register, then sign in."
                .into(),
        );
    }
    // A URL left over from an abandoned attempt must not be read as this one's.
    let _ = rc_host::urlhandler::take(&startup.secrets);

    let mut account = account(startup)?;
    let url = account
        .begin_sign_in(&startup.backend.web, now_ms())
        .await?;
    println!("\n  Opening your browser to sign in.");
    println!("  If it does not open, paste this address into it:\n\n  {url}\n");
    if let Err(e) = rc_host::urlhandler::open_in_browser(&url) {
        eprintln!("rc-host: {e}");
    }

    let deadline = std::time::Instant::now() + SIGN_IN_WAIT;
    let callback = loop {
        if let Some(url) = rc_host::urlhandler::take(&startup.secrets) {
            break url;
        }
        if std::time::Instant::now() >= deadline {
            return Err("no answer came back from the browser; choose Sign in again".into());
        }
        tokio::time::sleep(std::time::Duration::from_millis(250)).await;
    };

    let record = account.complete_sign_in(&callback, now_ms()).await?;
    let who = match record.account_email.is_empty() {
        true => "your account".to_string(),
        false => record.account_email.clone(),
    };
    println!("  Signed in as {who}.");
    if let Some(entitlement) = account.entitlement(now_ms(), true).await {
        println!("  Plan status: {}", entitlement.status);
    }
    Ok(())
}

async fn sign_out(startup: &Startup) -> Result<(), String> {
    let mut account = account(startup)?;
    match account.state() {
        AccountState::Linked { .. } => {}
        _ => {
            println!("  This PC is not signed in.");
            return Ok(());
        }
    }
    account.sign_out().await?;
    println!("  Signed out. This PC can no longer be connected to until it signs in again.");
    Ok(())
}

fn now_ms() -> i64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_millis() as i64)
        .unwrap_or(0)
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
