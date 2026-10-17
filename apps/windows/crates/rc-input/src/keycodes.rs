//! macOS virtual keycodes (`kVK_*`) and their Windows virtual-key equivalents.
//!
//! PROTOCOL.md §5 fixes `key_down.keycode` as a **macOS** virtual keycode, so a
//! Windows host owns this translation entirely; the controller never changes.
//!
//! Two things here are easy to get wrong and are therefore explicit:
//!
//! 1. **`extended`.** `SendInput` needs `KEYEVENTF_EXTENDEDKEY` for the keys
//!    that live on the grey island and the numeric keypad's divide/enter. Omit
//!    it and Right-Alt behaves as Left-Alt, and the arrow cluster collides with
//!    the numpad when Num Lock is off.
//! 2. **Layout.** This table maps *physical positions*, because that is what a
//!    `kVK_ANSI_*` code is. On a non-US Windows layout the letter produced by a
//!    position may differ. That is why the injector prefers `KeyEvent::chars`
//!    for printable input and falls back to this table only for keys that
//!    produce no text.

/// A Windows key, with the flag `SendInput` needs to disambiguate it.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct WinKey {
    /// Windows virtual-key code (`VK_*`).
    pub vk: u16,
    /// Requires `KEYEVENTF_EXTENDEDKEY`.
    pub extended: bool,
}

impl WinKey {
    pub const fn new(vk: u16) -> Self {
        Self { vk, extended: false }
    }
    pub const fn ext(vk: u16) -> Self {
        Self { vk, extended: true }
    }
}

/// Windows virtual-key constants used by this crate.
///
/// Declared by hand rather than pulled from the `windows` crate so that the
/// whole translation layer builds and is testable on a non-Windows machine —
/// which is where its tests actually run.
pub mod vk {
    pub const BACK: u16 = 0x08;
    pub const TAB: u16 = 0x09;
    pub const CLEAR: u16 = 0x0C;
    pub const RETURN: u16 = 0x0D;
    pub const SHIFT: u16 = 0x10;
    pub const CONTROL: u16 = 0x11;
    pub const MENU: u16 = 0x12;
    pub const CAPITAL: u16 = 0x14;
    pub const ESCAPE: u16 = 0x1B;
    pub const SPACE: u16 = 0x20;
    pub const PRIOR: u16 = 0x21; // Page Up
    pub const NEXT: u16 = 0x22; // Page Down
    pub const END: u16 = 0x23;
    pub const HOME: u16 = 0x24;
    pub const LEFT: u16 = 0x25;
    pub const UP: u16 = 0x26;
    pub const RIGHT: u16 = 0x27;
    pub const DOWN: u16 = 0x28;
    pub const DELETE: u16 = 0x2E;
    pub const HELP: u16 = 0x2F;
    pub const LWIN: u16 = 0x5B;
    pub const RWIN: u16 = 0x5C;
    pub const NUMPAD0: u16 = 0x60;
    pub const MULTIPLY: u16 = 0x6A;
    pub const ADD: u16 = 0x6B;
    pub const SUBTRACT: u16 = 0x6D;
    pub const DECIMAL: u16 = 0x6E;
    pub const DIVIDE: u16 = 0x6F;
    pub const F1: u16 = 0x70;
    pub const LSHIFT: u16 = 0xA0;
    pub const RSHIFT: u16 = 0xA1;
    pub const LCONTROL: u16 = 0xA2;
    pub const RCONTROL: u16 = 0xA3;
    pub const LMENU: u16 = 0xA4;
    pub const RMENU: u16 = 0xA5;
    pub const VOLUME_MUTE: u16 = 0xAD;
    pub const VOLUME_DOWN: u16 = 0xAE;
    pub const VOLUME_UP: u16 = 0xAF;
    pub const OEM_1: u16 = 0xBA; // ; :
    pub const OEM_PLUS: u16 = 0xBB; // = +
    pub const OEM_COMMA: u16 = 0xBC; // , <
    pub const OEM_MINUS: u16 = 0xBD; // - _
    pub const OEM_PERIOD: u16 = 0xBE; // . >
    pub const OEM_2: u16 = 0xBF; // / ?
    pub const OEM_3: u16 = 0xC0; // ` ~
    pub const OEM_4: u16 = 0xDB; // [ {
    pub const OEM_5: u16 = 0xDC; // \ |
    pub const OEM_6: u16 = 0xDD; // ] }
    pub const OEM_7: u16 = 0xDE; // ' "
    pub const OEM_102: u16 = 0xE2; // ISO < > / backslash
    /// `VK_0`..`VK_9` are the ASCII digits; `VK_A`..`VK_Z` the ASCII capitals.
    pub const fn digit(d: u8) -> u16 {
        (b'0' + d) as u16
    }
    pub const fn letter(c: u8) -> u16 {
        c as u16
    }
    pub const fn f(n: u8) -> u16 {
        F1 + (n as u16) - 1
    }
    pub const fn numpad(d: u8) -> u16 {
        NUMPAD0 + d as u16
    }
}

