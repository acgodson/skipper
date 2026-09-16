//! Tests for the macOS -> Windows input translation.
//!
//! These assert behaviour that is *wrong* in a specific, nameable way if the
//! translation drifts -- a scroll that stalls, a chord that double-presses
//! Control, an arrow key that lands on the numpad -- rather than merely
//! confirming that the functions return something.

use rc_input::keycodes::{kvk, vk, WinKey};
use rc_input::modifiers::{CommandPolicy, ModifierPolicy};
use rc_input::*;
use rc_proto::ctrl::{GestureName, KeyModifiers};

// ---------------------------------------------------------------------------
// Keycodes
// ---------------------------------------------------------------------------

/// The macOS keycodes in 0x00..=0x7E that this host deliberately does not map.
/// Anything else in that range must translate; anything added here must be a
/// decision, not an oversight.
const INTENTIONALLY_UNMAPPED: &[i32] = &[
    0x34, // unassigned
    kvk::FUNCTION,
    0x42, 0x44, 0x46, 0x4D, // unassigned
    kvk::KEYPAD_EQUALS,
    kvk::JIS_YEN,
    kvk::JIS_UNDERSCORE,
    kvk::JIS_KEYPAD_COMMA,
    kvk::JIS_EISU,
    kvk::JIS_KANA,
    0x6C, 0x6E, 0x70, // unassigned
];

#[test]
fn every_assigned_mac_keycode_translates() {
    let mut missing = Vec::new();
    for mac in 0x00..=0x7E {
        let mapped = map_keycode(mac).is_some();
        let expected = !INTENTIONALLY_UNMAPPED.contains(&mac);
        if expected && !mapped {
            missing.push(format!("0x{mac:02X} should map but does not"));
        }
        if !expected && mapped {
            missing.push(format!(
                "0x{mac:02X} is listed as intentionally unmapped but now maps"
            ));
        }
    }
    assert!(missing.is_empty(), "keycode table drift:\n  {}", missing.join("\n  "));
}

#[test]
fn out_of_range_keycodes_are_dropped_not_panicked() {
    for mac in [-1, 0x7F, 0x100, i32::MAX, i32::MIN] {
        assert_eq!(map_keycode(mac), None, "keycode {mac} should be dropped");
    }
}

#[test]
fn macos_delete_is_windows_backspace() {
    // The single most confusable pair in the table: macOS labels Backspace
    // "Delete", and its Forward Delete is what Windows calls Delete.
    assert_eq!(map_keycode(kvk::DELETE), Some(WinKey::new(vk::BACK)));
    assert_eq!(map_keycode(kvk::FORWARD_DELETE), Some(WinKey::ext(vk::DELETE)));
}

#[test]
fn navigation_and_right_hand_modifiers_are_extended() {
    // Without KEYEVENTF_EXTENDEDKEY the arrow cluster collides with the numpad
    // when Num Lock is off, and Right-Alt behaves as Left-Alt.
    for k in [
        kvk::LEFT_ARROW, kvk::RIGHT_ARROW, kvk::UP_ARROW, kvk::DOWN_ARROW,
        kvk::HOME, kvk::END, kvk::PAGE_UP, kvk::PAGE_DOWN, kvk::FORWARD_DELETE,
        kvk::RIGHT_CONTROL, kvk::RIGHT_OPTION, kvk::KEYPAD_DIVIDE, kvk::KEYPAD_ENTER,
    ] {
        let m = map_keycode(k).unwrap_or_else(|| panic!("0x{k:02X} unmapped"));
        assert!(m.extended, "0x{k:02X} -> VK 0x{:02X} must be extended", m.vk);
    }
    // ...and the ordinary keys must NOT be, or they become the wrong key.
    for k in [kvk::A, kvk::RETURN, kvk::SPACE, kvk::TAB, kvk::KEYPAD0, kvk::F1] {
        assert!(!map_keycode(k).unwrap().extended, "0x{k:02X} must not be extended");
    }
}

