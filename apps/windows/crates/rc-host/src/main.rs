//! `rc-host` entry point.
//!
//!   rc-host --synthetic         diagnostic mode: a synthetic screen and a
//!                               recording injector, on any OS
//!   rc-host                     the real host (Windows: Desktop Duplication +
//!                               SendInput)
//!   rc-host --unattended on|off whether a controller that proves the access
//!                               code connects without asking; persisted
//!
//! The two are never mixed. A synthetic screen with the real injector would put
//! the controller's clicks onto whatever is actually on the host's desktop while
//! showing a test pattern, which is worse than showing nothing: when capture
//! cannot start, the host comes online, says capture is unavailable, and
//! suspends remote input.

use std::path::PathBuf;

use rc_host::account::{Account, AccountState};
use rc_host::api::{ApiClient, DEFAULT_REFRESH_AFTER_SEC};
use rc_host::inject::Injector;
use rc_host::media::CaptureBackend;
use rc_host::pump::PumpEvent;
use rc_host::settings::{unattended_argument, unattended_line, unattended_override, HostSettings};
use rc_host::{
    Backend, Host, HostConfig, QualityCeiling, RecordingInjector, SecretStore, SyntheticBackend,
};
use rc_identity::{access_code, DeviceKey, IdentityRecord};
use tokio::sync::mpsc;

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
/// and the access code, formatted the same way the Mac host window shows them,
/// and whether a connection will ask whoever is here, in the Mac's words.
fn print_banner(identity: &IdentityRecord, unattended: bool) {
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
    println!("  {}", unattended_line(unattended));
    println!("  ---------------------------------------------");
    println!("  Enter these on your Mac's controller to connect.");
    if !unattended {
        println!("  Leaving this PC on its own? Run  rc-host.exe --unattended on");
        println!("  so connections do not wait for someone to answer here.");
    }
    println!("  This PC will not fall asleep on its own while this window is open");
    println!("  and online, and its screen stays on during a session.");
    println!("  Keep this window open. Closing it ends the host.\n");
}

/// `--unattended on|off`: the setting changes without a session, and says
/// what it now means.
fn set_unattended(startup: &Startup, on: bool) -> Result<(), String> {
    HostSettings { unattended_access: on }
        .save(&startup.secrets)
        .map_err(|e| e.to_string())?;
    println!("  {}", unattended_line(on));
    Ok(())
}

/// The shell starts a second copy of this program to carry the browser's answer
/// back, and that copy's window closes the instant it exits. On success that is
/// right. On failure it would take the only explanation with it, so the window
/// stays until Enter.
fn deliver_callback(startup: &Startup, url: &str) -> Result<(), String> {
    match rc_host::urlhandler::deliver(&startup.secrets, url) {
        Ok(()) => {
            println!("  Sign-in handed back to the SkipperDesk window. This one can close.");
            Ok(())
        }
        Err(e) => Err(format!("the sign-in could not be handed back ({e})")),
    }
}

/// Nobody can connect to a PC that is not signed in, so a launch that finds no
/// account goes straight to the browser rather than telling the user about a
/// command. Every later launch just says who it is signed in as.
async fn ensure_signed_in(
    backend: &Backend,
    secrets: &SecretStore,
    key: &DeviceKey,
    identity: &IdentityRecord,
) -> Result<(), String> {
    match account(backend, secrets, key)?.state() {
        AccountState::Linked { email } if !email.is_empty() => println!("  Signed in as {email}.\n"),
        AccountState::Linked { .. } => println!("  Signed in.\n"),
        AccountState::Linking | AccountState::Unlinked => {
            println!("  This PC is not signed in yet, so nobody can connect to it.");
            sign_in(backend, secrets, key, identity).await?;
            println!();
        }
    }
    Ok(())
}

/// Register, show the panel, sign in if needed, then come online — in that
/// order, because the sign-in binds to the Device ID and the user should read
/// the panel while the browser is open.
async fn host_online<I: Injector + Send + 'static, B: CaptureBackend>(
    mut host: Host<I, B>,
    events: mpsc::Receiver<PumpEvent>,
    backend: &Backend,
) -> Result<(), String> {
    host.ensure_registered().await?;
    print_banner(host.identity(), host.unattended_access());
    ensure_signed_in(backend, host.secrets(), host.key(), host.identity()).await?;
    refresh_quality_ceiling(backend, host.identity(), host.quality_ceiling());
    host.run(events).await
}

fn config(backend: &Backend) -> HostConfig {
    HostConfig {
        signaling_url: backend.api.signaling_url(),
        label: env_or("RC_DEVICE_LABEL", "Windows Host"),
        unattended_override: unattended_override(
            std::env::var("RC_UNATTENDED").ok().as_deref(),
        ),
        force_relay: std::env::var("RC_ICE_POLICY").map(|v| v == "relay").unwrap_or(false),
        quality_ceiling: QualityCeiling::default(),
        media_stats: env_or("RC_MEDIA_STATS", "0") == "1",
    }
}

