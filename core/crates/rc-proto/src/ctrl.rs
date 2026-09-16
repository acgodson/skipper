//! Peer-to-peer payloads — surfaces 2 and 3. PROTOCOL.md §5 and §6.
//!
//! The signaling server never sees any of this. Every macOS-specific convention
//! in the protocol lives here, which makes this module the whole of the
//! translation surface a non-macOS host has to implement.

use serde::{Deserialize, Serialize};

/// §5: 0 left, 1 right, 2 middle.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum MouseButton {
    Left,
    Right,
    Middle,
}

impl MouseButton {
    /// §0: an unrecognised button is ignored, not a session-ending error.
    pub fn from_wire(v: i32) -> Option<Self> {
        match v {
            0 => Some(Self::Left),
            1 => Some(Self::Right),
            2 => Some(Self::Middle),
            _ => None,
        }
    }

    pub fn to_wire(self) -> i32 {
        match self {
            Self::Left => 0,
            Self::Right => 1,
            Self::Middle => 2,
        }
    }
}

/// §5 `mods` bitmask: 1 shift, 2 control, 4 option, 8 command, 16 capslock, 32 fn.
///
/// The names are macOS's because the wire is macOS's. What each one *means* on
/// this host is decided in the input layer, not here.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Default)]
pub struct KeyModifiers(pub i32);

impl KeyModifiers {
    pub const SHIFT: Self = Self(1 << 0);
    pub const CONTROL: Self = Self(1 << 1);
    pub const OPTION: Self = Self(1 << 2);
    pub const COMMAND: Self = Self(1 << 3);
    pub const CAPS_LOCK: Self = Self(1 << 4);
    pub const FUNCTION: Self = Self(1 << 5);

    /// Every bit the protocol defines. Anything outside this is dropped on the
    /// way in, so a peer on a newer protocol version cannot hand this host a
    /// flag it would pass to `SendInput` without understanding it.
    pub const ALL: Self = Self(0b11_1111);

    /// Masks off undefined bits — the only constructor that should be used on
    /// data that came from a peer.
    pub fn from_wire(v: i32) -> Self {
        Self(v & Self::ALL.0)
    }

    pub fn contains(self, other: Self) -> bool {
        self.0 & other.0 == other.0
    }

    pub fn insert(&mut self, other: Self) {
        self.0 |= other.0;
    }

    pub fn is_empty(self) -> bool {
        self.0 == 0
    }
}

impl std::ops::BitOr for KeyModifiers {
    type Output = Self;
    fn bitor(self, rhs: Self) -> Self {
        Self(self.0 | rhs.0)
    }
}

/// §5 `scroll.phase`.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum ScrollPhase {
    Begin,
    Changed,
    End,
    Momentum,
}

impl ScrollPhase {
    /// An unrecognised phase becomes `Changed`: a scroll whose phase we do not
    /// know must still scroll, never vanish.
    pub fn from_wire(s: &str) -> Self {
        match s.to_ascii_lowercase().as_str() {
            "begin" => Self::Begin,
            "end" => Self::End,
            "momentum" => Self::Momentum,
            _ => Self::Changed,
        }
    }

    pub fn as_wire(self) -> &'static str {
        match self {
            Self::Begin => "begin",
            Self::Changed => "changed",
            Self::End => "end",
            Self::Momentum => "momentum",
        }
    }
}

/// §5 `gesture.name`.
///
/// The names are macOS's. Each host maps them to whatever its own OS calls the
/// same idea; see the Windows mapping in `rc-host`. `ALL` exists so that a test
/// can assert every variant resolves to a real action, which is what stops a new
/// variant from silently no-op'ing at runtime.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum GestureName {
    MissionControl,
    AppExpose,
    ShowDesktop,
    Launchpad,
    Spotlight,
    AppSwitcher,
    ScreenshotRegion,
    ForceQuit,
    LockScreen,
}

impl GestureName {
    pub const ALL: [GestureName; 9] = [
        Self::MissionControl,
        Self::AppExpose,
        Self::ShowDesktop,
        Self::Launchpad,
        Self::Spotlight,
        Self::AppSwitcher,
        Self::ScreenshotRegion,
        Self::ForceQuit,
        Self::LockScreen,
    ];

    pub fn from_wire(s: &str) -> Option<Self> {
        Some(match s {
            "mission_control" => Self::MissionControl,
            "app_expose" => Self::AppExpose,
            "show_desktop" => Self::ShowDesktop,
            "launchpad" => Self::Launchpad,
            "spotlight" => Self::Spotlight,
            "app_switcher" => Self::AppSwitcher,
            "screenshot_region" => Self::ScreenshotRegion,
            "force_quit" => Self::ForceQuit,
            "lock_screen" => Self::LockScreen,
            _ => return None,
        })
    }

