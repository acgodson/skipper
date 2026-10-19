//! `rc-host` entry point.
//!
//!   rc-host                     the real host (Windows: Desktop Duplication +
//!                               SendInput), with its window and tray icon
//!   rc-host --synthetic         diagnostic mode: a synthetic screen and a
//!                               recording injector, on any OS
//!   rc-host --unattended on|off whether a controller that proves the access
//!                               code connects without asking; persisted
//!   rc-host --sign-in | --sign-out
//!
//! The two screens are never mixed. A synthetic screen with the real injector
//! would put the controller's clicks onto whatever is actually on the host's
//! desktop while showing a test pattern, which is worse than showing nothing:
//! when capture cannot start, the host comes online, says capture is
//! unavailable, and suspends remote input.
//!
//! On Windows this is a windowed program with no console, so nothing it does
//! can be paused by someone selecting text in a terminal. What a terminal run
//! would print goes to the log, and a command-line flag answers in a message
//! box. The diagnostic build elsewhere prints exactly as it always has.

#![cfg_attr(windows, windows_subsystem = "windows")]

use std::path::PathBuf;

use rc_host::account::{Account, AccountState};
use rc_host::api::{ApiClient, DEFAULT_REFRESH_AFTER_SEC};
use rc_host::host::stopped;
use rc_host::inject::Injector;
use rc_host::media::CaptureBackend;
use rc_host::pump::PumpEvent;
use rc_host::settings::{save_unattended, unattended_argument, unattended_line, unattended_override};
use rc_host::status::{AccountRequest, AccountView, HostEvent};
use rc_host::{
    paths, report, say, Backend, Host, HostConfig, HostControls, QualityCeiling, RecordingInjector, SecretStore,
    SyntheticBackend,
};
use rc_identity::{access_code, DeviceKey, IdentityRecord};
use tokio::sync::mpsc;

fn env_or(key: &str, default: &str) -> String {
    std::env::var(key).unwrap_or_else(|_| default.to_string())
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
    let identity_path = paths::data_directory().join("identity.json");
    let secrets = SecretStore::open(paths::secrets_directory()).map_err(|e| e.to_string())?;

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

/// Good enough for a createdAt stamp without a date crate.
fn now_iso8601() -> String {
    let secs = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0);
    format!("unix:{secs}")
}

/// The at-a-glance panel the user reads to pair from their Mac: the Device ID
/// and the access code, formatted the same way the Mac host window shows them,
/// and whether a connection will ask whoever is here, in the Mac's words. The
/// window shows the same through [`HostEvent`]s.
fn print_banner(identity: &IdentityRecord, unattended: bool) {
    report::event(HostEvent::identity(identity));
    report::event(HostEvent::Unattended(unattended));
    #[cfg(not(windows))]
    print_console_banner(identity, unattended);
}

/// The terminal's version of the panel. The window shows these itself, and
/// the Windows log never holds the access code.
#[cfg(not(windows))]
fn print_console_banner(identity: &IdentityRecord, unattended: bool) {
    let id = if identity.device_id.is_empty() {
        "registering…".to_string()
    } else {
        access_code::formatted_device_id(&identity.device_id)
    };
    say!("\n  RemoteControl — Windows host");
    say!("  ---------------------------------------------");
    say!("  Device ID     {id}");
    say!("  Access code   {}", access_code::formatted(&identity.access_code));
    say!("  ---------------------------------------------");
    say!("  {}", unattended_line(unattended));
    say!("  ---------------------------------------------");
    say!("  Enter these on your Mac's controller to connect.");
    if !unattended {
        say!("  Leaving this PC on its own? Run  rc-host.exe --unattended on");
        say!("  so connections do not wait for someone to answer here.");
    }
    say!("  This PC will not fall asleep on its own while this window is open");
    say!("  and online, and its screen stays on during a session.");
    say!("  Keep this window open. Closing it ends the host.\n");
}

/// What a command-line run says when it is done: printed in the terminal, or
/// in a message box on Windows, where there is no terminal.
fn tell(text: &str) {
    #[cfg(not(windows))]
    println!("{text}");
    #[cfg(windows)]
    rc_host::ui::message_box(text.trim(), false);
}

/// Ends a run that failed. A double-clicked program would take the only
/// explanation with it, so it is shown in a message box on Windows; the
/// terminal build waits for Enter after a command, as it always has.
fn fail(error: &str, pause: bool) -> ! {
    report!("{error}");
    #[cfg(windows)]
    {
        let _ = pause;
        rc_host::ui::message_box(error, true);
    }
    #[cfg(not(windows))]
    if pause {
        eprintln!("  Press Enter to close this window.");
        let _ = std::io::stdin().read_line(&mut String::new());
    }
    std::process::exit(1)
}

