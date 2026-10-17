//! The real `SendInput` path. Compiled only on Windows; every [`InputOp`] it
//! consumes was already decided and tested on all platforms by
//! `InputDispatcher`, so this file is a thin, mechanical translation.
//!
//! `SendInput` returns the number of events it inserted. Fewer than were given
//! means the input was blocked — UIPI against an elevated window is the case
//! that actually happens, and `GetLastError` names it. That is reported back as
//! an [`InjectError`] rather than dropped, because the dispatcher uses it to
//! decide whether a key is really held: a refused key-down must not be recorded
//! as down, and a refused key-up must stay on the list to be retried.

use windows::Win32::Foundation::GetLastError;
use windows::Win32::UI::Input::KeyboardAndMouse::*;

use crate::inject::{InjectError, InputOp, Injector};
use rc_proto::ctrl::MouseButton;

pub struct WindowsInjector;

impl WindowsInjector {
    pub fn new() -> Self {
        Self
    }

    fn send(op: &InputOp, inputs: &[INPUT]) -> Result<(), InjectError> {
        let sent = unsafe { SendInput(inputs, std::mem::size_of::<INPUT>() as i32) };
        if sent as usize == inputs.len() {
            return Ok(());
        }
        let code = unsafe { GetLastError() };
        Err(InjectError {
            op: op.clone(),
            detail: format!(
                "SendInput inserted {sent} of {} events (GetLastError {:#x}); \
                 blocked input is usually UIPI against an elevated window",
                inputs.len(),
                code.0
            ),
        })
    }
}

impl Default for WindowsInjector {
    fn default() -> Self {
        Self::new()
    }
}

impl Injector for WindowsInjector {
    fn perform(&mut self, op: InputOp) -> Result<(), InjectError> {
        match op {
            InputOp::MouseMoveAbs { x, y } => {
                let mut input = INPUT { r#type: INPUT_MOUSE, ..Default::default() };
                input.Anonymous.mi = MOUSEINPUT {
                    dx: x,
                    dy: y,
                    mouseData: 0,
                    dwFlags: MOUSEEVENTF_MOVE | MOUSEEVENTF_ABSOLUTE | MOUSEEVENTF_VIRTUALDESK,
                    time: 0,
                    dwExtraInfo: 0,
                };
                Self::send(&op, &[input])
            }
            InputOp::MouseButton { button, down } => {
                let flag = match (MouseButton::from_wire(button), down) {
                    (Some(MouseButton::Left), true) => MOUSEEVENTF_LEFTDOWN,
                    (Some(MouseButton::Left), false) => MOUSEEVENTF_LEFTUP,
                    (Some(MouseButton::Right), true) => MOUSEEVENTF_RIGHTDOWN,
                    (Some(MouseButton::Right), false) => MOUSEEVENTF_RIGHTUP,
                    (Some(MouseButton::Middle), true) => MOUSEEVENTF_MIDDLEDOWN,
                    (Some(MouseButton::Middle), false) => MOUSEEVENTF_MIDDLEUP,
                    (None, _) => return Ok(()),
                };
                let mut input = INPUT { r#type: INPUT_MOUSE, ..Default::default() };
                input.Anonymous.mi = MOUSEINPUT { dwFlags: flag, ..Default::default() };
                Self::send(&op, &[input])
            }
            InputOp::MouseWheel { delta, horizontal } => {
                let mut input = INPUT { r#type: INPUT_MOUSE, ..Default::default() };
                input.Anonymous.mi = MOUSEINPUT {
                    // Windows takes a signed wheel delta in an unsigned field;
                    // the bit pattern is what matters (a negative delta scrolls
                    // the other way).
                    mouseData: delta as u32,
                    dwFlags: if horizontal { MOUSEEVENTF_HWHEEL } else { MOUSEEVENTF_WHEEL },
                    ..Default::default()
                };
                Self::send(&op, &[input])
            }
            InputOp::Key { vk, extended, down } => {
                let mut flags = KEYBD_EVENT_FLAGS(0);
                if extended {
                    flags |= KEYEVENTF_EXTENDEDKEY;
                }
                if !down {
                    flags |= KEYEVENTF_KEYUP;
                }
                let mut input = INPUT { r#type: INPUT_KEYBOARD, ..Default::default() };
                input.Anonymous.ki = KEYBDINPUT {
                    wVk: VIRTUAL_KEY(vk),
                    wScan: 0,
                    dwFlags: flags,
                    time: 0,
                    dwExtraInfo: 0,
                };
                Self::send(&op, &[input])
            }
            InputOp::UnicodeChar(c) => {
                // A char outside the BMP is two UTF-16 units. Both units of a
                // surrogate pair go in **one** `SendInput` call: splitting them
                // lets another thread's input interleave between the halves and
                // the target application then sees two broken characters.
                let mut buf = [0u16; 2];
                let units = c.encode_utf16(&mut buf);
                let mut inputs: Vec<INPUT> = Vec::with_capacity(units.len() * 2);
                for unit in units.iter() {
                    for &up in &[false, true] {
                        let mut flags = KEYEVENTF_UNICODE;
                        if up {
                            flags |= KEYEVENTF_KEYUP;
                        }
                        let mut input = INPUT { r#type: INPUT_KEYBOARD, ..Default::default() };
                        input.Anonymous.ki = KEYBDINPUT {
                            wVk: VIRTUAL_KEY(0),
                            wScan: *unit,
                            dwFlags: flags,
                            time: 0,
                            dwExtraInfo: 0,
                        };
                        inputs.push(input);
                    }
                }
                Self::send(&op, &inputs)
            }
        }
    }
}
