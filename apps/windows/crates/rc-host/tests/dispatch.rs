//! Tests the message->InputOp dispatch: ordering, the seq gate, what is held
//! and when it is let go, the suspend gate, and what happens when the OS
//! refuses an op. These are the rules that decide whether a remote keystroke
//! lands correctly, asserted on the exact op sequence rather than on a screen.

use rc_host::{InputDispatcher, InputOp, InputState, Injector, RecordingInjector};
use rc_input::keycodes::{kvk, vk};
use rc_input::{DisplayGeometry, WinKey};
use rc_proto::ctrl::{
    Click, Gesture, GestureName, KeyEvent, KeyModifiers, MouseEvent, MouseMove, Scroll,
};

const SCREEN: (i32, i32) = (1920, 1080);

/// A dispatcher with a known one-screen geometry, which is the precondition for
/// applying input at all.
fn ready() -> (InputDispatcher, RecordingInjector) {
    let mut d = InputDispatcher::default();
    let mut inj = RecordingInjector::default();
    d.set_geometry(Some(DisplayGeometry::single(SCREEN.0, SCREEN.1, 1.0)), &mut inj);
    assert_eq!(d.state(), InputState::Running);
    inj.ops.clear();
    (d, inj)
}

fn run(f: impl FnOnce(&mut InputDispatcher, &mut RecordingInjector)) -> Vec<InputOp> {
    let (mut d, mut inj) = ready();
    f(&mut d, &mut inj);
    inj.ops
}

fn key(keycode: i32, mods: KeyModifiers) -> KeyEvent {
    KeyEvent { keycode, mods: mods.0, chars: String::new() }
}

fn down(k: WinKey) -> InputOp {
    InputOp::Key { vk: k.vk, extended: k.extended, down: true }
}

fn up(k: WinKey) -> InputOp {
    InputOp::Key { vk: k.vk, extended: k.extended, down: false }
}

const CTRL: WinKey = WinKey { vk: vk::LCONTROL, extended: false };
const SHIFT: WinKey = WinKey { vk: vk::LSHIFT, extended: false };
const C: WinKey = WinKey { vk: b'C' as u16, extended: false };

/// The defect: `key_down` pressed *and released* the whole chord, so Command was
/// never actually held. A chord's release belongs to `key_up`.
#[test]
fn a_chord_key_down_holds_the_modifier_instead_of_releasing_it() {
    let (mut d, mut inj) = ready();
    d.key_down(&key(kvk::C, KeyModifiers::COMMAND), &mut inj);
    assert_eq!(inj.ops, vec![down(CTRL), down(C)]);
    assert_eq!(d.held().0, &[CTRL, C], "both keys are down after key_down");

    inj.ops.clear();
    d.key_up(&key(kvk::C, KeyModifiers::COMMAND), &mut inj);
    assert_eq!(inj.ops, vec![up(C)], "the letter is released, Command is still held");

    inj.ops.clear();
    d.key_up(&key(kvk::COMMAND, KeyModifiers(0)), &mut inj);
    assert_eq!(inj.ops, vec![up(CTRL)]);
    assert!(d.held().0.is_empty(), "nothing is left down");
}

/// Auto-repeat is a stream of key-downs. Re-pressing the modifier on each one
/// is wrong (it is already down) and so is releasing the key between them.
#[test]
fn a_held_key_repeats_without_re_pressing_its_modifier() {
    let (mut d, mut inj) = ready();
    for _ in 0..3 {
        d.key_down(&key(kvk::C, KeyModifiers::COMMAND), &mut inj);
    }
    assert_eq!(inj.ops, vec![down(CTRL), down(C), down(C), down(C)]);
    assert_eq!(d.held().0, &[CTRL, C]);
}

#[test]
fn a_bare_modifier_event_holds_that_modifier_until_its_key_up() {
    let (mut d, mut inj) = ready();
    d.key_down(&key(kvk::SHIFT, KeyModifiers::SHIFT), &mut inj);
    assert_eq!(inj.ops, vec![down(SHIFT)]);
    assert_eq!(d.held().0, &[SHIFT]);
    inj.ops.clear();
    d.key_up(&key(kvk::SHIFT, KeyModifiers(0)), &mut inj);
    assert_eq!(inj.ops, vec![up(SHIFT)]);
}

