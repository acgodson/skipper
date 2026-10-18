//! The console the host runs in, made safe to look at.
//!
//! A Windows console starts in QuickEdit mode: one click inside the window
//! enters text selection, and while a selection is open every write to the
//! console blocks. The host prints from its only loop, so a click froze the
//! whole host — no answer to the controller, no reply to the access-code
//! exchange — until someone pressed Esc or Enter. Turning QuickEdit off makes
//! a click harmless; text can still be selected through the window menu.

#[cfg(windows)]
pub fn disable_quick_edit() {
    use windows::Win32::System::Console::{
        GetConsoleMode, GetStdHandle, SetConsoleMode, CONSOLE_MODE, ENABLE_EXTENDED_FLAGS,
        ENABLE_QUICK_EDIT_MODE, STD_INPUT_HANDLE,
    };

    unsafe {
        let Ok(input) = GetStdHandle(STD_INPUT_HANDLE) else { return };
        let mut mode = CONSOLE_MODE(0);
        if GetConsoleMode(input, &mut mode).is_err() {
            return;
        }
        let _ = SetConsoleMode(input, (mode & !ENABLE_QUICK_EDIT_MODE) | ENABLE_EXTENDED_FLAGS);
    }
}

#[cfg(not(windows))]
pub fn disable_quick_edit() {}