#[test]
fn letters_and_digits_land_on_their_ascii_virtual_keys() {
    assert_eq!(map_keycode(kvk::A).unwrap().vk, u16::from(b'A'));
    assert_eq!(map_keycode(kvk::Z).unwrap().vk, u16::from(b'Z'));
    assert_eq!(map_keycode(kvk::N0).unwrap().vk, u16::from(b'0'));
    assert_eq!(map_keycode(kvk::N9).unwrap().vk, u16::from(b'9'));
    // The macOS digit row is not in numeric order -- 6 sits at 0x16, before 5.
    // A table built by counting upward instead of by name gets these two wrong.
    assert_eq!(map_keycode(0x16).unwrap().vk, u16::from(b'6'));
    assert_eq!(map_keycode(0x17).unwrap().vk, u16::from(b'5'));
}

#[test]
fn keypad_digits_are_distinct_from_the_digit_row() {
    for d in 0..=9u8 {
        let row = map_keycode(match d {
            0 => kvk::N0, 1 => kvk::N1, 2 => kvk::N2, 3 => kvk::N3, 4 => kvk::N4,
            5 => kvk::N5, 6 => kvk::N6, 7 => kvk::N7, 8 => kvk::N8, _ => kvk::N9,
        })
        .unwrap();
        let pad = map_keycode(kvk::KEYPAD0 + i32::from(d) - if d == 0 { 0 } else { 0 });
        let pad = match d {
            0 => map_keycode(kvk::KEYPAD0), 1 => map_keycode(kvk::KEYPAD1),
            2 => map_keycode(kvk::KEYPAD2), 3 => map_keycode(kvk::KEYPAD3),
            4 => map_keycode(kvk::KEYPAD4), 5 => map_keycode(kvk::KEYPAD5),
            6 => map_keycode(kvk::KEYPAD6), 7 => map_keycode(kvk::KEYPAD7),
            8 => map_keycode(kvk::KEYPAD8), _ => map_keycode(kvk::KEYPAD9),
        }
        .unwrap_or(pad.unwrap());
        assert_ne!(row.vk, pad.vk, "digit {d} row and keypad must differ");
    }
}

// ---------------------------------------------------------------------------
// Modifiers
// ---------------------------------------------------------------------------

fn keys(mods: KeyModifiers) -> Vec<WinKey> {
    modifier_keys(mods, ModifierPolicy::default())
}

#[test]
fn command_becomes_control_so_that_cmd_c_copies() {
    assert_eq!(keys(KeyModifiers::COMMAND), vec![WinKey::new(vk::LCONTROL)]);
}

#[test]
fn command_plus_control_collapses_to_a_single_control() {
    // Emitting Control twice would leave a stuck key: the chord is pressed in
    // order and released in reverse, so a duplicate press is released once.
    let k = keys(KeyModifiers::COMMAND | KeyModifiers::CONTROL);
    assert_eq!(k, vec![WinKey::new(vk::LCONTROL)], "got {k:?}");
}

#[test]
fn caps_lock_is_never_pressed() {
    // macOS reports Caps Lock as a state; Windows treats VK_CAPITAL as a toggle.
    // Pressing it would flip the host's caps state on every keystroke.
    let k = keys(KeyModifiers::CAPS_LOCK | KeyModifiers::SHIFT);
    assert_eq!(k, vec![WinKey::new(vk::LSHIFT)]);
}

#[test]
fn the_fn_bit_is_dropped() {
    assert!(keys(KeyModifiers::FUNCTION).is_empty());
}

#[test]
fn undefined_modifier_bits_from_a_future_peer_are_masked_off() {
    // A peer on a newer protocol must not be able to make this host press a key
    // it does not understand.
    assert!(keys(KeyModifiers(1 << 20)).is_empty());
    assert_eq!(keys(KeyModifiers(KeyModifiers::SHIFT.0 | (1 << 20))),
               vec![WinKey::new(vk::LSHIFT)]);
}

