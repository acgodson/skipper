//! The real `SendInput` path. Compiled only on Windows; every [`InputOp`] it
//! consumes was already decided and tested on all platforms by
//! `InputDispatcher`, so this file is a thin, mechanical translation.

use windows::Win32::UI::Input::KeyboardAndMouse::*;

use crate::inject::{InputOp, Injector};
use rc_proto::ctrl::MouseButton;

pub struct WindowsInjector;

impl WindowsInjector {
    pub fn new() -> Self {
        Self
    }

    fn send(inputs: &[INPUT]) {
        // A zero return means the input was blocked (UIPI) — a real possibility
        // against an elevated window when this process is not elevated. There is
        // nothing to do about it per-call; the elevation manifest is the fix.
        unsafe {
            SendInput(inputs, std::mem::size_of::<INPUT>() as i32);
        }
    }
}

impl Injector for WindowsInjector {
    fn perform(&mut self, op: InputOp) {
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
                Self::send(&[input]);
            }
            InputOp::MouseButton { button, down } => {
                let flag = match (MouseButton::from_wire(button), down) {
                    (Some(MouseButton::Left), true) => MOUSEEVENTF_LEFTDOWN,
                    (Some(MouseButton::Left), false) => MOUSEEVENTF_LEFTUP,
                    (Some(MouseButton::Right), true) => MOUSEEVENTF_RIGHTDOWN,
                    (Some(MouseButton::Right), false) => MOUSEEVENTF_RIGHTUP,
                    (Some(MouseButton::Middle), true) => MOUSEEVENTF_MIDDLEDOWN,
                    (Some(MouseButton::Middle), false) => MOUSEEVENTF_MIDDLEUP,
                    (None, _) => return,
                };
                let mut input = INPUT { r#type: INPUT_MOUSE, ..Default::default() };
                input.Anonymous.mi = MOUSEINPUT { dwFlags: flag, ..Default::default() };
                Self::send(&[input]);
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
                Self::send(&[input]);
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
                Self::send(&[input]);
            }
            InputOp::UnicodeChar(c) => {
                // A char outside the BMP is two UTF-16 units, each its own
                // KEYEVENTF_UNICODE event with wVk = 0.
                let mut buf = [0u16; 2];
                for unit in c.encode_utf16(&mut buf).iter() {
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
                        Self::send(&[input]);
                    }
                }
            }
        }
    }
}
