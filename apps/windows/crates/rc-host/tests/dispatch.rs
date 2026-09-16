//! Tests the message->InputOp dispatch: ordering, the seq gate, the chord
//! press/release order, text-vs-keystroke selection. These are the rules that
//! decide whether a remote keystroke lands correctly, asserted on the exact
//! op sequence rather than on a screen.

use rc_host::{InputDispatcher, InputOp, RecordingInjector};
use rc_proto::ctrl::{Click, Gesture, GestureName, KeyEvent, KeyModifiers, MouseEvent, MouseMove, Scroll};

fn run(f: impl FnOnce(&mut InputDispatcher, &mut RecordingInjector)) -> Vec<InputOp> {
    let mut d = InputDispatcher::default();
    let mut inj = RecordingInjector::default();
    f(&mut d, &mut inj);
    inj.ops
}

#[test]
fn a_cmd_c_shortcut_presses_control_then_c_then_releases_in_reverse() {
    // The single most important ordering: Ctrl down, C down, C up, Ctrl up.
    // Any other order either types "c" or leaves Control stuck.
    let ops = run(|d, i| {
        d.key_down(&KeyEvent { keycode: 0x08 /* kVK_ANSI_C */, mods: KeyModifiers::COMMAND.0, chars: String::new() }, i);
    });
    use rc_input::keycodes::vk;
    assert_eq!(
        ops,
        vec![
            InputOp::Key { vk: vk::LCONTROL, extended: false, down: true },
            InputOp::Key { vk: u16::from(b'C'), extended: false, down: true },
            InputOp::Key { vk: u16::from(b'C'), extended: false, down: false },
            InputOp::Key { vk: vk::LCONTROL, extended: false, down: false },
        ]
    );
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
    // Dispatch emits one char op; the Windows injector splits it into two
    // UTF-16 units. Keeping the split in the injector keeps this layer testable.
    assert_eq!(ops, vec![InputOp::UnicodeChar('😀')]);
}

#[test]
fn the_hi_channel_sequence_gate_drops_stale_and_duplicate_moves() {
    let mut d = InputDispatcher::default();
    let mut inj = RecordingInjector::default();
    d.mouse_move(&MouseMove { x: 0.1, y: 0.1, seq: 5 }, &mut inj);
    d.mouse_move(&MouseMove { x: 0.9, y: 0.9, seq: 3 }, &mut inj); // stale
    d.mouse_move(&MouseMove { x: 0.2, y: 0.2, seq: 5 }, &mut inj); // duplicate
    d.mouse_move(&MouseMove { x: 0.3, y: 0.3, seq: 6 }, &mut inj); // newer: applied
    let moves = inj.ops.iter().filter(|o| matches!(o, InputOp::MouseMoveAbs { .. })).count();
    assert_eq!(moves, 2, "only seq 5 and 6 should move the pointer");
}

#[test]
fn input_reset_reopens_the_sequence_gate() {
    // After a reconnect the controller's seq counter may restart; a reset must
    // stop the gate from swallowing every post-reconnect move.
    let mut d = InputDispatcher::default();
    let mut inj = RecordingInjector::default();
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
fn a_drag_moves_without_touching_the_button_state() {
    let ops = run(|d, i| {
        d.mouse_drag(&MouseEvent { button: 0, x: 0.5, y: 0.5 }, i);
    });
    assert_eq!(ops.len(), 1);
    assert!(matches!(ops[0], InputOp::MouseMoveAbs { .. }));
    assert!(!ops.iter().any(|o| matches!(o, InputOp::MouseButton { .. })),
            "a drag must not press or release a button");
}

#[test]
fn a_double_click_moves_once_then_presses_twice() {
    let ops = run(|d, i| {
        d.click(&Click { button: 0, x: 0.5, y: 0.5, count: 2 }, i);
    });
    let downs = ops.iter().filter(|o| matches!(o, InputOp::MouseButton { down: true, .. })).count();
    assert_eq!(downs, 2);
    assert!(matches!(ops[0], InputOp::MouseMoveAbs { .. }), "position is set before clicking");
}

#[test]
fn a_gesture_emits_its_windows_chord_pressed_then_released_in_reverse() {
    let ops = run(|d, i| {
        d.gesture(GestureName::LockScreen, i);
    });
    use rc_input::keycodes::vk;
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
fn slow_scroll_accumulates_across_dispatch_calls() {
    let mut d = InputDispatcher::default();
    let mut inj = RecordingInjector::default();
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
    assert_eq!(wheels, 30, "60 half-pixel events must integrate to 30 wheel units");
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

#[test]
fn an_unknown_mouse_button_is_ignored_not_injected() {
    let ops = run(|d, i| {
        d.mouse_down(&MouseEvent { button: 99, x: 0.5, y: 0.5 }, i);
    });
    assert!(ops.is_empty(), "an out-of-range button must produce nothing");
}
