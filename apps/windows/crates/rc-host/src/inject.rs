//! Applies decoded `ctrl`/`hi` messages to the machine.
//!
//! `Injector` is the trait; `WindowsInjector` (behind `cfg(windows)`) calls
//! `SendInput`, and `RecordingInjector` records intent without touching any OS
//! so the dispatch logic is testable everywhere. All the macOS->Windows
//! translation lives in `rc-input` and is exercised by both.
//!
//! The dispatcher owns the *state* a keyboard has and a stream of messages does
//! not: which keys and buttons are currently down. Without it a chord is pressed
//! and released inside one `key_down`, so a held modifier is never actually
//! held, auto-repeat re-presses modifiers it already holds, and a reset releases
//! a guessed list rather than what is really down.

use rc_input::{
    chord_for, DisplayGeometry, KeyPolicy, KeyResolution, ScrollAccumulator, WinKey,
};
use rc_proto::ctrl::{
    Click, DisplayInfo, GestureName, KeyEvent, MouseButton, MouseEvent, MouseMove, Scroll,
    ScrollPhase,
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

/// An op the OS refused. `SendInput` returning fewer events than it was given
/// is the documented signal that something blocked the input — UIPI against an
/// elevated window is the one that actually happens — and it is a fact about the
/// host's state, not noise to discard.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct InjectError {
    pub op: InputOp,
    pub detail: String,
}

pub trait Injector {
    fn perform(&mut self, op: InputOp) -> Result<(), InjectError>;
}

/// Why remote input is not being applied. Any value but `Running` means the
/// controller's clicks are dropped rather than aimed at something stale.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum InputState {
    Running,
    /// Capture is unavailable, or the display geometry is not known, so there
    /// is nothing trustworthy to aim at.
    NoPicture,
    /// The desktop is locked, or a secure/protected desktop is in front.
    DesktopUnavailable,
}

/// Turns protocol messages into ordered [`InputOp`]s and feeds them to an
/// [`Injector`]. Holds the per-axis scroll accumulators, the last-seen `hi`
/// sequence number, the display geometry clicks are aimed with, and the set of
/// keys and buttons currently held — so every ordering and release rule lives in
/// one tested place.
pub struct InputDispatcher {
    policy: KeyPolicy,
    scroll_x: ScrollAccumulator,
    scroll_y: ScrollAccumulator,
    last_move_seq: i64,
    geometry: Option<DisplayGeometry>,
    state: InputState,
    /// In press order, so a reset releases in reverse.
    held_keys: Vec<WinKey>,
    held_buttons: Vec<i32>,
    last_error: Option<InjectError>,
}

impl Default for InputDispatcher {
    fn default() -> Self {
        Self {
            policy: KeyPolicy::default(),
            scroll_x: ScrollAccumulator::default(),
            scroll_y: ScrollAccumulator::default(),
            last_move_seq: i64::MIN,
            geometry: None,
            state: InputState::NoPicture,
            held_keys: Vec::new(),
            held_buttons: Vec::new(),
            last_error: None,
        }
    }
}

impl InputDispatcher {
    pub fn with_policy(policy: KeyPolicy) -> Self {
        Self { policy, ..Self::default() }
    }

    /// The geometry clicks are translated with. `None` suspends input: a click
    /// aimed with no idea where the screen is would land somewhere arbitrary.
    pub fn set_geometry(&mut self, geometry: Option<DisplayGeometry>, inj: &mut dyn Injector) {
        self.geometry = geometry.filter(DisplayGeometry::is_usable);
        if self.geometry.is_none() {
            self.suspend(InputState::NoPicture, inj);
        } else if self.state == InputState::NoPicture {
            self.state = InputState::Running;
        }
    }

    pub fn geometry(&self) -> Option<DisplayGeometry> {
        self.geometry
    }

    /// Stop applying input, releasing everything currently held first. Leaving
    /// a key down while input is suspended is how a remote Ctrl gets stuck on
    /// the host after the picture goes away.
    pub fn suspend(&mut self, reason: InputState, inj: &mut dyn Injector) {
        self.state = reason;
        self.release_all(inj);
    }

    /// Resume, if there is something to aim at.
    pub fn resume(&mut self) {
        if self.geometry.is_some() {
            self.state = InputState::Running;
        }
    }

    pub fn state(&self) -> InputState {
        self.state
    }

    /// The most recent op the OS refused, for the host to log once rather than
    /// per event.
    pub fn take_last_error(&mut self) -> Option<InjectError> {
        self.last_error.take()
    }