/// The Mac's `AccountLinker.startRefreshing`: the entitlement is re-read every
/// `refreshAfterSec`, as the last answer asked, and the host gate reads the
/// ceiling and its age from the shared cell. It runs on its own store handle
/// and key copy because the host owns the originals for its lifetime.
fn refresh_quality_ceiling(backend: &Backend, identity: &IdentityRecord, ceiling: QualityCeiling) {
    let secrets = SecretStore::open(identity_directory().join("secrets"));
    let (Ok(secrets), Ok(key)) = (secrets, identity.device_key()) else {
        eprintln!("rc-host: the account could not be read; quality stays at auto");
        return;
    };
    let backend = backend.clone();
    tokio::spawn(async move {
        let Ok(mut account) = account(&backend, &secrets, &key) else { return };
        loop {
            let now = now_ms();
            let entitlement = account.entitlement(now, true).await;
            ceiling.record(entitlement, now);
            let seconds = entitlement.map_or(DEFAULT_REFRESH_AFTER_SEC, |e| e.refresh_after_sec);
            tokio::time::sleep(std::time::Duration::from_secs(seconds.max(1) as u64)).await;
        }
    });
}

/// How long `--sign-in` waits for the browser. The attempt itself expires at
/// `ATTEMPT_LIFETIME_MS`; this is just how long the console stays blocked.
const SIGN_IN_WAIT: std::time::Duration = std::time::Duration::from_secs(600);

enum Command {
    Run { synthetic: bool },
    SignIn,
    SignOut,
    Unattended(Result<bool, String>),
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
    if let Some(choice) = unattended_argument(&args) {
        return Command::Unattended(choice);
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
        Command::LinkCallback(url) => deliver_callback(&startup, &url),
        Command::SignIn => {
            sign_in(&startup.backend, &startup.secrets, &startup.key, &startup.identity).await
        }
        Command::SignOut => sign_out(&startup).await,
        Command::Unattended(choice) => choice.and_then(|on| set_unattended(&startup, on)),
        Command::Run { synthetic } => run(startup, synthetic).await,
    };
    if let Err(e) = outcome {
        // A double-clicked program's window closes with it, and would take the
        // only explanation along.
        eprintln!("rc-host: {e}");
        eprintln!("  Press Enter to close this window.");
        let _ = std::io::stdin().read_line(&mut String::new());
        std::process::exit(1);
    }
}

fn account<'a>(
    backend: &Backend,
    secrets: &'a SecretStore,
    key: &'a DeviceKey,
) -> Result<Account<'a>, String> {
    let api = ApiClient::new(backend.api.clone(), env!("CARGO_PKG_VERSION"))
        .map_err(|e| e.to_string())?;
    Ok(Account::new(
        api,
        secrets,
        key,
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
async fn sign_in(
    backend: &Backend,
    secrets: &SecretStore,
    key: &DeviceKey,
    identity: &IdentityRecord,
) -> Result<(), String> {
    if let Ok(executable) = std::env::current_exe() {
        if let Err(e) = rc_host::urlhandler::register(&executable) {
            eprintln!("rc-host: the sign-in return handler could not be registered ({e})");
        }
    }
    if identity.device_id.is_empty() || !identity.server_registered {
        return Err(
            "this PC has no Device ID yet. Start the host once so it can register, then sign in."
                .into(),
        );
    }
    // A URL left over from an abandoned attempt must not be read as this one's.
    let _ = rc_host::urlhandler::take(secrets);

    let mut account = account(backend, secrets, key)?;
    let url = account.begin_sign_in(&backend.web, now_ms()).await?;
    println!("\n  Opening your browser to sign in.");
    println!("  If it does not open, paste this address into it:\n\n  {url}\n");
    if let Err(e) = rc_host::urlhandler::open_in_browser(&url) {
        eprintln!("rc-host: {e}");
    }

    let deadline = std::time::Instant::now() + SIGN_IN_WAIT;
    let callback = loop {
        if let Some(url) = rc_host::urlhandler::take(secrets) {
            break url;
        }
        if std::time::Instant::now() >= deadline {
            return Err("no answer came back from the browser; open rc-host.exe again to retry".into());
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
    let mut account = account(&startup.backend, &startup.secrets, &startup.key)?;
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

/// The synthetic screen's size: 1280x720, or `RC_SYNTHETIC_SIZE=WIDTHxHEIGHT`
/// to load the encoder like a larger display does.
fn synthetic_backend() -> SyntheticBackend {
    let size = std::env::var("RC_SYNTHETIC_SIZE").ok().and_then(|v| {
        let (w, h) = v.split_once('x')?;
        Some((w.trim().parse().ok()?, h.trim().parse().ok()?))
    });
    let (width, height) = size.unwrap_or((1280, 720));
    SyntheticBackend { width, height }
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
        synthetic_backend(),
        startup.secrets,
        Some(startup.identity_path),
    );
    host_online(host, events, &startup.backend).await
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
    host_online(host, events, &startup.backend).await
}

#[cfg(not(windows))]
async fn run(startup: Startup, _synthetic: bool) -> Result<(), String> {
    // There is no real capture or injection to offer here, so this build is the
    // diagnostic one whether or not --synthetic was passed.
    eprintln!("rc-host: non-Windows build — diagnostic mode only");
    run_synthetic(startup).await
}
