use serde::{Deserialize, Serialize};

/// 0 left, 1 right, 2 middle.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum MouseButton {
    Left,
    Right,
    Middle,
}

impl MouseButton {
    /// An unrecognised button is ignored, not a session-ending error.
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

/// `mods` bitmask: 1 shift, 2 control, 4 option, 8 command, 16 capslock, 32 fn.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Default)]
pub struct KeyModifiers(pub i32);

impl KeyModifiers {
    pub const SHIFT: Self = Self(1 << 0);
    pub const CONTROL: Self = Self(1 << 1);
    pub const OPTION: Self = Self(1 << 2);
    pub const COMMAND: Self = Self(1 << 3);
    pub const CAPS_LOCK: Self = Self(1 << 4);
    pub const FUNCTION: Self = Self(1 << 5);

    /// Every bit the protocol defines; anything outside this is dropped on the way in.
    pub const ALL: Self = Self(0b11_1111);

    /// Masks off undefined bits — the only constructor to use on data from a peer.
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

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum ScrollPhase {
    Begin,
    Changed,
    End,
    Momentum,
}

impl ScrollPhase {
    /// An unrecognised phase becomes `Changed`, never vanishes.
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

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum CursorShapeName {
    Arrow,
    IBeam,
    Crosshair,
    PointingHand,
    OpenHand,
    ClosedHand,
    ResizeLeftRight,
    ResizeUpDown,
    ResizeDiagonalNeSw,
    ResizeDiagonalNwSe,
    NotAllowed,
    Busy,
}

impl CursorShapeName {
    pub const ALL: [CursorShapeName; 12] = [
        Self::Arrow,
        Self::IBeam,
        Self::Crosshair,
        Self::PointingHand,
        Self::OpenHand,
        Self::ClosedHand,
        Self::ResizeLeftRight,
        Self::ResizeUpDown,
        Self::ResizeDiagonalNeSw,
        Self::ResizeDiagonalNwSe,
        Self::NotAllowed,
        Self::Busy,
    ];

    /// An unrecognised shape is drawn as the arrow, never rejected.
    pub fn from_wire(s: &str) -> Self {
        Self::ALL
            .into_iter()
            .find(|shape| shape.as_wire() == s)
            .unwrap_or(Self::Arrow)
    }

    pub fn as_wire(self) -> &'static str {
        match self {
            Self::Arrow => "arrow",
            Self::IBeam => "ibeam",
            Self::Crosshair => "crosshair",
            Self::PointingHand => "pointing_hand",
            Self::OpenHand => "open_hand",
            Self::ClosedHand => "closed_hand",
            Self::ResizeLeftRight => "resize_lr",
            Self::ResizeUpDown => "resize_ud",
            Self::ResizeDiagonalNeSw => "resize_diag_nesw",
            Self::ResizeDiagonalNwSe => "resize_diag_nwse",
            Self::NotAllowed => "not_allowed",
            Self::Busy => "busy",
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum QualityMode {
    Auto,
    Sharp,
    Smooth,
}

impl QualityMode {
    /// The ladder, cheapest first. API.md §4.4 states a ceiling in these values.
    pub const LADDER: [Self; 3] = [Self::Smooth, Self::Auto, Self::Sharp];

    /// The answer for anything unrecognised, missing or stale: a value nobody
    /// understands must never buy the top tier.
    pub const FALLBACK_CEILING: Self = Self::Auto;

    /// Case-insensitive, and an unknown value is `auto`, as on the Mac.
    pub fn from_wire(s: &str) -> Self {
        match s.to_ascii_lowercase().as_str() {
            "sharp" => Self::Sharp,
            "smooth" => Self::Smooth,
            _ => Self::Auto,
        }
    }

    pub fn rank(self) -> usize {
        match self {
            Self::Smooth => 0,
            Self::Auto => 1,
            Self::Sharp => 2,
        }
    }

    /// One rung cheaper, or `None` at the bottom of the ladder.
    pub fn cheaper(self) -> Option<Self> {
        self.rank().checked_sub(1).map(|rank| Self::LADDER[rank])
    }

    /// This mode or `ceiling`, whichever is lower.
    pub fn clamped(self, ceiling: Self) -> Self {
        Self::LADDER[self.rank().min(ceiling.rank())]
    }

    /// The host's whole gate (API.md §4.4). The host owns the encoder, so a
    /// controller may ask for anything and only this answer is configured.
    /// `stated` is `None` without an entitlement and `fresh` is false once it
    /// is older than `refreshAfterSec`; both fail closed to `auto`.
    pub fn permitted(requested: Self, stated: Option<Self>, fresh: bool) -> Self {
        match stated {
            Some(ceiling) if fresh => requested.clamped(ceiling),
            _ => requested.clamped(Self::FALLBACK_CEILING),
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

/// `x`/`y` are normalised `[0,1]`; receivers must clamp.
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

/// `keycode` is a macOS virtual keycode (`kVK_*`).
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct KeyEvent {
    pub keycode: i32,
    pub mods: i32,
    #[serde(default, skip_serializing_if = "String::is_empty")]
    pub chars: String,
}

/// Pixel units at the host's resolution. Positive `dy` moves content up
/// (macOS "natural"), the opposite of the Windows wheel convention.
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
    /// base64 SHA-256 of `text`. A receiver must drop a message whose hash
    /// equals its own last set-or-received hash.
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

/// Host -> controller. Pixel dimensions of the captured display and its backing scale.
#[derive(Debug, Clone, PartialEq, Default, Serialize, Deserialize)]
pub struct DisplayInfo {
    pub w: i32,
    pub h: i32,
    pub scale: f64,
    /// `macos` | `windows`; absent means macos.
    #[serde(default, skip_serializing_if = "String::is_empty")]
    pub os: String,
}

pub mod host_os {
    pub const MACOS: &str = "macos";
    pub const WINDOWS: &str = "windows";
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Quality {
    pub mode: String,
}

/// Host -> controller, on change only.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct CursorShape {
    pub shape: String,
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

/// The only message permitted on the unreliable `hi` channel. The receiver
/// must drop any packet whose `seq` is <= the highest seen.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct MouseMove {
    pub x: f64,
    pub y: f64,
    pub seq: i64,
}

/// Clamps to `[0,1]`; NaN becomes `0.0`.
pub fn clamp_unit(v: f64) -> f64 {
    if v.is_nan() {
        0.0
    } else {
        v.clamp(0.0, 1.0)
    }
}