#[test]
fn command_as_windows_policy_presses_the_win_key_instead() {
    let policy = ModifierPolicy { command: CommandPolicy::AsWindows };
    assert_eq!(modifier_keys(KeyModifiers::COMMAND, policy), vec![WinKey::ext(vk::LWIN)]);
}

#[test]
fn text_injection_is_preferred_only_when_it_cannot_break_a_shortcut() {
    // Plain and shifted text: inject the character the controller resolved.
    assert!(should_inject_as_text("a", KeyModifiers::default()));
    assert!(should_inject_as_text("A", KeyModifiers::SHIFT));
    assert!(should_inject_as_text("é", KeyModifiers::default()));
    assert!(should_inject_as_text("中", KeyModifiers::default()));

    // Any chord modifier means this is a shortcut, not typing. Injecting "c"
    // here instead of Ctrl+C is the bug this guard exists to prevent.
    assert!(!should_inject_as_text("c", KeyModifiers::COMMAND));
    assert!(!should_inject_as_text("c", KeyModifiers::CONTROL));
    assert!(!should_inject_as_text("c", KeyModifiers::OPTION));

    // Control characters must arrive as real keystrokes.
    assert!(!should_inject_as_text("\r", KeyModifiers::default()));
    assert!(!should_inject_as_text("\t", KeyModifiers::default()));
    assert!(!should_inject_as_text("\u{1b}", KeyModifiers::default()));
    assert!(!should_inject_as_text("", KeyModifiers::default()));
}

// ---------------------------------------------------------------------------
// Scroll
// ---------------------------------------------------------------------------

#[test]
fn scroll_direction_is_inverted_relative_to_the_protocol() {
    // PROTOCOL.md §5: positive dy = content moves up. A positive Windows wheel
    // delta moves content down. Getting this backwards is invisible in code
    // review and instantly obvious to a user.
    let mut acc = ScrollAccumulator::default();
    assert!(acc.push(120.0).unwrap() < 0, "positive protocol dy must give a negative wheel delta");
    let mut acc = ScrollAccumulator::default();
    assert!(acc.push(-120.0).unwrap() > 0);
}

#[test]
fn one_notch_of_pixels_is_one_wheel_delta() {
    let mut acc = ScrollAccumulator::default();
    assert_eq!(acc.push(-120.0), Some(120));
}

#[test]
fn slow_scrolling_accumulates_instead_of_rounding_away_to_nothing() {
    // The real failure this prevents: 60 events of half a pixel each, every one
    // of which truncates to zero, so a slow trackpad drag scrolls nothing at all.
    let mut acc = ScrollAccumulator::default();
    let mut emitted = 0i64;
    let mut any = false;
    for _ in 0..60 {
        if let Some(d) = acc.push(-0.5) {
            emitted += i64::from(d);
            any = true;
        }
    }
    assert!(any, "60 sub-pixel events produced no scrolling at all");
    assert_eq!(emitted, 30, "30 pixels of travel should yield 30 wheel units");
}

#[test]
fn no_scroll_travel_is_lost_across_many_events() {
    // Property: emitted units plus the banked remainder always equals the exact
    // conversion of everything pushed. Any leak shows up as drift.
    let mut acc = ScrollAccumulator::default();
    let mut total_in = 0.0;
    let mut total_out = 0i64;
    for i in 1..=500 {
        let px = ((i % 17) as f64 - 8.0) * 0.37;
        total_in += px;
        if let Some(d) = acc.push(px) {
            total_out += i64::from(d);
        }
    }
    let exact = -total_in;
    let accounted = total_out as f64 + acc.banked();
    assert!(
        (exact - accounted).abs() < 1e-6,
        "scroll travel leaked: exact {exact}, accounted {accounted}"
    );
}

