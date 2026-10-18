//! macOS gesture names -> Windows key chords.
//!
//! PROTOCOL.md §5 fixes the nine names; what they *mean* is per-host. A chord is
//! pressed in order and released in reverse, which is what Windows shell
//! shortcuts expect.

use rc_proto::ctrl::GestureName;

use crate::keycodes::{vk, WinKey};

/// A gesture's Windows realisation.
pub struct GestureChord {
    /// Keys to press in order, then release in reverse.
    pub keys: &'static [WinKey],
    /// What the user sees happen, for the controller's palette label.
    pub label: &'static str,
}

const LWIN: WinKey = WinKey { vk: vk::LWIN, extended: true };
const LSHIFT: WinKey = WinKey { vk: vk::LSHIFT, extended: false };
const LCTRL: WinKey = WinKey { vk: vk::LCONTROL, extended: false };
const LALT: WinKey = WinKey { vk: vk::LMENU, extended: false };
const TAB: WinKey = WinKey { vk: vk::TAB, extended: false };
const ESC: WinKey = WinKey { vk: vk::ESCAPE, extended: false };
const KEY_D: WinKey = WinKey { vk: vk::letter(b'D'), extended: false };
const KEY_S: WinKey = WinKey { vk: vk::letter(b'S'), extended: false };
const KEY_L: WinKey = WinKey { vk: vk::letter(b'L'), extended: false };

/// Every gesture resolves to a chord. There is no `Option` here on purpose: a
/// gesture that silently did nothing would look like a broken connection, and
/// the exhaustive `match` means adding a tenth gesture to the protocol fails to
/// compile until it is given a Windows meaning.
///
/// Windows has no per-application window exposé; Task View is the closest thing that is not simply nothing.
pub fn chord_for(gesture: GestureName) -> GestureChord {
    use GestureName::*;
    match gesture {
        MissionControl => GestureChord { keys: &[LWIN, TAB], label: "Task View" },
        AppExpose => GestureChord { keys: &[LWIN, TAB], label: "Task View" },
        ShowDesktop => GestureChord { keys: &[LWIN, KEY_D], label: "Show Desktop" },
        Launchpad => GestureChord { keys: &[LWIN], label: "Start Menu" },
        Spotlight => GestureChord { keys: &[LWIN, KEY_S], label: "Search" },
        AppSwitcher => GestureChord { keys: &[LALT, TAB], label: "Switch App" },
        ScreenshotRegion => {
            GestureChord { keys: &[LWIN, LSHIFT, KEY_S], label: "Snip Screenshot" }
        }
        ForceQuit => GestureChord { keys: &[LCTRL, LSHIFT, ESC], label: "Task Manager" },
        LockScreen => GestureChord { keys: &[LWIN, KEY_L], label: "Lock Screen" },
    }
}
