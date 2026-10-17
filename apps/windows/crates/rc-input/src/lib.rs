//! Translation from the protocol's macOS input semantics to Windows semantics.
//!
//! Deliberately free of any OS call and any `windows` crate dependency, so the
//! whole of it compiles and its tests run on macOS and Linux. The parts that
//! actually touch the machine live in `rc-host`; everything that could be
//! *wrong* lives here, where it can be asserted on.

#![forbid(unsafe_code)]

pub mod geometry;
pub mod gestures;
pub mod keycodes;
pub mod modifiers;
pub mod policy;
pub mod scroll;

pub use geometry::{DisplayGeometry, Rect, ABSOLUTE_MAX};
pub use gestures::{chord_for, GestureChord};
pub use keycodes::{map_keycode, WinKey};
pub use modifiers::{modifier_keys, should_inject_as_text, CommandPolicy, ModifierPolicy};
pub use policy::{KeyPolicy, KeyResolution};
pub use scroll::ScrollAccumulator;