/// A dropped modifier `key_up` would otherwise leave Ctrl stuck down for the
/// rest of the session. The next keystroke's `mods` says it is not held, and
/// that is enough to let go.
#[test]
fn a_lost_modifier_key_up_is_healed_by_the_next_keystrokes_mods() {
    let (mut d, mut inj) = ready();
    d.key_down(&key(kvk::COMMAND, KeyModifiers::COMMAND), &mut inj);
    inj.ops.clear();
    d.key_down(&key(kvk::T, KeyModifiers(0)), &mut inj);
    assert_eq!(
        inj.ops,
        vec![up(CTRL), down(WinKey { vk: b'T' as u16, extended: false })],
        "Ctrl is released before the unmodified key is pressed"
    );
}

#[test]
fn a_reset_releases_every_held_key_newest_first() {
    let (mut d, mut inj) = ready();
    d.key_down(&key(kvk::SHIFT, KeyModifiers::SHIFT), &mut inj);
    d.key_down(&key(kvk::C, KeyModifiers::SHIFT | KeyModifiers::COMMAND), &mut inj);
    inj.ops.clear();
    d.input_reset(&mut inj);
    assert_eq!(inj.ops, vec![up(C), up(CTRL), up(SHIFT)]);
    assert!(d.held().0.is_empty());
}

/// The defect: the reset released a fixed guessed list of modifiers, so a held
/// *letter* or a held mouse button survived it.
#[test]
fn a_reset_releases_a_held_letter_and_a_held_button_too() {
    let (mut d, mut inj) = ready();
    d.key_down(&key(kvk::A, KeyModifiers(0)), &mut inj);
    d.mouse_down(&MouseEvent { button: 0, x: 0.5, y: 0.5 }, &mut inj);
    inj.ops.clear();
    d.input_reset(&mut inj);
    assert!(inj.ops.contains(&up(WinKey { vk: b'A' as u16, extended: false })));
    assert!(inj.ops.contains(&InputOp::MouseButton { button: 0, down: false }));
    assert_eq!(d.held().1.len(), 0, "no button is left down");
}

#[test]
fn a_reset_with_nothing_held_is_a_no_op_and_stays_idempotent() {
    let (mut d, mut inj) = ready();
    d.input_reset(&mut inj);
    d.input_reset(&mut inj);
    assert!(inj.ops.is_empty(), "releasing nothing must not fabricate key-ups");
}

#[test]
fn clicks_are_aimed_through_the_display_geometry() {
    let mut d = InputDispatcher::default();
    let mut inj = RecordingInjector::default();
    d.set_geometry(
        Some(DisplayGeometry {
            monitor: rc_input::Rect::new(0, 0, 1920, 1080),
            virtual_desktop: rc_input::Rect::new(-1920, 0, 1920, 1080),
            scale: 1.0,
        }),
        &mut inj,
    );
    inj.ops.clear();
    d.mouse_down(&MouseEvent { button: 0, x: 1.0, y: 0.0 }, &mut inj);
    assert_eq!(
        inj.ops.first(),
        Some(&InputOp::MouseMoveAbs { x: rc_input::ABSOLUTE_MAX, y: 0 }),
        "the captured screen's right edge is the virtual desktop's right edge"
    );
}

#[test]
fn a_drag_moves_without_touching_the_button_state() {
    let ops = run(|d, i| {
        d.mouse_drag(&MouseEvent { button: 0, x: 0.5, y: 0.5 }, i);
    });
    assert_eq!(ops.len(), 1);
    assert!(matches!(ops[0], InputOp::MouseMoveAbs { .. }));
    assert!(
        !ops.iter().any(|o| matches!(o, InputOp::MouseButton { .. })),
        "a drag must not press or release a button"
    );
}

