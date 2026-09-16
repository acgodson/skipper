//! Applies decoded `ctrl`/`hi` messages to the machine.
//!
//! `Injector` is the trait; `WindowsInjector` (behind `cfg(windows)`) calls
//! `SendInput`, and `RecordingInjector` records intent without touching any OS
//! so the dispatch logic is testable everywhere. All the macOS->Windows
//! translation lives in `rc-input` and is exercised by both.

use rc_input::{
    chord_for, map_keycode, modifier_keys, should_inject_as_text, to_absolute, ModifierPolicy,
    ScrollAccumulator, WinKey,
};
use rc_proto::ctrl::{
    Click, DisplayInfo, GestureName, KeyEvent, KeyModifiers, MouseButton, MouseEvent, MouseMove,
    Scroll, ScrollPhase,
};

/// A single low-level intent, at the granularity `SendInput` consumes. The
/// recording injector stores these; the Windows injector performs them.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum InputOp {
    MouseMoveAbs { x: i32, y: i32 },
    MouseButton { button: i32, down: bool },
    MouseWheel { delta: i32, horizontal: bool },
    Key { vk: u16, extended: bool, down: bool },
    UnicodeChar(char),
}

pub trait Injector {
    fn perform(&mut self, op: InputOp);
}

/// Turns protocol messages into ordered [`InputOp`]s and feeds them to an
/// [`Injector`]. Holds the per-axis scroll accumulators and the last-seen `hi`
/// sequence number, so the ordering and clamping rules live in one tested place.
pub struct InputDispatcher {
    policy: ModifierPolicy,
    scroll_x: ScrollAccumulator,
    scroll_y: ScrollAccumulator,
    last_move_seq: i64,
}

impl Default for InputDispatcher {
    fn default() -> Self {
        Self {
            policy: ModifierPolicy::default(),
            scroll_x: ScrollAccumulator::default(),
            scroll_y: ScrollAccumulator::default(),
            last_move_seq: i64::MIN,
        }
    }
}

impl InputDispatcher {
    pub fn with_policy(policy: ModifierPolicy) -> Self {
        Self { policy, ..Self::default() }
    }

    fn press_chord(&self, keys: &[WinKey], inj: &mut dyn Injector) {
        for k in keys {
            inj.perform(InputOp::Key { vk: k.vk, extended: k.extended, down: true });
        }
        for k in keys.iter().rev() {
            inj.perform(InputOp::Key { vk: k.vk, extended: k.extended, down: false });
        }
    }

    fn move_to(&self, x: f64, y: f64, inj: &mut dyn Injector) {
        inj.perform(InputOp::MouseMoveAbs { x: to_absolute(x), y: to_absolute(y) });
    }

    pub fn mouse_down(&mut self, e: &MouseEvent, inj: &mut dyn Injector) {
        if MouseButton::from_wire(e.button).is_none() {
            return; // §0: unknown button ignored
        }
        self.move_to(e.x, e.y, inj);
        inj.perform(InputOp::MouseButton { button: e.button, down: true });
    }

    pub fn mouse_up(&mut self, e: &MouseEvent, inj: &mut dyn Injector) {
        if MouseButton::from_wire(e.button).is_none() {
            return;
        }
        self.move_to(e.x, e.y, inj);
        inj.perform(InputOp::MouseButton { button: e.button, down: false });
    }

    /// A drag is a move with the button already held — the button state is not
    /// touched here, matching `kCGEventLeftMouseDragged` on the Mac side.
    pub fn mouse_drag(&mut self, e: &MouseEvent, inj: &mut dyn Injector) {
        self.move_to(e.x, e.y, inj);
    }

    pub fn mouse_move(&mut self, m: &MouseMove, inj: &mut dyn Injector) {
        // §6: drop any packet whose seq is <= the highest already seen.
        if m.seq <= self.last_move_seq {
            return;
        }
        self.last_move_seq = m.seq;
        self.move_to(m.x, m.y, inj);
    }