    pub fn display_geometry(&self) -> Option<DisplayInfo> {
        self.geometry.map(|g| g.display_info())
    }

    fn running(&self) -> bool {
        self.state == InputState::Running && self.geometry.is_some()
    }

    fn perform(&mut self, op: InputOp, inj: &mut dyn Injector) -> bool {
        match inj.perform(op) {
            Ok(()) => true,
            Err(e) => {
                self.last_error = Some(e);
                false
            }
        }
    }

    /// Press a key and remember it is down. A repeat of a key already held is
    /// sent again — Windows auto-repeat is a stream of key-downs — without
    /// duplicating the bookkeeping.
    fn press(&mut self, key: WinKey, inj: &mut dyn Injector) {
        let op = InputOp::Key { vk: key.vk, extended: key.extended, down: true };
        if self.perform(op, inj) && !self.held_keys.contains(&key) {
            self.held_keys.push(key);
        }
    }

    /// Release a key. A refused release keeps the key on the held list so the
    /// next reset tries again rather than forgetting about it.
    fn release(&mut self, key: WinKey, inj: &mut dyn Injector) {
        let op = InputOp::Key { vk: key.vk, extended: key.extended, down: false };
        if self.perform(op, inj) {
            self.held_keys.retain(|k| *k != key);
        }
    }

    fn button_down(&mut self, button: i32, inj: &mut dyn Injector) {
        if self.perform(InputOp::MouseButton { button, down: true }, inj)
            && !self.held_buttons.contains(&button)
        {
            self.held_buttons.push(button);
        }
    }

    fn button_up(&mut self, button: i32, inj: &mut dyn Injector) {
        if self.perform(InputOp::MouseButton { button, down: false }, inj) {
            self.held_buttons.retain(|b| *b != button);
        }
    }

    /// Bring the held modifiers in line with what the controller says is down.
    /// Releasing the ones that disappeared is what heals a lost modifier
    /// key_up: the next keystroke's `mods` reveals it and the key comes back up.
    fn reconcile_modifiers(&mut self, wanted: &[WinKey], inj: &mut dyn Injector) {
        let stale: Vec<WinKey> = self
            .held_keys
            .iter()
            .rev()
            .copied()
            .filter(|k| KeyPolicy::is_modifier_vk(k.vk) && !wanted.contains(k))
            .collect();
        for key in stale {
            self.release(key, inj);
        }
        for key in wanted {
            if !self.held_keys.contains(key) {
                self.press(*key, inj);
            }
        }
    }

    fn press_chord(&mut self, keys: &[WinKey], inj: &mut dyn Injector) {
        for k in keys {
            self.press(*k, inj);
        }
        for k in keys.iter().rev() {
            self.release(*k, inj);
        }
    }

    fn move_to(&mut self, x: f64, y: f64, inj: &mut dyn Injector) {
        let Some(geometry) = self.geometry else { return };
        let (x, y) = geometry.to_absolute(x, y);
        self.perform(InputOp::MouseMoveAbs { x, y }, inj);
    }

    pub fn mouse_down(&mut self, e: &MouseEvent, inj: &mut dyn Injector) {
        if !self.running() || MouseButton::from_wire(e.button).is_none() {
            return;
        }
        self.move_to(e.x, e.y, inj);
        self.button_down(e.button, inj);
    }

    pub fn mouse_up(&mut self, e: &MouseEvent, inj: &mut dyn Injector) {
        if !self.running() || MouseButton::from_wire(e.button).is_none() {
            return;
        }
        self.move_to(e.x, e.y, inj);
        self.button_up(e.button, inj);
    }

    /// A drag is a move with the button already held — the button state is not
    /// touched here, matching `kCGEventLeftMouseDragged` on the Mac side.
    pub fn mouse_drag(&mut self, e: &MouseEvent, inj: &mut dyn Injector) {
        if !self.running() {
            return;
        }
        self.move_to(e.x, e.y, inj);
    }

    /// §6: drops any packet whose seq is not above the highest already seen.
    pub fn mouse_move(&mut self, m: &MouseMove, inj: &mut dyn Injector) {
        if !self.running() {
            return;
        }
        if m.seq <= self.last_move_seq {
            return;
        }
        self.last_move_seq = m.seq;
        self.move_to(m.x, m.y, inj);
    }

    pub fn click(&mut self, c: &Click, inj: &mut dyn Injector) {
        if !self.running() || MouseButton::from_wire(c.button).is_none() {
            return;
        }
        self.move_to(c.x, c.y, inj);
        for _ in 0..c.count.clamp(1, 3) {
            self.button_down(c.button, inj);
            self.button_up(c.button, inj);
        }
    }

