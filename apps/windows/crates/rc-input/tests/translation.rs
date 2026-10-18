//! Tests for the macOS -> Windows input translation.
//!
//! These assert behaviour that is *wrong* in a specific, nameable way if the
//! translation drifts -- a scroll that stalls, a chord that double-presses
//! Control, an arrow key that lands on the numpad -- rather than merely
//! confirming that the functions return something.

use rc_input::keycodes::{kvk, vk, WinKey};
use rc_input::modifiers::{CommandPolicy, ModifierPolicy};
use rc_input::*;
use rc_proto::ctrl::{GestureName, KeyEvent, KeyModifiers};

/// The macOS keycodes in 0x00..=0x7E that this host deliberately does not map.
/// Anything else in that range must translate; anything added here must be a
///
/// The unassigned codes are 0x34, 0x42, 0x44, 0x46, 0x4D, 0x6C, 0x6E and 0x70.
/// decision, not an oversight.
const INTENTIONALLY_UNMAPPED: &[i32] = &[
    0x34,
    kvk::FUNCTION,
    0x42, 0x44, 0x46, 0x4D,
    kvk::KEYPAD_EQUALS,
    kvk::JIS_YEN,
    kvk::JIS_UNDERSCORE,
    kvk::JIS_KEYPAD_COMMA,
    kvk::JIS_EISU,
    kvk::JIS_KANA,
    0x6C, 0x6E, 0x70,
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

/// The single most confusable pair in the table: macOS labels Backspace "Delete", and its Forward Delete is what Windows calls Delete.
#[test]
fn macos_delete_is_windows_backspace() {
    assert_eq!(map_keycode(kvk::DELETE), Some(WinKey::new(vk::BACK)));
    assert_eq!(map_keycode(kvk::FORWARD_DELETE), Some(WinKey::ext(vk::DELETE)));
}

/// Without `KEYEVENTF_EXTENDEDKEY` the arrow cluster collides with the numpad when Num Lock is off, and Right-Alt behaves as Left-Alt. The ordinary keys must not be extended, or they become the wrong key.
#[test]
fn navigation_and_right_hand_modifiers_are_extended() {
    for k in [
        kvk::LEFT_ARROW, kvk::RIGHT_ARROW, kvk::UP_ARROW, kvk::DOWN_ARROW,
        kvk::HOME, kvk::END, kvk::PAGE_UP, kvk::PAGE_DOWN, kvk::FORWARD_DELETE,
        kvk::RIGHT_CONTROL, kvk::RIGHT_OPTION, kvk::KEYPAD_DIVIDE, kvk::KEYPAD_ENTER,
    ] {
        let m = map_keycode(k).unwrap_or_else(|| panic!("0x{k:02X} unmapped"));
        assert!(m.extended, "0x{k:02X} -> VK 0x{:02X} must be extended", m.vk);
    }
    for k in [kvk::A, kvk::RETURN, kvk::SPACE, kvk::TAB, kvk::KEYPAD0, kvk::F1] {
        assert!(!map_keycode(k).unwrap().extended, "0x{k:02X} must not be extended");
    }
}

/// The macOS digit row is not in numeric order: 6 sits at 0x16, before 5. A table built by counting upward instead of by name gets these two wrong.
#[test]
fn letters_and_digits_land_on_their_ascii_virtual_keys() {
    assert_eq!(map_keycode(kvk::A).unwrap().vk, u16::from(b'A'));
    assert_eq!(map_keycode(kvk::Z).unwrap().vk, u16::from(b'Z'));
    assert_eq!(map_keycode(kvk::N0).unwrap().vk, u16::from(b'0'));
    assert_eq!(map_keycode(kvk::N9).unwrap().vk, u16::from(b'9'));
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

fn keys(mods: KeyModifiers) -> Vec<WinKey> {
    modifier_keys(mods, ModifierPolicy::default())
}

#[test]
fn command_becomes_control_so_that_cmd_c_copies() {
    assert_eq!(keys(KeyModifiers::COMMAND), vec![WinKey::new(vk::LCONTROL)]);
}

/// Emitting Control twice would leave a stuck key: the chord is pressed in order and released in reverse, so a duplicate press is released once.
#[test]
fn command_plus_control_collapses_to_a_single_control() {
    let k = keys(KeyModifiers::COMMAND | KeyModifiers::CONTROL);
    assert_eq!(k, vec![WinKey::new(vk::LCONTROL)], "got {k:?}");
}

/// macOS reports Caps Lock as a state; Windows treats `VK_CAPITAL` as a toggle. Pressing it would flip the host's caps state on every keystroke.
#[test]
fn caps_lock_is_never_pressed() {
    let k = keys(KeyModifiers::CAPS_LOCK | KeyModifiers::SHIFT);
    assert_eq!(k, vec![WinKey::new(vk::LSHIFT)]);
}

#[test]
fn the_fn_bit_is_dropped() {
    assert!(keys(KeyModifiers::FUNCTION).is_empty());
}

/// A peer on a newer protocol must not be able to make this host press a key it does not understand.
#[test]
fn undefined_modifier_bits_from_a_future_peer_are_masked_off() {
    assert!(keys(KeyModifiers(1 << 20)).is_empty());
    assert_eq!(keys(KeyModifiers(KeyModifiers::SHIFT.0 | (1 << 20))),
               vec![WinKey::new(vk::LSHIFT)]);
}

#[test]
fn command_as_windows_policy_presses_the_win_key_instead() {
    let policy = ModifierPolicy { command: CommandPolicy::AsWindows };
    assert_eq!(modifier_keys(KeyModifiers::COMMAND, policy), vec![WinKey::ext(vk::LWIN)]);
}

/// Any chord modifier means this is a shortcut, not typing. Injecting "c" instead of Ctrl+C is the bug this guard exists to prevent.
#[test]
fn text_injection_is_preferred_only_when_it_cannot_break_a_shortcut() {
    assert!(should_inject_as_text("a", KeyModifiers::default()));
    assert!(should_inject_as_text("A", KeyModifiers::SHIFT));
    assert!(should_inject_as_text("é", KeyModifiers::default()));
    assert!(should_inject_as_text("中", KeyModifiers::default()));

    assert!(!should_inject_as_text("c", KeyModifiers::COMMAND));
    assert!(!should_inject_as_text("c", KeyModifiers::CONTROL));
    assert!(!should_inject_as_text("c", KeyModifiers::OPTION));

    assert!(!should_inject_as_text("\r", KeyModifiers::default()));
    assert!(!should_inject_as_text("\t", KeyModifiers::default()));
    assert!(!should_inject_as_text("\u{1b}", KeyModifiers::default()));
    assert!(!should_inject_as_text("", KeyModifiers::default()));
}

/// PROTOCOL.md §5: `dy` has the AppKit sign, positive = content moves down, which is the Windows wheel sign too. The Mac host passes it through unchanged; a flip here is invisible in review and instantly obvious to a user, and was.
#[test]
fn scroll_direction_is_the_wire_direction() {
    let mut acc = ScrollAccumulator::default();
    assert!(acc.push(120.0).unwrap() > 0, "positive wire dy must give a positive wheel delta");
    let mut acc = ScrollAccumulator::default();
    assert!(acc.push(-120.0).unwrap() < 0);
}

#[test]
fn one_notch_of_pixels_is_one_wheel_delta() {
    let mut acc = ScrollAccumulator::default();
    assert_eq!(acc.push(120.0), Some(120));
}

/// The real failure this prevents: 60 events of half a pixel each, every one of which truncates to zero, so a slow trackpad drag scrolls nothing at all.
#[test]
fn slow_scrolling_accumulates_instead_of_rounding_away_to_nothing() {
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

/// Property: emitted units plus the banked remainder always equals the exact conversion of everything pushed. Any leak shows up as drift.
#[test]
fn no_scroll_travel_is_lost_across_many_events() {
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
    assert_eq!(acc.push(-60.0), Some(60));
}

/// Uses a fractional pixel delta, since whole pixels bank nothing at the default 1:1 pixels-per-unit ratio.
#[test]
fn reset_drops_the_banked_fraction() {
    let mut acc = ScrollAccumulator::default();
    acc.push(-119.5);
    assert!(acc.banked() > 0.0, "expected a banked fraction, got {}", acc.banked());
    acc.reset();
    assert_eq!(acc.banked(), 0.0);
}

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

/// Mission Control and App Exposé deliberately collide, because Windows has no per-application exposé. Any other collision is a copy-paste error.
#[test]
fn only_the_documented_gesture_pair_shares_a_chord() {
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

fn one_screen() -> DisplayGeometry {
    DisplayGeometry::single(1920, 1080, 1.0)
}

#[test]
fn normalised_coordinates_span_the_full_absolute_range() {
    let g = one_screen();
    assert_eq!(g.to_absolute(0.0, 0.0), (0, 0));
    assert_eq!(
        g.to_absolute(1.0, 1.0),
        (ABSOLUTE_MAX, ABSOLUTE_MAX),
        "1.0 must reach the last column, not stop short"
    );
}

#[test]
fn coordinates_are_clamped_and_nan_safe() {
    let g = one_screen();
    assert_eq!(g.to_absolute(-5.0, 5.0), (0, ABSOLUTE_MAX));
    assert_eq!(g.to_absolute(f64::NAN, f64::NAN), (0, 0));
    assert_eq!(g.to_absolute(f64::INFINITY, f64::NEG_INFINITY), (ABSOLUTE_MAX, 0));
}

/// The defect this exists to prevent: treating the captured monitor as if it
/// were the whole virtual desktop. With a second screen attached to the left,
/// `VIRTUALDESK` coordinate 0 is on *that* screen, so a click at the left edge
/// of the remote window landed on the wrong monitor entirely.
#[test]
fn a_second_monitor_to_the_left_shifts_the_absolute_origin() {
    let g = DisplayGeometry {
        monitor: Rect::new(0, 0, 1920, 1080),
        virtual_desktop: Rect::new(-1920, 0, 1920, 1080),
        scale: 1.0,
    };
    assert!(g.is_usable());
    let (left, _) = g.to_absolute(0.0, 0.0);
    let (right, _) = g.to_absolute(1.0, 0.0);
    assert!(
        left > ABSOLUTE_MAX / 2 - 100 && left < ABSOLUTE_MAX / 2 + 100,
        "the captured screen's left edge is halfway across a doubled desktop, got {left}"
    );
    assert_eq!(right, ABSOLUTE_MAX, "its right edge is the desktop's right edge");
}

#[test]
fn a_captured_monitor_at_a_negative_origin_still_maps_into_range() {
    let g = DisplayGeometry {
        monitor: Rect::new(-2560, -400, 0, 1040),
        virtual_desktop: Rect::new(-2560, -400, 1920, 1080),
        scale: 1.0,
    };
    assert!(g.is_usable());
    for (u, v) in [(0.0, 0.0), (0.5, 0.5), (1.0, 1.0)] {
        let (x, y) = g.to_absolute(u, v);
        assert!((0..=ABSOLUTE_MAX).contains(&x), "x out of range: {x}");
        assert!((0..=ABSOLUTE_MAX).contains(&y), "y out of range: {y}");
    }
    assert_eq!(g.to_absolute(0.0, 0.0), (0, 0), "the top-left of the desktop is the origin");
}

#[test]
fn geometry_read_mid_change_is_rejected_rather_than_aimed_with() {
    let detached = DisplayGeometry {
        monitor: Rect::new(2000, 0, 3920, 1080),
        virtual_desktop: Rect::new(0, 0, 1920, 1080),
        scale: 1.0,
    };
    assert!(!detached.is_usable(), "a monitor outside the virtual desktop is not aimable");
    assert!(!DisplayGeometry::single(0, 0, 1.0).is_usable(), "an empty display is not aimable");
}

#[test]
fn display_info_reports_the_captured_monitor_and_names_windows() {
    let g = DisplayGeometry {
        monitor: Rect::new(-1920, 0, 0, 1200),
        virtual_desktop: Rect::new(-1920, 0, 2560, 1440),
        scale: 1.5,
    };
    let info = g.display_info();
    assert_eq!((info.w, info.h), (1920, 1200), "the captured monitor, not the desktop");
    assert_eq!(info.scale, 1.5);
    assert_eq!(info.os, "windows");
}

fn resolve(keycode: i32, mods: KeyModifiers, chars: &str) -> KeyResolution {
    KeyPolicy::default().resolve(&KeyEvent { keycode, mods: mods.0, chars: chars.into() })
}

/// The five shortcuts whose breaking makes the product feel broken. Named as a
/// set so the policy cannot be changed without this failing.
#[test]
fn the_five_command_shortcuts_become_their_ctrl_equivalents() {
    for (keycode, letter) in
        [(kvk::C, b'C'), (kvk::V, b'V'), (kvk::X, b'X'), (kvk::A, b'A'), (kvk::Z, b'Z')]
    {
        let got = resolve(keycode, KeyModifiers::COMMAND, "");
        assert_eq!(
            got,
            KeyResolution::Keystroke {
                modifiers: vec![WinKey::new(vk::LCONTROL)],
                key: Some(WinKey::new(vk::letter(letter))),
            },
            "Command+{} must be Ctrl+{}",
            letter as char,
            letter as char
        );
    }
}

#[test]
fn control_is_ctrl_and_option_is_alt_and_the_pair_does_not_merge() {
    let got = resolve(kvk::T, KeyModifiers::CONTROL | KeyModifiers::OPTION, "");
    assert_eq!(
        got,
        KeyResolution::Keystroke {
            modifiers: vec![WinKey::new(vk::LCONTROL), WinKey::new(vk::LMENU)],
            key: Some(WinKey::new(vk::letter(b'T'))),
        }
    );
}

#[test]
fn overlapping_command_and_control_resolve_to_one_ctrl() {
    let KeyResolution::Keystroke { modifiers, .. } =
        resolve(kvk::S, KeyModifiers::COMMAND | KeyModifiers::CONTROL, "")
    else {
        panic!("a chord must not be text");
    };
    assert_eq!(
        modifiers,
        vec![WinKey::new(vk::LCONTROL)],
        "two Mac modifiers mapping to Ctrl must press it once; twice leaves it stuck"
    );
}

#[test]
fn the_backspace_and_delete_keys_do_not_swap() {
    assert_eq!(
        resolve(kvk::DELETE, KeyModifiers(0), ""),
        KeyResolution::Keystroke { modifiers: vec![], key: Some(WinKey::new(vk::BACK)) },
        "the Mac's Delete key is Windows Backspace"
    );
    assert_eq!(
        resolve(kvk::FORWARD_DELETE, KeyModifiers(0), ""),
        KeyResolution::Keystroke { modifiers: vec![], key: Some(WinKey::ext(vk::DELETE)) },
        "the Mac's Forward Delete is the extended Windows Delete"
    );
}

#[test]
fn navigation_keys_resolve_extended_so_they_do_not_land_on_the_numpad() {
    for (mac, win) in [
        (kvk::LEFT_ARROW, vk::LEFT),
        (kvk::RIGHT_ARROW, vk::RIGHT),
        (kvk::UP_ARROW, vk::UP),
        (kvk::DOWN_ARROW, vk::DOWN),
        (kvk::HOME, vk::HOME),
        (kvk::END, vk::END),
        (kvk::PAGE_UP, vk::PRIOR),
        (kvk::PAGE_DOWN, vk::NEXT),
    ] {
        assert_eq!(
            resolve(mac, KeyModifiers(0), ""),
            KeyResolution::Keystroke { modifiers: vec![], key: Some(WinKey::ext(win)) },
            "mac keycode {mac:#x} must be the extended form of {win:#x}"
        );
    }
}

/// The controller sends `flagsChanged` as a `key_down`/`key_up` of the modifier
/// keycode itself, so a held modifier arrives as its own event and must resolve
/// to that one key, not to a chord derived from the bitmask.
#[test]
fn a_modifier_keycode_resolves_to_that_one_sided_modifier() {
    for (mac, expected) in [
        (kvk::COMMAND, WinKey::new(vk::LCONTROL)),
        (kvk::RIGHT_COMMAND, WinKey::new(vk::LCONTROL)),
        (kvk::CONTROL, WinKey::new(vk::LCONTROL)),
        (kvk::RIGHT_CONTROL, WinKey::ext(vk::RCONTROL)),
        (kvk::OPTION, WinKey::new(vk::LMENU)),
        (kvk::RIGHT_OPTION, WinKey::ext(vk::RMENU)),
        (kvk::SHIFT, WinKey::new(vk::LSHIFT)),
        (kvk::RIGHT_SHIFT, WinKey::new(vk::RSHIFT)),
    ] {
        assert_eq!(
            resolve(mac, KeyModifiers::COMMAND, ""),
            KeyResolution::Keystroke { modifiers: vec![], key: Some(expected) },
            "mac modifier keycode {mac:#x}"
        );
    }
}

#[test]
fn caps_lock_and_fn_are_ignored_rather_than_pressed() {
    assert_eq!(resolve(kvk::CAPS_LOCK, KeyModifiers(0), ""), KeyResolution::Ignored);
    assert_eq!(resolve(kvk::FUNCTION, KeyModifiers(0), ""), KeyResolution::Ignored);
}

#[test]
fn resolved_text_is_preferred_only_when_no_shortcut_modifier_is_held() {
    assert_eq!(resolve(kvk::E, KeyModifiers(0), "é"), KeyResolution::Text("é".into()));
    assert_eq!(resolve(kvk::E, KeyModifiers::SHIFT, "É"), KeyResolution::Text("É".into()));
    assert!(
        matches!(resolve(kvk::E, KeyModifiers::COMMAND, "e"), KeyResolution::Keystroke { .. }),
        "Command+E must stay a chord even when the controller resolved a character"
    );
}

/// The shipped Mac controller never populates `chars`, so every keystroke takes
/// the physical-key path. That path must therefore be complete on its own.
#[test]
fn a_key_event_without_chars_still_resolves_through_the_physical_table() {
    assert_eq!(
        resolve(kvk::K, KeyModifiers(0), ""),
        KeyResolution::Keystroke { modifiers: vec![], key: Some(WinKey::new(vk::letter(b'K'))) }
    );
}

#[test]
fn an_unmapped_keycode_keeps_its_modifiers_instead_of_releasing_them() {
    let got = resolve(kvk::JIS_KANA, KeyModifiers::COMMAND, "");
    assert_eq!(
        got,
        KeyResolution::Keystroke { modifiers: vec![WinKey::new(vk::LCONTROL)], key: None },
        "an unknown key must not look like Command being let go"
    );
    assert_eq!(resolve(kvk::JIS_KANA, KeyModifiers(0), ""), KeyResolution::Ignored);
}

#[test]
fn only_the_modifiers_the_policy_holds_count_as_modifier_keys() {
    for vk_code in [vk::LSHIFT, vk::RSHIFT, vk::LCONTROL, vk::RCONTROL, vk::LMENU, vk::RMENU, vk::LWIN]
    {
        assert!(KeyPolicy::is_modifier_vk(vk_code), "{vk_code:#x} is a modifier");
    }
    for vk_code in [vk::letter(b'A'), vk::RETURN, vk::CAPITAL, vk::ESCAPE, vk::TAB] {
        assert!(!KeyPolicy::is_modifier_vk(vk_code), "{vk_code:#x} is not a modifier");
    }
}