#[test]
fn a_full_drag_presses_moves_and_releases_exactly_once() {
    let (mut d, mut inj) = ready();
    d.mouse_down(&MouseEvent { button: 0, x: 0.1, y: 0.1 }, &mut inj);
    for step in 1..=3 {
        d.mouse_drag(&MouseEvent { button: 0, x: 0.1 * step as f64, y: 0.2 }, &mut inj);
    }
    d.mouse_up(&MouseEvent { button: 0, x: 0.4, y: 0.2 }, &mut inj);
    let downs = inj.ops.iter().filter(|o| matches!(o, InputOp::MouseButton { down: true, .. })).count();
    let ups = inj.ops.iter().filter(|o| matches!(o, InputOp::MouseButton { down: false, .. })).count();
    assert_eq!((downs, ups), (1, 1));
    assert!(d.held().1.is_empty(), "the button is not left down after the drag");
}

#[test]
fn left_right_and_middle_buttons_are_tracked_separately() {
    let (mut d, mut inj) = ready();
    for button in 0..=2 {
        d.mouse_down(&MouseEvent { button, x: 0.5, y: 0.5 }, &mut inj);
    }
    assert_eq!(d.held().1, &[0, 1, 2]);
    d.mouse_up(&MouseEvent { button: 1, x: 0.5, y: 0.5 }, &mut inj);
    assert_eq!(d.held().1, &[0, 2], "releasing the right button leaves the others held");
}

#[test]
fn a_double_click_moves_once_then_presses_twice() {
    let ops = run(|d, i| {
        d.click(&Click { button: 0, x: 0.5, y: 0.5, count: 2 }, i);
    });
    let downs = ops.iter().filter(|o| matches!(o, InputOp::MouseButton { down: true, .. })).count();
    assert_eq!(downs, 2);
    assert!(matches!(ops[0], InputOp::MouseMoveAbs { .. }), "position is set before clicking");
    assert_eq!(
        ops.iter().filter(|o| matches!(o, InputOp::MouseMoveAbs { .. })).count(),
        1,
        "a double click must not jitter the pointer between its two presses"
    );
}

#[test]
fn a_click_count_outside_one_to_three_is_clamped() {
    for (count, expected) in [(0, 1), (1, 1), (3, 3), (9, 3), (-4, 1)] {
        let ops = run(|d, i| {
            d.click(&Click { button: 0, x: 0.5, y: 0.5, count }, i);
        });
        let downs =
            ops.iter().filter(|o| matches!(o, InputOp::MouseButton { down: true, .. })).count();
        assert_eq!(downs, expected, "count {count}");
    }
}

#[test]
fn the_hi_channel_sequence_gate_drops_stale_and_duplicate_moves() {
    let (mut d, mut inj) = ready();
    d.mouse_move(&MouseMove { x: 0.1, y: 0.1, seq: 5 }, &mut inj);
    d.mouse_move(&MouseMove { x: 0.9, y: 0.9, seq: 3 }, &mut inj);
    d.mouse_move(&MouseMove { x: 0.2, y: 0.2, seq: 5 }, &mut inj);
    d.mouse_move(&MouseMove { x: 0.3, y: 0.3, seq: 6 }, &mut inj);
    let moves = inj.ops.iter().filter(|o| matches!(o, InputOp::MouseMoveAbs { .. })).count();
    assert_eq!(moves, 2, "only seq 5 and 6 should move the pointer");
}

/// After a reconnect the controller's seq counter may restart; a reset must stop the gate from swallowing every post-reconnect move.
#[test]
fn input_reset_reopens_the_sequence_gate() {
    let (mut d, mut inj) = ready();
    d.mouse_move(&MouseMove { x: 0.5, y: 0.5, seq: 1000 }, &mut inj);
    d.input_reset(&mut inj);
    inj.ops.clear();
    d.mouse_move(&MouseMove { x: 0.6, y: 0.6, seq: 1 }, &mut inj);
    assert_eq!(
        inj.ops.iter().filter(|o| matches!(o, InputOp::MouseMoveAbs { .. })).count(),
        1,
        "a low seq after reset must still move"
    );
}

#[test]
fn an_unknown_mouse_button_is_ignored_not_injected() {
    let ops = run(|d, i| {
        d.mouse_down(&MouseEvent { button: 99, x: 0.5, y: 0.5 }, i);
    });
    assert!(ops.is_empty(), "an out-of-range button must produce nothing");
}

#[test]
fn plain_typing_goes_through_unicode_not_the_keycode_table() {
    let ops = run(|d, i| {
        d.key_down(&KeyEvent { keycode: 0, mods: 0, chars: "é".into() }, i);
    });
    assert_eq!(ops, vec![InputOp::UnicodeChar('é')]);
}