/// macOS virtual keycodes, from Carbon's `HIToolbox/Events.h`.
pub mod kvk {
    pub const A: i32 = 0x00;
    pub const S: i32 = 0x01;
    pub const D: i32 = 0x02;
    pub const F: i32 = 0x03;
    pub const H: i32 = 0x04;
    pub const G: i32 = 0x05;
    pub const Z: i32 = 0x06;
    pub const X: i32 = 0x07;
    pub const C: i32 = 0x08;
    pub const V: i32 = 0x09;
    pub const ISO_SECTION: i32 = 0x0A;
    pub const B: i32 = 0x0B;
    pub const Q: i32 = 0x0C;
    pub const W: i32 = 0x0D;
    pub const E: i32 = 0x0E;
    pub const R: i32 = 0x0F;
    pub const Y: i32 = 0x10;
    pub const T: i32 = 0x11;
    pub const N1: i32 = 0x12;
    pub const N2: i32 = 0x13;
    pub const N3: i32 = 0x14;
    pub const N4: i32 = 0x15;
    pub const N6: i32 = 0x16;
    pub const N5: i32 = 0x17;
    pub const EQUAL: i32 = 0x18;
    pub const N9: i32 = 0x19;
    pub const N7: i32 = 0x1A;
    pub const MINUS: i32 = 0x1B;
    pub const N8: i32 = 0x1C;
    pub const N0: i32 = 0x1D;
    pub const RIGHT_BRACKET: i32 = 0x1E;
    pub const O: i32 = 0x1F;
    pub const U: i32 = 0x20;
    pub const LEFT_BRACKET: i32 = 0x21;
    pub const I: i32 = 0x22;
    pub const P: i32 = 0x23;
    pub const RETURN: i32 = 0x24;
    pub const L: i32 = 0x25;
    pub const J: i32 = 0x26;
    pub const QUOTE: i32 = 0x27;
    pub const K: i32 = 0x28;
    pub const SEMICOLON: i32 = 0x29;
    pub const BACKSLASH: i32 = 0x2A;
    pub const COMMA: i32 = 0x2B;
    pub const SLASH: i32 = 0x2C;
    pub const N: i32 = 0x2D;
    pub const M: i32 = 0x2E;
    pub const PERIOD: i32 = 0x2F;
    pub const TAB: i32 = 0x30;
    pub const SPACE: i32 = 0x31;
    pub const GRAVE: i32 = 0x32;
    /// macOS "Delete" is Backspace.
    pub const DELETE: i32 = 0x33;
    pub const ESCAPE: i32 = 0x35;
    pub const RIGHT_COMMAND: i32 = 0x36;
    pub const COMMAND: i32 = 0x37;
    pub const SHIFT: i32 = 0x38;
    pub const CAPS_LOCK: i32 = 0x39;
    pub const OPTION: i32 = 0x3A;
    pub const CONTROL: i32 = 0x3B;
    pub const RIGHT_SHIFT: i32 = 0x3C;
    pub const RIGHT_OPTION: i32 = 0x3D;
    pub const RIGHT_CONTROL: i32 = 0x3E;
    pub const FUNCTION: i32 = 0x3F;
    pub const F17: i32 = 0x40;
    pub const KEYPAD_DECIMAL: i32 = 0x41;
    pub const KEYPAD_MULTIPLY: i32 = 0x43;
    pub const KEYPAD_PLUS: i32 = 0x45;
    pub const KEYPAD_CLEAR: i32 = 0x47;
    pub const VOLUME_UP: i32 = 0x48;
    pub const VOLUME_DOWN: i32 = 0x49;
    pub const MUTE: i32 = 0x4A;
    pub const KEYPAD_DIVIDE: i32 = 0x4B;
    pub const KEYPAD_ENTER: i32 = 0x4C;
    pub const KEYPAD_MINUS: i32 = 0x4E;
    pub const F18: i32 = 0x4F;
    pub const F19: i32 = 0x50;
    pub const KEYPAD_EQUALS: i32 = 0x51;
    pub const KEYPAD0: i32 = 0x52;
    pub const KEYPAD1: i32 = 0x53;
    pub const KEYPAD2: i32 = 0x54;
    pub const KEYPAD3: i32 = 0x55;
    pub const KEYPAD4: i32 = 0x56;
    pub const KEYPAD5: i32 = 0x57;
    pub const KEYPAD6: i32 = 0x58;
    pub const KEYPAD7: i32 = 0x59;
    pub const F20: i32 = 0x5A;
    pub const KEYPAD8: i32 = 0x5B;
    pub const KEYPAD9: i32 = 0x5C;
    pub const JIS_YEN: i32 = 0x5D;
    pub const JIS_UNDERSCORE: i32 = 0x5E;
    pub const JIS_KEYPAD_COMMA: i32 = 0x5F;
    pub const F5: i32 = 0x60;
    pub const F6: i32 = 0x61;
    pub const F7: i32 = 0x62;
    pub const F3: i32 = 0x63;
    pub const F8: i32 = 0x64;
    pub const F9: i32 = 0x65;
    pub const JIS_EISU: i32 = 0x66;
    pub const F11: i32 = 0x67;
    pub const JIS_KANA: i32 = 0x68;
    pub const F13: i32 = 0x69;
    pub const F16: i32 = 0x6A;
    pub const F14: i32 = 0x6B;
    pub const F10: i32 = 0x6D;
    pub const F12: i32 = 0x6F;
    pub const F15: i32 = 0x71;
    pub const HELP: i32 = 0x72;
    pub const HOME: i32 = 0x73;
    pub const PAGE_UP: i32 = 0x74;
    pub const FORWARD_DELETE: i32 = 0x75;
    pub const F4: i32 = 0x76;
    pub const END: i32 = 0x77;
    pub const F2: i32 = 0x78;
    pub const PAGE_DOWN: i32 = 0x79;
    pub const F1: i32 = 0x7A;
    pub const LEFT_ARROW: i32 = 0x7B;
    pub const RIGHT_ARROW: i32 = 0x7C;
    pub const DOWN_ARROW: i32 = 0x7D;
    pub const UP_ARROW: i32 = 0x7E;
}