/// `--unattended on|off`: the setting changes without a session, and says
/// what it now means. A host already running picks it up at once.
fn set_unattended(startup: &Startup, on: bool) -> Result<(), String> {
    save_unattended(&startup.secrets, on)?;
    #[cfg(windows)]
    rc_host::ui::settings_changed_in_running_instance();
    tell(&format!("  {}", unattended_line(on)));
    Ok(())
}

/// The shell starts a second copy of this program to carry the browser's
/// answer back. On success it hands the waiting window the foreground and
/// leaves quietly; on failure it says why.
fn deliver_callback(startup: &Startup, url: &str) -> Result<(), String> {
    match rc_host::urlhandler::deliver(&startup.secrets, url) {
        Ok(()) => {
            say!("  Sign-in handed back to the SkipperDesk window. This one can close.");
            #[cfg(windows)]
            rc_host::ui::show_running_instance();
            Ok(())
        }
        Err(e) => Err(format!("the sign-in could not be handed back ({e})")),
    }
}

fn account_view(backend: &Backend, secrets: &SecretStore, key: &DeviceKey) -> AccountView {
    match account(backend, secrets, key).map(|a| a.state()) {
        Ok(AccountState::Linked { email }) => AccountView::SignedIn { email },
        _ => AccountView::SignedOut,
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
    let state = account(backend, secrets, key)?.state();
    report::event(HostEvent::Account(account_view(backend, secrets, key)));
    match state {
        AccountState::Linked { email } if !email.is_empty() => say!("  Signed in as {email}.\n"),
        AccountState::Linked { .. } => say!("  Signed in.\n"),
        AccountState::Linking | AccountState::Unlinked => {
            say!("  This PC is not signed in yet, so nobody can connect to it.");
            sign_in(backend, secrets, key, identity).await?;
            say!();
        }
    }
    Ok(())
}

/// The window's account service: the first launch's automatic sign-in, then
/// whatever the window asks for, one at a time and off the window's thread.
/// After each, the window is told the account's real state.
fn spawn_account_service(
    backend: Backend,
    identity: IdentityRecord,
    mut requests: mpsc::UnboundedReceiver<AccountRequest>,
) -> Result<(), String> {
    let secrets = SecretStore::open(paths::secrets_directory()).map_err(|e| e.to_string())?;
    let key = identity.device_key().map_err(|e| e.to_string())?;
    tokio::spawn(async move {
        if let Err(e) = ensure_signed_in(&backend, &secrets, &key, &identity).await {
            report!("{e}");
        }
        report::event(HostEvent::Account(account_view(&backend, &secrets, &key)));
        while let Some(request) = requests.recv().await {
            let signed_in = account_view(&backend, &secrets, &key).is_signed_in();
            let outcome = match request {
                AccountRequest::SignIn if !signed_in => sign_in(&backend, &secrets, &key, &identity).await.map(drop),
                AccountRequest::SignOut if signed_in => sign_out(&backend, &secrets, &key).await.map(|said| report!("{}", said.trim())),
                _ => Ok(()),
            };
            if let Err(e) = outcome {
                report!("{e}");
            }
            report::event(HostEvent::Account(account_view(&backend, &secrets, &key)));
        }
    });
    Ok(())
}

/// How the owner reaches the account: in the terminal build, the blocking
/// first-launch sign-in; with a window, the window's requests.
type AccountRequests = Option<mpsc::UnboundedReceiver<AccountRequest>>;

/// Register, show the panel, sign in if needed — in that order, because the
/// sign-in binds to the Device ID and the user should read the panel while the
/// browser is open.
async fn prepare<I: Injector + Send + 'static, B: CaptureBackend>(
    host: &mut Host<I, B>,
    backend: &Backend,
    requests: AccountRequests,
) -> Result<(), String>
where
    B::Source: Send,
{
    host.ensure_registered().await?;
    print_banner(host.identity(), host.unattended_access());
    match requests {
        Some(requests) => spawn_account_service(backend.clone(), host.identity().clone(), requests)?,
        None => ensure_signed_in(backend, host.secrets(), host.key(), host.identity()).await?,
    }
    refresh_quality_ceiling(backend, host.identity(), host.quality_ceiling());
    Ok(())
}