#[test]
fn a_malformed_peer_cannot_poison_the_scroll_bank() {
    let mut acc = ScrollAccumulator::default();
    acc.push(-60.0);
    let banked = acc.banked();
    assert_eq!(acc.push(f64::NAN), None);
    assert_eq!(acc.push(f64::INFINITY), None);
    assert_eq!(acc.banked(), banked, "bank must survive a NaN unchanged");
    // ...and still work afterwards. 60 pixels is 60 units at the default 1:1
    // ratio; the earlier push already emitted its own 60.
    assert_eq!(acc.push(-60.0), Some(60));
}

#[test]
fn reset_drops_the_banked_fraction() {
    let mut acc = ScrollAccumulator::default();
    // A fractional pixel delta, since whole pixels bank nothing at the default
    // 1:1 pixels-per-unit ratio.
    acc.push(-119.5);
    assert!(acc.banked() > 0.0, "expected a banked fraction, got {}", acc.banked());
    acc.reset();
    assert_eq!(acc.banked(), 0.0);
}

// ---------------------------------------------------------------------------
// Gestures
// ---------------------------------------------------------------------------

#[test]
fn every_gesture_resolves_to_a_real_chord() {
    for g in GestureName::ALL {
        let c = chord_for(g);
        assert!(!c.keys.is_empty(), "{:?} has an empty chord", g.as_wire());
        assert!(!c.label.is_empty(), "{:?} has no label", g.as_wire());
    }
}

#[test]
fn gestures_map_to_the_documented_windows_shortcuts() {
    let win = vk::LWIN;
    assert_eq!(chord_for(GestureName::LockScreen).keys,
               &[WinKey::ext(win), WinKey::new(vk::letter(b'L'))]);
    assert_eq!(chord_for(GestureName::ShowDesktop).keys,
               &[WinKey::ext(win), WinKey::new(vk::letter(b'D'))]);
    assert_eq!(chord_for(GestureName::Spotlight).keys,
               &[WinKey::ext(win), WinKey::new(vk::letter(b'S'))]);
    assert_eq!(chord_for(GestureName::ForceQuit).keys,
               &[WinKey::new(vk::LCONTROL), WinKey::new(vk::LSHIFT), WinKey::new(vk::ESCAPE)]);
    assert_eq!(chord_for(GestureName::AppSwitcher).keys,
               &[WinKey::new(vk::LMENU), WinKey::new(vk::TAB)]);
    assert_eq!(chord_for(GestureName::Launchpad).keys, &[WinKey::ext(win)]);
}

#[test]
fn only_the_documented_gesture_pair_shares_a_chord() {
    // Mission Control and App Exposé deliberately collide -- Windows has no
    // per-application exposé. Any *other* collision is a copy-paste error.
    let mut seen: Vec<(&str, Vec<WinKey>)> = Vec::new();
    for g in GestureName::ALL {
        let keys = chord_for(g).keys.to_vec();
        if let Some((other, _)) = seen.iter().find(|(_, k)| *k == keys) {
            let pair = {
                let mut p = [*other, g.as_wire()];
                p.sort();
                p
            };
            assert_eq!(pair, ["app_expose", "mission_control"],
                       "undocumented chord collision between {other} and {}", g.as_wire());
        }
        seen.push((g.as_wire(), keys));
    }
}

// ---------------------------------------------------------------------------
// Coordinates
// ---------------------------------------------------------------------------

#[test]
fn normalised_coordinates_span_the_full_absolute_range() {
    assert_eq!(to_absolute(0.0), 0);
    assert_eq!(to_absolute(1.0), 65535, "1.0 must reach the last column, not stop short");
    assert_eq!(to_absolute(0.5), 32768);
}

#[test]
fn coordinates_are_clamped_and_nan_safe() {
    assert_eq!(to_absolute(-5.0), 0);
    assert_eq!(to_absolute(5.0), 65535);
    assert_eq!(to_absolute(f64::NAN), 0);
    assert_eq!(to_absolute(f64::INFINITY), 65535);
    assert_eq!(to_absolute(f64::NEG_INFINITY), 0);
}