/// Translate a macOS virtual keycode to its Windows equivalent.
///
/// `None` means "no sensible Windows key", which the injector treats as a key to
/// drop rather than an error — §0's rule that a receiver ignores what it does
/// not recognise applies to keycodes too.
pub fn map_keycode(mac: i32) -> Option<WinKey> {
    use kvk as k;
    use vk::*;
    Some(match mac {
        // Letters. Physical positions; see the layout note above.
        k::A => WinKey::new(letter(b'A')),
        k::B => WinKey::new(letter(b'B')),
        k::C => WinKey::new(letter(b'C')),
        k::D => WinKey::new(letter(b'D')),
        k::E => WinKey::new(letter(b'E')),
        k::F => WinKey::new(letter(b'F')),
        k::G => WinKey::new(letter(b'G')),
        k::H => WinKey::new(letter(b'H')),
        k::I => WinKey::new(letter(b'I')),
        k::J => WinKey::new(letter(b'J')),
        k::K => WinKey::new(letter(b'K')),
        k::L => WinKey::new(letter(b'L')),
        k::M => WinKey::new(letter(b'M')),
        k::N => WinKey::new(letter(b'N')),
        k::O => WinKey::new(letter(b'O')),
        k::P => WinKey::new(letter(b'P')),
        k::Q => WinKey::new(letter(b'Q')),
        k::R => WinKey::new(letter(b'R')),
        k::S => WinKey::new(letter(b'S')),
        k::T => WinKey::new(letter(b'T')),
        k::U => WinKey::new(letter(b'U')),
        k::V => WinKey::new(letter(b'V')),
        k::W => WinKey::new(letter(b'W')),
        k::X => WinKey::new(letter(b'X')),
        k::Y => WinKey::new(letter(b'Y')),
        k::Z => WinKey::new(letter(b'Z')),

        // Digit row.
        k::N0 => WinKey::new(digit(0)),
        k::N1 => WinKey::new(digit(1)),
        k::N2 => WinKey::new(digit(2)),
        k::N3 => WinKey::new(digit(3)),
        k::N4 => WinKey::new(digit(4)),
        k::N5 => WinKey::new(digit(5)),
        k::N6 => WinKey::new(digit(6)),
        k::N7 => WinKey::new(digit(7)),
        k::N8 => WinKey::new(digit(8)),
        k::N9 => WinKey::new(digit(9)),

        // Punctuation.
        k::EQUAL => WinKey::new(OEM_PLUS),
        k::MINUS => WinKey::new(OEM_MINUS),
        k::LEFT_BRACKET => WinKey::new(OEM_4),
        k::RIGHT_BRACKET => WinKey::new(OEM_6),
        k::BACKSLASH => WinKey::new(OEM_5),
        k::SEMICOLON => WinKey::new(OEM_1),
        k::QUOTE => WinKey::new(OEM_7),
        k::COMMA => WinKey::new(OEM_COMMA),
        k::PERIOD => WinKey::new(OEM_PERIOD),
        k::SLASH => WinKey::new(OEM_2),
        k::GRAVE => WinKey::new(OEM_3),
        k::ISO_SECTION => WinKey::new(OEM_102),

        // Editing and whitespace.
        k::RETURN => WinKey::new(RETURN),
        k::TAB => WinKey::new(TAB),
        k::SPACE => WinKey::new(SPACE),
        k::DELETE => WinKey::new(BACK), // macOS Delete == Backspace
        k::FORWARD_DELETE => WinKey::ext(DELETE),
        k::ESCAPE => WinKey::new(ESCAPE),
        k::HELP => WinKey::ext(HELP),

        // Navigation. All extended.
        k::HOME => WinKey::ext(HOME),
        k::END => WinKey::ext(END),
        k::PAGE_UP => WinKey::ext(PRIOR),
        k::PAGE_DOWN => WinKey::ext(NEXT),
        k::LEFT_ARROW => WinKey::ext(LEFT),
        k::RIGHT_ARROW => WinKey::ext(RIGHT),
        k::UP_ARROW => WinKey::ext(UP),
        k::DOWN_ARROW => WinKey::ext(DOWN),

        // Modifiers. Sided where Windows distinguishes.
        k::SHIFT => WinKey::new(LSHIFT),
        k::RIGHT_SHIFT => WinKey::new(RSHIFT),
        k::CONTROL => WinKey::new(LCONTROL),
        k::RIGHT_CONTROL => WinKey::ext(RCONTROL),
        k::OPTION => WinKey::new(LMENU),
        k::RIGHT_OPTION => WinKey::ext(RMENU),
        // Command maps to Control, not the Windows key -- see `modifiers.rs`.
        k::COMMAND | k::RIGHT_COMMAND => WinKey::new(LCONTROL),
        k::CAPS_LOCK => WinKey::new(CAPITAL),

        // Function row.
        k::F1 => WinKey::new(f(1)),
        k::F2 => WinKey::new(f(2)),
        k::F3 => WinKey::new(f(3)),
        k::F4 => WinKey::new(f(4)),
        k::F5 => WinKey::new(f(5)),
        k::F6 => WinKey::new(f(6)),
        k::F7 => WinKey::new(f(7)),
        k::F8 => WinKey::new(f(8)),
        k::F9 => WinKey::new(f(9)),
        k::F10 => WinKey::new(f(10)),
        k::F11 => WinKey::new(f(11)),
        k::F12 => WinKey::new(f(12)),
        k::F13 => WinKey::new(f(13)),
        k::F14 => WinKey::new(f(14)),
        k::F15 => WinKey::new(f(15)),
        k::F16 => WinKey::new(f(16)),
        k::F17 => WinKey::new(f(17)),
        k::F18 => WinKey::new(f(18)),
        k::F19 => WinKey::new(f(19)),
        k::F20 => WinKey::new(f(20)),

        // Numeric keypad.
        k::KEYPAD0 => WinKey::new(numpad(0)),
        k::KEYPAD1 => WinKey::new(numpad(1)),
        k::KEYPAD2 => WinKey::new(numpad(2)),
        k::KEYPAD3 => WinKey::new(numpad(3)),
        k::KEYPAD4 => WinKey::new(numpad(4)),
        k::KEYPAD5 => WinKey::new(numpad(5)),
        k::KEYPAD6 => WinKey::new(numpad(6)),
        k::KEYPAD7 => WinKey::new(numpad(7)),
        k::KEYPAD8 => WinKey::new(numpad(8)),
        k::KEYPAD9 => WinKey::new(numpad(9)),
        k::KEYPAD_DECIMAL => WinKey::new(DECIMAL),
        k::KEYPAD_MULTIPLY => WinKey::new(MULTIPLY),
        k::KEYPAD_PLUS => WinKey::new(ADD),
        k::KEYPAD_MINUS => WinKey::new(SUBTRACT),
        k::KEYPAD_DIVIDE => WinKey::ext(DIVIDE),
        k::KEYPAD_ENTER => WinKey::ext(RETURN),
        k::KEYPAD_CLEAR => WinKey::new(CLEAR),

        // Media.
        k::VOLUME_UP => WinKey::new(VOLUME_UP),
        k::VOLUME_DOWN => WinKey::new(VOLUME_DOWN),
        k::MUTE => WinKey::new(VOLUME_MUTE),

        // Deliberately unmapped, each for a stated reason:
        //   KEYPAD_EQUALS   - Windows has no numpad '=' virtual key.
        //   FUNCTION        - the macOS fn key has no Windows analogue.
        //   JIS_*           - Japanese-layout keys with no US-Windows equivalent.
        _ => return None,
    })
}
