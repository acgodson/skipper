//! What the host tells whoever is looking at it: typed events, not parsed
//! lines. The Windows window and tray icon render these; the diagnostic build
//! has no window and drops them.
//!
//! The words are the Mac host's (`HostView`, `ConnectionStatus`, the presence
//! explanations), with "this PC" where the Mac says "this Mac".

use rc_identity::{access_code, IdentityRecord};
use rc_session::SessionPhase;

/// What the capture pump last said about the screen during a session.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub enum Screen {
    #[default]
    Live,
    Locked,
    Unavailable,
}

/// DESIGN.md's tones: a pill, a dot or a banner takes one of these, never a
/// raw colour.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Tone {
    Neutral,
    Accent,
    Positive,
    Attention,
    Critical,
}

/// The host's state, from which the status pill and the hero's sentence follow.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum HostStatus {
    Starting,
    Connecting,
    Offline,
    Online,
    Request { from: String },
    AwaitingConsent { from: String },
    Session { with: String },
    Reconnecting { with: String },
    DesktopLocked { with: String },
    CaptureUnavailable,
    Stopping,
}

impl HostStatus {
    /// `online` is authenticated on the signalling connection, the Mac's
    /// `signalingReady`; the session phase is the shared state machine's.
    pub fn derive(online: bool, phase: &SessionPhase, peer_device_id: Option<&str>, screen: Screen) -> Self {
        let peer = peer_device_id
            .map(access_code::formatted_device_id)
            .unwrap_or_default();
        match phase {
            SessionPhase::Idle | SessionPhase::Closed { .. } => match online {
                true => Self::Online,
                false => Self::Connecting,
            },
            SessionPhase::Connecting => Self::Request { from: peer },
            SessionPhase::AwaitingConsent => Self::AwaitingConsent { from: peer },
            SessionPhase::Reconnecting => Self::Reconnecting { with: peer },
            SessionPhase::Live => match screen {
                Screen::Live => Self::Session { with: peer },
                Screen::Locked => Self::DesktopLocked { with: peer },
                Screen::Unavailable => Self::CaptureUnavailable,
            },
        }
    }

    /// The status pill: a short label and its tone.
    pub fn pill(&self) -> (&'static str, Tone) {
        match self {
            Self::Starting | Self::Connecting | Self::Request { .. } | Self::AwaitingConsent { .. } => {
                ("Connecting…", Tone::Attention)
            }
            Self::Offline | Self::Stopping => ("Offline", Tone::Neutral),
            Self::Online => ("Online", Tone::Positive),
            Self::Session { .. } | Self::DesktopLocked { .. } => ("Session active", Tone::Accent),
            Self::Reconnecting { .. } => ("Reconnecting…", Tone::Attention),
            Self::CaptureUnavailable => ("Session active", Tone::Critical),
        }
    }

    /// The sentence under the codes saying what the state means for the owner.
    pub fn note(&self) -> String {
        match self {
            Self::Starting | Self::Connecting => "Connecting to SkipperDesk…".into(),
            Self::Offline => {
                "Cannot reach SkipperDesk, so no one can connect to this PC right now. Retrying automatically.".into()
            }
            Self::Online => "This PC is reachable. Another Mac can connect with the Device ID and access code above, and this PC will not fall asleep on its own while it is.".into(),
            Self::Request { from } => format!("The Mac {from} is entering this PC's access code."),
            Self::AwaitingConsent { from } => format!("The Mac {from} is waiting for you to allow it."),
            Self::Session { with } => format!("Someone at the Mac {with} is viewing and controlling this PC."),
            Self::Reconnecting { .. } => "The connection wobbled. The session is still open and is recovering — no one has to re-enter the access code.".into(),
            Self::DesktopLocked { .. } => {
                "This PC's desktop is locked or protected, so the other Mac cannot click or type on it right now.".into()
            }
            Self::CaptureUnavailable => {
                "This PC's screen cannot be captured, so the other Mac cannot see it and its clicks are ignored.".into()
            }
            Self::Stopping => "Stopping…".into(),
        }
    }

    /// One line for the tray icon's tooltip and menu.
    pub fn line(&self) -> String {
        match self {
            Self::Starting | Self::Connecting => "Connecting…".into(),
            Self::Offline => "Offline — retrying".into(),
            Self::Online => "Online — ready for connections".into(),
            Self::Request { from } => format!("Connection request from {from}"),
            Self::AwaitingConsent { from } => format!("Waiting for you to allow {from}…"),
            Self::Session { with } => format!("Session with {with}"),
            Self::Reconnecting { with } => format!("Reconnecting to {with}…"),
            Self::DesktopLocked { with } => format!("Session with {with} — desktop locked"),
            Self::CaptureUnavailable => "Capture unavailable — remote input suspended".into(),
            Self::Stopping => "Stopping…".into(),
        }
    }

    pub fn in_session(&self) -> bool {
        matches!(
            self,
            Self::Session { .. } | Self::Reconnecting { .. } | Self::DesktopLocked { .. } | Self::CaptureUnavailable
        )
    }
}

/// Whether this PC is signed in to the account that pays for its sessions.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub enum AccountView {
    #[default]
    Unknown,
    SignedOut,
    SigningIn { url: String },
    SignedIn { email: String },
}

impl AccountView {
    pub fn is_signed_in(&self) -> bool {
        matches!(self, Self::SignedIn { .. })
    }
}

/// The tray's one-line answer to "can someone connect right now?". While
/// idle, not being signed in is the thing that matters; otherwise the state.
pub fn headline(status: &HostStatus, account: &AccountView) -> String {
    let idle = matches!(status, HostStatus::Online | HostStatus::Connecting | HostStatus::Offline);
    match account {
        AccountView::SignedOut if idle => "Not signed in — nobody can connect yet".into(),
        AccountView::SigningIn { .. } if idle => "Continue in your browser…".into(),
        _ => status.line(),
    }
}

/// What the window may ask of the account; the host runs these off the window
/// thread.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum AccountRequest {
    SignIn,
    SignOut,
}

/// Who is asking, as the consent window shows it. Nothing here names the
/// access code.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ConsentRequest {
    pub device_id: String,
    pub fingerprint: String,
    pub replaces_previous: bool,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum HostEvent {
    /// A milestone line for the window's activity log.
    Line(String),
    /// The Device ID and access code, formatted the way the Mac shows them.
    Identity { device_id: String, access_code: String },
    Status(HostStatus),
    Account(AccountView),
    Unattended(bool),
    ConsentOpened(ConsentRequest),
    ConsentClosed,
}

impl HostEvent {
    pub fn identity(record: &IdentityRecord) -> Self {
        let device_id = match record.device_id.is_empty() {
            true => "registering…".to_string(),
            false => access_code::formatted_device_id(&record.device_id),
        };
        Self::Identity {
            device_id,
            access_code: access_code::formatted(&record.access_code),
        }
    }
}

#[cfg(test)]
mod tests;