    /// Press and **hold**. The release comes from `key_up`, which is what makes
    /// a held modifier actually held and a held key actually repeat.
    pub fn key_down(&mut self, e: &KeyEvent, inj: &mut dyn Injector) {
        if !self.running() {
            return;
        }
        match self.policy.resolve(e) {
            KeyResolution::Text(text) => {
                for c in text.chars() {
                    self.perform(InputOp::UnicodeChar(c), inj);
                }
            }
            KeyResolution::Keystroke { modifiers, key } => {
                let is_bare_modifier = key.is_some_and(|k| KeyPolicy::is_modifier_vk(k.vk));
                if !is_bare_modifier {
                    self.reconcile_modifiers(&modifiers, inj);
                }
                if let Some(key) = key {
                    self.press(key, inj);
                }
            }
            KeyResolution::Ignored => {}
        }
    }

    /// Release the key this event names, then let go of any modifier the
    /// controller no longer reports as held. Text injection has no up event —
    /// the character was already delivered as a down/up pair.
    pub fn key_up(&mut self, e: &KeyEvent, inj: &mut dyn Injector) {
        if !self.running() {
            return;
        }
        match self.policy.resolve(e) {
            KeyResolution::Text(_) => {}
            KeyResolution::Keystroke { modifiers, key } => {
                if let Some(key) = key {
                    self.release(key, inj);
                }
                let is_bare_modifier = key.is_some_and(|k| KeyPolicy::is_modifier_vk(k.vk));
                if !is_bare_modifier {
                    self.reconcile_modifiers(&modifiers, inj);
                }
            }
            KeyResolution::Ignored => {}
        }
    }

    /// A gesture boundary banks nothing new, but must not carry a stale fraction across a fresh scroll.
    pub fn scroll(&mut self, s: &Scroll, inj: &mut dyn Injector) {
        if !self.running() {
            return;
        }
        if ScrollPhase::from_wire(&s.phase) == ScrollPhase::End {
            self.scroll_x.reset();
            self.scroll_y.reset();
            return;
        }
        if let Some(delta) = self.scroll_y.push(s.dy) {
            self.perform(InputOp::MouseWheel { delta, horizontal: false }, inj);
        }
        if let Some(delta) = self.scroll_x.push(s.dx) {
            self.perform(InputOp::MouseWheel { delta, horizontal: true }, inj);
        }
    }

    pub fn gesture(&mut self, name: GestureName, inj: &mut dyn Injector) {
        if !self.running() {
            return;
        }
        self.press_chord(chord_for(name).keys, inj);
    }

    /// §5 `input_reset`: release everything. Idempotent, and accepted whatever
    /// the input state is — a reset is the one message that must still land when
    /// input is suspended, because that is when something is most likely stuck.
    pub fn input_reset(&mut self, inj: &mut dyn Injector) {
        self.release_all(inj);
    }

    /// Release every key and button this dispatcher knows it pressed, newest
    /// first, and forget the scroll banks and the `hi` sequence gate.
    fn release_all(&mut self, inj: &mut dyn Injector) {
        self.scroll_x.reset();
        self.scroll_y.reset();
        self.last_move_seq = i64::MIN;
        for key in std::mem::take(&mut self.held_keys).into_iter().rev() {
            let op = InputOp::Key { vk: key.vk, extended: key.extended, down: false };
            if !self.perform(op, inj) {
                self.held_keys.push(key);
            }
        }
        for button in std::mem::take(&mut self.held_buttons).into_iter().rev() {
            if !self.perform(InputOp::MouseButton { button, down: false }, inj) {
                self.held_buttons.push(button);
            }
        }
    }

    /// What is held right now, for tests and for the host's logging.
    pub fn held(&self) -> (&[WinKey], &[i32]) {
        (&self.held_keys, &self.held_buttons)
    }
}

/// Records intents instead of performing them, for tests and for the
/// `--synthetic` diagnostic mode.
#[derive(Default)]
pub struct RecordingInjector {
    pub ops: Vec<InputOp>,
    /// Ops matching this predicate are refused, so the failure handling can be
    /// exercised without a machine that refuses input.
    pub refuse: Option<fn(&InputOp) -> bool>,
}

impl Injector for RecordingInjector {
    fn perform(&mut self, op: InputOp) -> Result<(), InjectError> {
        if self.refuse.is_some_and(|f| f(&op)) {
            return Err(InjectError { op, detail: "refused by test".into() });
        }
        self.ops.push(op);
        Ok(())
    }
}