#[test]
fn a_supplementary_plane_char_still_arrives_as_one_unicode_char_op() {
    let ops = run(|d, i| {
        d.key_down(&KeyEvent { keycode: 0, mods: 0, chars: "😀".into() }, i);
    });
    assert_eq!(ops, vec![InputOp::UnicodeChar('😀')]);
}

#[test]
fn injected_text_holds_nothing_down_afterwards() {
    let (mut d, mut inj) = ready();
    d.key_down(&KeyEvent { keycode: kvk::E, mods: 0, chars: "ß".into() }, &mut inj);
    d.key_up(&key(kvk::E, KeyModifiers(0)), &mut inj);
    assert!(d.held().0.is_empty(), "a typed character is not a held key");
}

#[test]
fn slow_scroll_accumulates_across_dispatch_calls() {
    let (mut d, mut inj) = ready();
    for _ in 0..60 {
        d.scroll(&Scroll { dx: 0.0, dy: -0.5, phase: "changed".into() }, &mut inj);
    }
    let wheels: i32 = inj
        .ops
        .iter()
        .filter_map(|o| match o {
            InputOp::MouseWheel { delta, horizontal: false } => Some(*delta),
            _ => None,
        })
        .sum();
    assert_eq!(wheels, -30, "60 half-pixel events must integrate to 30 wheel units, sign kept");
}

#[test]
fn horizontal_and_vertical_wheel_deltas_go_to_their_own_axis() {
    let ops = run(|d, i| {
        d.scroll(&Scroll { dx: -240.0, dy: 120.0, phase: "changed".into() }, i);
    });
    assert!(ops.contains(&InputOp::MouseWheel { delta: 120, horizontal: false }));
    assert!(ops.contains(&InputOp::MouseWheel { delta: -240, horizontal: true }));
}

#[test]
fn a_gesture_emits_its_windows_chord_pressed_then_released_in_reverse() {
    let ops = run(|d, i| {
        d.gesture(GestureName::LockScreen, i);
    });
    assert_eq!(
        ops,
        vec![
            InputOp::Key { vk: vk::LWIN, extended: true, down: true },
            InputOp::Key { vk: u16::from(b'L'), extended: false, down: true },
            InputOp::Key { vk: u16::from(b'L'), extended: false, down: false },
            InputOp::Key { vk: vk::LWIN, extended: true, down: false },
        ]
    );
}

#[test]
fn a_gesture_leaves_nothing_held() {
    let (mut d, mut inj) = ready();
    for g in GestureName::ALL {
        d.gesture(g, &mut inj);
        assert!(d.held().0.is_empty(), "{:?} left a key down", g.as_wire());
    }
}

#[test]
fn every_gesture_from_the_wire_dispatches_to_a_chord() {
    for g in GestureName::ALL {
        let ops = run(|d, i| {
            let wire = Gesture { name: g.as_wire().into() };
            let name = GestureName::from_wire(&wire.name).unwrap();
            d.gesture(name, i);
        });
        assert!(!ops.is_empty(), "{:?} produced no ops", g.as_wire());
    }
}

/// The defect this closes: a dispatcher with no geometry still aimed clicks,
/// and a host whose capture had failed still injected them.
#[test]
fn nothing_is_injected_before_the_display_geometry_is_known() {
    let mut d = InputDispatcher::default();
    let mut inj = RecordingInjector::default();
    assert_eq!(d.state(), InputState::NoPicture);
    d.mouse_down(&MouseEvent { button: 0, x: 0.5, y: 0.5 }, &mut inj);
    d.key_down(&key(kvk::A, KeyModifiers(0)), &mut inj);
    d.scroll(&Scroll { dx: 0.0, dy: -400.0, phase: "changed".into() }, &mut inj);
    d.gesture(GestureName::ShowDesktop, &mut inj);
    assert!(inj.ops.is_empty(), "no picture means no input, got {:?}", inj.ops);
}

