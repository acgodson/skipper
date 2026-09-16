//! Translation from the protocol's macOS input semantics to Windows semantics.
//!
//! Deliberately free of any OS call and any `windows` crate dependency, so the
//! whole of it compiles and its tests run on macOS and Linux. The parts that
//! actually touch the machine live in `rc-host`; everything that could be
//! *wrong* lives here, where it can be asserted on.

#![forbid(unsafe_code)]

pub mod gestures;
pub mod keycodes;
pub mod modifiers;
pub mod scroll;

pub use gestures::{chord_for, GestureChord};
pub use keycodes::{map_keycode, WinKey};
pub use modifiers::{modifier_keys, should_inject_as_text, CommandPolicy, ModifierPolicy};
pub use scroll::ScrollAccumulator;

/// Normalised `[0,1]` -> the absolute coordinate space `SendInput` uses with
/// `MOUSEEVENTF_ABSOLUTE | MOUSEEVENTF_VIRTUALDESK`, which is 0..65535 across
/// the whole virtual desktop.
///
/// The protocol's normalised coordinates map onto this exactly, with no display
/// geometry needed. Input is clamped per PROTOCOL.md §0, so a malformed or NaN
/// coordinate becomes a defined on-screen position rather than an out-of-range
/// value.
pub fn to_absolute(v: f64) -> i32 {
    let clamped = rc_proto::ctrl::clamp_unit(v);
    // 65535, not 65536: the range is inclusive, and rounding rather than
    // truncating is what lets 1.0 reach the last column instead of stopping one
    // short of it.
    (clamped * 65535.0).round() as i32
}