    pub fn as_wire(self) -> &'static str {
        match self {
            Self::MissionControl => "mission_control",
            Self::AppExpose => "app_expose",
            Self::ShowDesktop => "show_desktop",
            Self::Launchpad => "launchpad",
            Self::Spotlight => "spotlight",
            Self::AppSwitcher => "app_switcher",
            Self::ScreenshotRegion => "screenshot_region",
            Self::ForceQuit => "force_quit",
            Self::LockScreen => "lock_screen",
        }
    }
}

/// §5 `quality.mode`.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum QualityMode {
    Auto,
    Sharp,
    Smooth,
}

impl QualityMode {
    pub fn from_wire(s: &str) -> Self {
        match s {
            "sharp" => Self::Sharp,
            "smooth" => Self::Smooth,
            _ => Self::Auto,
        }
    }

    pub fn as_wire(self) -> &'static str {
        match self {
            Self::Auto => "auto",
            Self::Sharp => "sharp",
            Self::Smooth => "smooth",
        }
    }
}

// ---------------------------------------------------------------------------
// Wire payloads
// ---------------------------------------------------------------------------

/// `mouse_down`, `mouse_up`, `mouse_drag`. `x`/`y` are normalised `[0,1]`;
/// receivers **must** clamp (§0).
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct MouseEvent {
    pub button: i32,
    pub x: f64,
    pub y: f64,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Click {
    pub button: i32,
    pub x: f64,
    pub y: f64,
    pub count: i32,
}

/// `key_down` / `key_up`.
///
/// `keycode` is a **macOS virtual keycode** (`kVK_*`). `chars`, when present, is
/// the text the key produced on the controller — preferring it over `keycode`
/// for printable input is what lets a host avoid the entire keyboard-layout
/// translation problem.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct KeyEvent {
    pub keycode: i32,
    pub mods: i32,
    #[serde(default, skip_serializing_if = "String::is_empty")]
    pub chars: String,
}

/// Pixel units at the host's resolution. Positive `dy` means content moves up
/// (macOS "natural"), which is the **opposite** of the Windows wheel convention.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Scroll {
    pub dx: f64,
    pub dy: f64,
    pub phase: String,
}

/// Contents are never logged.
#[derive(Clone, PartialEq, Serialize, Deserialize)]
pub struct ClipboardText {
    pub text: String,
    #[serde(rename = "originId")]
    pub origin_id: String,
    /// base64 SHA-256 of `text`. A receiver **must** drop a message whose hash
    /// equals its own last set-or-received hash; that is the echo-loop guard.
    pub hash: String,
}

impl std::fmt::Debug for ClipboardText {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("ClipboardText")
            .field("text", &format_args!("<{} bytes>", self.text.len()))
            .field("origin_id", &self.origin_id)
            .field("hash", &self.hash)
            .finish()
    }
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Gesture {
    pub name: String,
}

/// Host -> controller. Pixel dimensions of the captured display and its backing
/// scale.
#[derive(Debug, Clone, PartialEq, Default, Serialize, Deserialize)]
pub struct DisplayInfo {
    pub w: i32,
    pub h: i32,
    pub scale: f64,
    /// Host operating system: `macos` | `windows`. **Extension to §5.**
    ///
    /// Purely additive — §0 requires receivers to ignore unknown members, so a
    /// build that predates this field is unaffected and no version bump is
    /// needed. An absent value means macOS, which is what every build shipped
    /// before this field existed was. The controller uses it to label the
    /// gesture palette with the host's own vocabulary ("Task View", not
    /// "Mission Control").
    #[serde(default, skip_serializing_if = "String::is_empty")]
    pub os: String,
}

/// Values for [`DisplayInfo::os`].
pub mod host_os {
    pub const MACOS: &str = "macos";
    pub const WINDOWS: &str = "windows";
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Quality {
    pub mode: String,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Ping {
    pub t: i64,
}

/// Echoes the `ping`'s `t` verbatim; RTT = now - t.
pub type Pong = Ping;

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct SessionClose {
    pub reason: String,
}

/// §6. The only message permitted on the unreliable `hi` channel.
///
/// The receiver **must** drop any packet whose `seq` is <= the highest seen:
/// discarding stale out-of-order positions is the entire reason this channel is
/// unreliable.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct MouseMove {
    pub x: f64,
    pub y: f64,
    pub seq: i64,
}

/// §0: normalised coordinates must be clamped by the receiver. Centralised here
/// so no call site can forget, and so a NaN from a malformed peer becomes a
/// defined position rather than an out-of-bounds pixel.
pub fn clamp_unit(v: f64) -> f64 {
    if v.is_nan() {
        0.0
    } else {
        v.clamp(0.0, 1.0)
    }
}