#[test]
fn suspending_releases_what_was_held_and_then_drops_further_input() {
    let (mut d, mut inj) = ready();
    d.key_down(&key(kvk::COMMAND, KeyModifiers::COMMAND), &mut inj);
    d.mouse_down(&MouseEvent { button: 0, x: 0.5, y: 0.5 }, &mut inj);
    inj.ops.clear();

    d.suspend(InputState::DesktopUnavailable, &mut inj);
    assert_eq!(d.state(), InputState::DesktopUnavailable);
    assert!(inj.ops.contains(&up(CTRL)), "a held modifier is let go when input stops");
    assert!(inj.ops.contains(&InputOp::MouseButton { button: 0, down: false }));

    inj.ops.clear();
    d.key_down(&key(kvk::A, KeyModifiers(0)), &mut inj);
    assert!(inj.ops.is_empty(), "input stays suspended until it is resumed");

    d.resume();
    d.key_down(&key(kvk::A, KeyModifiers(0)), &mut inj);
    assert_eq!(inj.ops, vec![down(WinKey { vk: b'A' as u16, extended: false })]);
}

#[test]
fn losing_the_geometry_suspends_input_by_itself() {
    let (mut d, mut inj) = ready();
    d.set_geometry(None, &mut inj);
    assert_eq!(d.state(), InputState::NoPicture);
    d.resume();
    assert_eq!(d.state(), InputState::NoPicture, "resume cannot override a missing picture");
}

#[test]
fn a_reset_is_honoured_even_while_input_is_suspended() {
    let (mut d, mut inj) = ready();
    d.key_down(&key(kvk::A, KeyModifiers(0)), &mut inj);

    inj.refuse = Some(|op| matches!(op, InputOp::Key { down: false, .. }));
    d.suspend(InputState::DesktopUnavailable, &mut inj);
    assert_eq!(d.held().0.len(), 1);

    inj.refuse = None;
    inj.ops.clear();
    d.input_reset(&mut inj);
    assert_eq!(
        inj.ops,
        vec![up(WinKey { vk: b'A' as u16, extended: false })],
        "a reset must land even with input suspended; that is when a key is stuck"
    );
    assert!(d.held().0.is_empty());
}

/// A refused key-down is not down. Recording it as held would make the next
/// reset send a key-up for a key that was never pressed.
#[test]
fn a_refused_key_down_is_not_recorded_as_held() {
    let mut d = InputDispatcher::default();
    let mut inj = RecordingInjector {
        refuse: Some(|op| matches!(op, InputOp::Key { down: true, .. })),
        ..Default::default()
    };
    d.set_geometry(Some(DisplayGeometry::single(SCREEN.0, SCREEN.1, 1.0)), &mut inj);
    d.key_down(&key(kvk::A, KeyModifiers(0)), &mut inj);
    assert!(d.held().0.is_empty(), "a blocked press is not a held key");
    assert!(d.take_last_error().is_some(), "the refusal is reported, not discarded");
    assert!(d.take_last_error().is_none(), "and reported once");
}

/// A refused key-*up* means the key is still down. It stays on the list so the
/// next reset tries again instead of leaving it stuck forever.
#[test]
fn a_refused_release_keeps_the_key_on_the_held_list_to_retry() {
    let mut d = InputDispatcher::default();
    let mut inj = RecordingInjector::default();
    d.set_geometry(Some(DisplayGeometry::single(SCREEN.0, SCREEN.1, 1.0)), &mut inj);
    d.key_down(&key(kvk::A, KeyModifiers(0)), &mut inj);
    assert_eq!(d.held().0.len(), 1);

    inj.refuse = Some(|op| matches!(op, InputOp::Key { down: false, .. }));
    d.input_reset(&mut inj);
    assert_eq!(d.held().0.len(), 1, "the key is still down, so it is still tracked");
    assert!(d.take_last_error().is_some());

    inj.refuse = None;
    d.input_reset(&mut inj);
    assert!(d.held().0.is_empty(), "the retry succeeds");
}

#[test]
fn an_injector_error_names_the_op_it_refused() {
    let mut inj = RecordingInjector {
        refuse: Some(|op| matches!(op, InputOp::UnicodeChar(_))),
        ..Default::default()
    };
    let err = inj.perform(InputOp::UnicodeChar('x')).expect_err("must refuse");
    assert_eq!(err.op, InputOp::UnicodeChar('x'));
    assert!(!err.detail.is_empty());
}
