//! Which Windows modifier keys a macOS `mods` bitmask should hold down.
//!
//! This is the one place where the translation is a *judgement*, not a lookup,
//! so the judgement is named and configurable rather than buried in a match arm.

use rc_proto::ctrl::KeyModifiers;

use crate::keycodes::{vk, WinKey};

/// How the macOS Command key is presented to Windows.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum CommandPolicy {
    /// Command becomes **Control**. ⌘C copies, ⌘S saves, ⌘Tab is handled by the
    /// gesture palette. This is what a Mac user's fingers expect and is the
    /// default.
    ///
    /// The cost: macOS Control also becomes Control, so ⌃C and ⌘C arrive
    /// indistinguishable. That only bites in a terminal, where ⌃C means
    /// interrupt and ⌘C means copy.
    #[default]
    AsControl,
    /// Command becomes the **Windows key**. Correct only if the controlling
    /// keyboard is a Windows keyboard whose Win key macOS reported as Command.
    AsWindows,
}

/// The full modifier translation policy.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub struct ModifierPolicy {
    pub command: CommandPolicy,
}

/// The Windows modifier keys to hold for a given macOS `mods` bitmask.
///
/// Caps Lock is deliberately **not** returned: on macOS it is a reported *state*
/// while on Windows it is a *toggle*. Pressing `VK_CAPITAL` because the
/// controller had Caps Lock on would flip the host's caps state on every
/// keystroke and leave it stuck on afterwards. The shift bit already carries the
/// intent for the character being typed.
///
/// The macOS `fn` bit is dropped for the same reason as in the keycode table:
/// Windows has nothing it means.
pub fn modifier_keys(mods: KeyModifiers, policy: ModifierPolicy) -> Vec<WinKey> {
    let mods = KeyModifiers::from_wire(mods.0);
    let mut keys = Vec::with_capacity(4);
    let mut push = |k: WinKey| {
        if !keys.contains(&k) {
            keys.push(k);
        }
    };

    if mods.contains(KeyModifiers::SHIFT) {
        push(WinKey::new(vk::LSHIFT));
    }
    if mods.contains(KeyModifiers::CONTROL) {
        push(WinKey::new(vk::LCONTROL));
    }
    if mods.contains(KeyModifiers::OPTION) {
        push(WinKey::new(vk::LMENU));
    }
    if mods.contains(KeyModifiers::COMMAND) {
        push(match policy.command {
            // Deduplicated by `push`: ⌃⌘ collapses to a single Control, which is
            // what makes the chord land instead of double-pressing Control.
            CommandPolicy::AsControl => WinKey::new(vk::LCONTROL),
            CommandPolicy::AsWindows => WinKey::ext(vk::LWIN),
        });
    }
    keys
}

/// Whether this key event should be injected as **text** rather than as a
/// keystroke.
///
/// Preferring `chars` sidesteps the entire keyboard-layout problem: the
/// controller already resolved the key to the character the user meant, so the
/// host can inject that character directly with `KEYEVENTF_UNICODE` and never
/// consult the physical-position table.
///
/// It must **not** be used when a non-shift modifier is held: ⌘C must arrive as
/// Ctrl+C, not as the letter "c". Shift is the exception because it is already
/// baked into `chars` — the controller sent "C", not "c".
pub fn should_inject_as_text(chars: &str, mods: KeyModifiers) -> bool {
    if chars.is_empty() {
        return false;
    }
    let mods = KeyModifiers::from_wire(mods.0);
    let non_text = KeyModifiers::CONTROL | KeyModifiers::OPTION | KeyModifiers::COMMAND;
    if mods.0 & non_text.0 != 0 {
        return false;
    }
    // Control characters (Return, Tab, Escape, Backspace) arrive in `chars` on
    // macOS but must be injected as real keys so that applications see the
    // keystroke rather than a stray control character.
    !chars.chars().any(|c| c.is_control())
}