    pub fn click(&mut self, c: &Click, inj: &mut dyn Injector) {
        if MouseButton::from_wire(c.button).is_none() {
            return;
        }
        self.move_to(c.x, c.y, inj);
        for _ in 0..c.count.clamp(1, 3) {
            inj.perform(InputOp::MouseButton { button: c.button, down: true });
            inj.perform(InputOp::MouseButton { button: c.button, down: false });
        }
    }

    pub fn key_down(&mut self, e: &KeyEvent, inj: &mut dyn Injector) {
        let mods = KeyModifiers::from_wire(e.mods);
        // Prefer the resolved character for printable input: it sidesteps
        // keyboard-layout translation entirely (rc-input decides when this is
        // safe — never for a chord).
        if should_inject_as_text(&e.chars, mods) {
            for c in e.chars.chars() {
                inj.perform(InputOp::UnicodeChar(c));
            }
            return;
        }
        let held = modifier_keys(mods, self.policy);
        for k in &held {
            inj.perform(InputOp::Key { vk: k.vk, extended: k.extended, down: true });
        }
        if let Some(key) = map_keycode(e.keycode) {
            inj.perform(InputOp::Key { vk: key.vk, extended: key.extended, down: true });
            inj.perform(InputOp::Key { vk: key.vk, extended: key.extended, down: false });
        }
        for k in held.iter().rev() {
            inj.perform(InputOp::Key { vk: k.vk, extended: k.extended, down: false });
        }
    }

    /// `key_up` for a bare key. Modifiers are released as part of `key_down`'s
    /// chord, and text injection has no up event, so a `key_up` only matters for
    /// a held non-text key.
    pub fn key_up(&mut self, e: &KeyEvent, inj: &mut dyn Injector) {
        if !e.chars.is_empty() {
            return;
        }
        if let Some(key) = map_keycode(e.keycode) {
            inj.perform(InputOp::Key { vk: key.vk, extended: key.extended, down: false });
        }
    }

    pub fn scroll(&mut self, s: &Scroll, inj: &mut dyn Injector) {
        match ScrollPhase::from_wire(&s.phase) {
            // A gesture boundary banks nothing new but must not carry a stale
            // fraction across a fresh scroll.
            ScrollPhase::End => {
                self.scroll_x.reset();
                self.scroll_y.reset();
                return;
            }
            _ => {}
        }
        if let Some(delta) = self.scroll_y.push(s.dy) {
            inj.perform(InputOp::MouseWheel { delta, horizontal: false });
        }
        if let Some(delta) = self.scroll_x.push(s.dx) {
            inj.perform(InputOp::MouseWheel { delta, horizontal: true });
        }
    }

    pub fn gesture(&mut self, name: GestureName, inj: &mut dyn Injector) {
        self.press_chord(chord_for(name).keys, inj);
    }

    /// §5 `input_reset`: release everything. Idempotent. Modelled as releasing
    /// the modifier and mouse keys the host could plausibly be holding, plus
    /// clearing the scroll banks so a reconnect starts clean.
    pub fn input_reset(&mut self, inj: &mut dyn Injector) {
        self.scroll_x.reset();
        self.scroll_y.reset();
        self.last_move_seq = i64::MIN;
        use rc_input::keycodes::vk;
        for vk in [vk::LSHIFT, 0xA1, vk::LCONTROL, vk::RCONTROL, vk::LMENU, vk::RMENU, vk::LWIN] {
            inj.perform(InputOp::Key { vk, extended: false, down: false });
        }
        for button in 0..=2 {
            inj.perform(InputOp::MouseButton { button, down: false });
        }
    }

    pub fn display_geometry(&self) -> Option<DisplayInfo> {
        None
    }
}

/// Records intents instead of performing them, for tests and for the
/// `--synthetic` diagnostic mode.
#[derive(Default)]
pub struct RecordingInjector {
    pub ops: Vec<InputOp>,
}

impl Injector for RecordingInjector {
    fn perform(&mut self, op: InputOp) {
        self.ops.push(op);
    }
}
