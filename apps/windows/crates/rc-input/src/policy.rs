//! The Mac -> Windows key policy, as one named thing.
//!
//! The wire contract is Mac-oriented and stays that way: `key_down.keycode` is a
//! macOS virtual keycode for every peer that exists (PROTOCOL.md §5), and
//! nothing here reinterprets those numbers as Windows VK codes. This module is
//! the adapter that owns the whole translation, so a future Windows *controller*
//! can produce macOS keycodes from the same table read in the other direction
//! instead of growing a second dialect.
//!
//! The split that makes that reuse possible:
//!
//! * [`KeyPolicy::physical`] answers "which Windows key is this position", and
//!   [`KeyPolicy::chord_modifiers`] answers "which modifiers are held" - both
//!   pure lookups over the Mac vocabulary.
//! * [`KeyPolicy::resolve`] decides between those and the already-resolved
//!   `chars` text. Only this last step is a judgement, and it is the only part a
//!   controller would not reuse.
//!
//! The policy itself:
//!
//! * Command+C/V/X/A/Z become Ctrl+C/V/X/A/Z — the five that have to work or the
//!   product feels broken. They fall out of Command -> Ctrl plus the physical
//!   table rather than being special-cased, and are tested as a named set.
//! * Command -> Ctrl ([`crate::CommandPolicy::AsControl`], the default),
//!   Control -> Ctrl, Option -> Alt, Shift -> Shift.
//! * Command together with Control deduplicates to a single Ctrl: pressing it
//!   twice and releasing once leaves a stuck modifier.
//! * Caps Lock and fn are dropped — a macOS state bit against a Windows toggle,
//!   and no analogue at all, respectively.
//! * macOS Delete is Backspace; macOS Forward Delete is the extended Delete.
//! * Arrows and Home/End/PageUp/PageDown take the extended-key flag, without
//!   which they collide with the numpad when Num Lock is off.

use rc_proto::ctrl::{KeyEvent, KeyModifiers};

use crate::keycodes::{kvk, map_keycode, vk, WinKey};
use crate::modifiers::{modifier_keys, should_inject_as_text, ModifierPolicy};

/// What a `key_down`/`key_up` means on Windows.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum KeyResolution {
    /// Inject these characters verbatim, sidestepping keyboard layout entirely.
    /// Never chosen when a chord modifier is held - Command+C must not type "c".
    Text(String),
    /// Hold `modifiers`, then act on `key`. `key: None` means the modifiers are
    /// the whole of it.
    Keystroke { modifiers: Vec<WinKey>, key: Option<WinKey> },
    /// Deliberately nothing: Caps Lock, fn, and keycodes with no Windows
    /// meaning. §0's "ignore what you do not recognise", applied to keys.
    Ignored,
}

/// The policy. One value, carried by the host for the life of a session.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub struct KeyPolicy {
    pub modifiers: ModifierPolicy,
}

impl KeyPolicy {
    /// The Windows key at the physical position a macOS keycode names. No
    /// judgement, no modifier state - the half a controller reuses.
    pub fn physical(keycode: i32) -> Option<WinKey> {
        map_keycode(keycode)
    }

    /// The Windows modifiers a macOS `mods` bitmask holds down, deduplicated.
    pub fn chord_modifiers(&self, mods: KeyModifiers) -> Vec<WinKey> {
        modifier_keys(mods, self.modifiers)
    }

    /// The sided Windows modifier a macOS keycode *is*, for the `flagsChanged`
    /// events the controller sends as `key_down`/`key_up` of the modifier
    /// itself. `None` for anything that is not a modifier position.
    pub fn modifier_at(&self, keycode: i32) -> Option<WinKey> {
        Some(match keycode {
            kvk::SHIFT => WinKey::new(vk::LSHIFT),
            kvk::RIGHT_SHIFT => WinKey::new(vk::RSHIFT),
            kvk::CONTROL => WinKey::new(vk::LCONTROL),
            kvk::RIGHT_CONTROL => WinKey::ext(vk::RCONTROL),
            kvk::OPTION => WinKey::new(vk::LMENU),
            kvk::RIGHT_OPTION => WinKey::ext(vk::RMENU),
            kvk::COMMAND | kvk::RIGHT_COMMAND => self.command_key(),
            _ => return None,
        })
    }

    fn command_key(&self) -> WinKey {
        self.chord_modifiers(KeyModifiers::COMMAND)
            .first()
            .copied()
            .unwrap_or(WinKey::new(vk::LCONTROL))
    }

    /// Whether a Windows VK is one of the modifiers this policy ever holds, so
    /// that reconciling held modifiers cannot accidentally release a real key.
    pub fn is_modifier_vk(vk_code: u16) -> bool {
        matches!(
            vk_code,
            vk::SHIFT
                | vk::LSHIFT
                | vk::RSHIFT
                | vk::CONTROL
                | vk::LCONTROL
                | vk::RCONTROL
                | vk::MENU
                | vk::LMENU
                | vk::RMENU
                | vk::LWIN
                | vk::RWIN
        )
    }

    /// The whole decision for one key event.
    pub fn resolve(&self, event: &KeyEvent) -> KeyResolution {
        let mods = KeyModifiers::from_wire(event.mods);

        if let Some(modifier) = self.modifier_at(event.keycode) {
            // A bare modifier event. Its own `mods` bit may or may not be set
            // yet depending on which edge this is, so it is not consulted: the
            // key being named is the whole message.
            return KeyResolution::Keystroke { modifiers: Vec::new(), key: Some(modifier) };
        }

        // Caps Lock and fn are reported by macOS as *state*. Honouring them
        // would flip a Windows toggle on every keystroke and leave it stuck.
        if matches!(event.keycode, kvk::CAPS_LOCK | kvk::FUNCTION) {
            return KeyResolution::Ignored;
        }

        if should_inject_as_text(&event.chars, mods) {
            return KeyResolution::Text(event.chars.clone());
        }

        let held = self.chord_modifiers(mods);
        match Self::physical(event.keycode) {
            Some(key) => KeyResolution::Keystroke { modifiers: held, key: Some(key) },
            // No Windows key at this position, but the modifiers in the event
            // are still real and still held, so they are reported rather than
            // dropped - otherwise holding Command and pressing an unmapped key
            // would silently release Command.
            None if !held.is_empty() => KeyResolution::Keystroke { modifiers: held, key: None },
            None => KeyResolution::Ignored,
        }
    }
}