/// Preparing can wait on the network; a stop asked for meanwhile ends it there,
/// since no session exists yet. Once the host runs, stopping is its own job.
async fn host_online<I: Injector + Send + 'static, B: CaptureBackend>(
    mut host: Host<I, B>,
    events: mpsc::Receiver<PumpEvent>,
    backend: &Backend,
    controls: HostControls,
    requests: AccountRequests,
) -> Result<(), String>
where
    B::Source: Send,
{
    let mut shutdown = controls.shutdown.clone();
    tokio::select! {
        prepared = prepare(&mut host, backend, requests) => prepared?,
        _ = stopped(&mut shutdown) => return Ok(()),
    }
    host.run(events, controls).await
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
        software_encoder: env_or("RC_ENCODER", "auto") == "software",
    }
}

/// The Mac's `AccountLinker.startRefreshing`: the entitlement is re-read every
/// `refreshAfterSec`, as the last answer asked, and the host gate reads the
/// ceiling and its age from the shared cell. It runs on its own store handle
/// and key copy because the host owns the originals for its lifetime.
fn refresh_quality_ceiling(backend: &Backend, identity: &IdentityRecord, ceiling: QualityCeiling) {
    let secrets = SecretStore::open(paths::secrets_directory());
    let (Ok(secrets), Ok(key)) = (secrets, identity.device_key()) else {
        report!("the account could not be read; quality stays at auto");
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

/// How long a sign-in waits for the browser. The attempt itself expires at
/// `ATTEMPT_LIFETIME_MS`; this is just how long this run waits for it.
const SIGN_IN_WAIT: std::time::Duration = std::time::Duration::from_secs(600);

enum Command {
    Run { synthetic: bool },
    SignIn,
    SignOut,
    Unattended(Result<bool, String>),
    /// The shell handing this process a `skipperdesk://link` URL.
    LinkCallback(String),
}

/// The shell may also pass the URL on its own, depending on how the handler was registered by an earlier build.
fn command() -> Command {
    let args: Vec<String> = std::env::args().skip(1).collect();
    if let Some(index) = args.iter().position(|a| a == "--link-callback") {
        return match args.get(index + 1) {
            Some(url) => Command::LinkCallback(url.clone()),
            None => Command::Run { synthetic: false },
        };
    }
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
    #[cfg(windows)]
    set_dpi_awareness();
    let command = command();
    let startup = match startup() {
        Ok(startup) => startup,
        Err(e) => fail(&e, false),
    };

    let outcome = match command {
        Command::LinkCallback(url) => deliver_callback(&startup, &url),
        Command::SignIn => {
            let signed_in = sign_in(&startup.backend, &startup.secrets, &startup.key, &startup.identity).await;
            #[cfg(windows)]
            if let Ok(who) = &signed_in {
                tell(&format!("Signed in as {who}."));
            }
            signed_in.map(drop)
        }
        Command::SignOut => sign_out(&startup.backend, &startup.secrets, &startup.key)
            .await
            .map(tell),
        Command::Unattended(choice) => choice.and_then(|on| set_unattended(&startup, on)),
        Command::Run { synthetic } => run(startup, synthetic).await,
    };
    if let Err(e) = outcome {
        fail(&e, true);
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
///
/// `reg` is a console program; started from a windowed one it would flash a
/// console window, so it is started without one.
///
/// The fallback is stable and still identifies this machine rather than this run.
fn hardware_id() -> String {
    #[cfg(windows)]
    {
        use std::os::windows::process::CommandExt;
        const CREATE_NO_WINDOW: u32 = 0x0800_0000;
        let read = std::process::Command::new("reg")
            .args([
                "query",
                r"HKLM\SOFTWARE\Microsoft\Cryptography",
                "/v",
                "MachineGuid",
            ])
            .creation_flags(CREATE_NO_WINDOW)
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
/// Answers who is now signed in.
///
/// A URL left over from an abandoned attempt is discarded so it is not read as this one's.
async fn sign_in(
    backend: &Backend,
    secrets: &SecretStore,
    key: &DeviceKey,
    identity: &IdentityRecord,
) -> Result<String, String> {
    if let Ok(executable) = std::env::current_exe() {
        if let Err(e) = rc_host::urlhandler::register(&executable) {
            report!("the sign-in return handler could not be registered ({e})");
        }
    }
    if identity.device_id.is_empty() || !identity.server_registered {
        return Err(
            "this PC has no Device ID yet. Start the host once so it can register, then sign in."
                .into(),
        );
    }
    let _ = rc_host::urlhandler::take(secrets);

    let mut account = account(backend, secrets, key)?;
    let url = account.begin_sign_in(&backend.web, now_ms()).await?;
    report::event(HostEvent::Account(AccountView::SigningIn { url: url.clone() }));
    #[cfg(not(windows))]
    print_sign_in_address(&url);
    if let Err(e) = rc_host::urlhandler::open_externally(&url) {
        report!("{e}");
    }

    let deadline = std::time::Instant::now() + SIGN_IN_WAIT;
    let callback = loop {
        if let Some(url) = rc_host::urlhandler::take(secrets) {
            break url;
        }
        if std::time::Instant::now() >= deadline {
            return Err("no answer came back from the browser; sign in again to retry".into());
        }
        tokio::time::sleep(std::time::Duration::from_millis(250)).await;
    };

    let record = account.complete_sign_in(&callback, now_ms()).await?;
    let who = match record.account_email.is_empty() {
        true => "your account".to_string(),
        false => record.account_email.clone(),
    };
    report::event(HostEvent::Account(AccountView::SignedIn { email: record.account_email.clone() }));
    say!("  Signed in as {who}.");
    if let Some(entitlement) = account.entitlement(now_ms(), true).await {
        say!("  Plan status: {}", entitlement.status);
    }
    Ok(who)
}

/// The terminal is told where to go. The window shows the address itself, and
/// it is kept out of the Windows log.
#[cfg(not(windows))]
fn print_sign_in_address(url: &str) {
    say!("\n  Opening your browser to sign in.");
    say!("  If it does not open, paste this address into it:\n\n  {url}\n");
}

/// Answers the sentence that says what happened.
async fn sign_out(backend: &Backend, secrets: &SecretStore, key: &DeviceKey) -> Result<&'static str, String> {
    let mut account = account(backend, secrets, key)?;
    match account.state() {
        AccountState::Linked { .. } => {}
        _ => return Ok("  This PC is not signed in."),
    }
    account.sign_out().await?;
    Ok("  Signed out. This PC can no longer be connected to until it signs in again.")
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
async fn run_synthetic(startup: Startup, controls: HostControls, requests: AccountRequests) -> Result<(), String> {
    report!("--synthetic mode — test pattern, no input is applied to this machine");
    let (host, events) = Host::with_identity_path(
        config(&startup.backend),
        startup.identity,
        startup.key,
        RecordingInjector::default(),
        synthetic_backend(),
        startup.secrets,
        Some(startup.identity_path),
    );
    host_online(host, events, &startup.backend, controls, requests).await
}

/// Per-monitor DPI awareness in code, so a build without the manifest (the
/// no-elevation test build) still captures real pixels, maps clicks correctly
/// and draws its window sharply on a scaled display. It fails harmlessly if a
/// manifest already set it.
#[cfg(windows)]
fn set_dpi_awareness() {
    use windows::Win32::UI::HiDpi::{SetProcessDpiAwarenessContext, DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2};
    unsafe {
        let _ = SetProcessDpiAwarenessContext(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2);
    }
}

/// One host per user: a second launch brings the first one's window forward
/// instead. The window comes up before anything touches the network, so the
/// user sees the host start, and goes away only after the host has stopped.
#[cfg(windows)]
async fn run(startup: Startup, synthetic: bool) -> Result<(), String> {
    use rc_host::capture_windows::DxgiBackend;
    use rc_host::inject_windows::WindowsInjector;
    use rc_host::ui::{Ui, UiChannels};

    if !rc_host::ui::claim_single_instance() {
        rc_host::ui::show_running_instance();
        return Ok(());
    }
    let (stop_tx, shutdown) = tokio::sync::watch::channel(false);
    let (answers_tx, answers) = mpsc::channel(4);
    let (settings_tx, settings_changed) = mpsc::channel(1);
    let (account_tx, account_rx) = mpsc::unbounded_channel();
    let ui = Ui::start(UiChannels {
        shutdown: stop_tx,
        answers: answers_tx,
        settings_changed: settings_tx,
        account: account_tx,
        secrets: SecretStore::open(paths::secrets_directory()).map_err(|e| e.to_string())?,
    })?;
    let controls = HostControls { shutdown, answers, settings_changed };

    let outcome = match synthetic {
        true => run_synthetic(startup, controls, Some(account_rx)).await,
        false => {
            let (host, events) = Host::with_identity_path(
                config(&startup.backend),
                startup.identity,
                startup.key,
                WindowsInjector::new(),
                DxgiBackend::primary_display(),
                startup.secrets,
                Some(startup.identity_path),
            );
            host_online(host, events, &startup.backend, controls, Some(account_rx)).await
        }
    };
    ui.finish();
    outcome
}

/// There is no real capture or injection here, so this build is the diagnostic one whether or not `--synthetic` was passed.
#[cfg(not(windows))]
async fn run(startup: Startup, _synthetic: bool) -> Result<(), String> {
    report!("non-Windows build — diagnostic mode only");
    run_synthetic(startup, HostControls::console(), None).await
}
