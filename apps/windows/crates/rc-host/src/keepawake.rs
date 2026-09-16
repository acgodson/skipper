//! Keep the machine awake while a session is (or may be) live, mirroring
//! `StayAwake.swift`'s `IOPMAssertPreventUserIdleSystemSleep`.
//!
//! On Windows this is `SetThreadExecutionState(ES_CONTINUOUS | ES_SYSTEM_REQUIRED
//! | ES_DISPLAY_REQUIRED)`. Like the Mac assertion it prevents *idle* sleep; it
//! cannot wake a machine that is already asleep — that needs Wake-on-LAN, which
//! is out of scope (WINDOWS-HOST.md §5). Dropping the guard restores normal
//! power behaviour.

/// Held while unattended access is on. Non-Windows builds are a no-op so the
/// host binary links for the interop harness.
pub struct KeepAwake {
    active: bool,
}

impl KeepAwake {
    pub fn enabled(on: bool) -> Self {
        if on {
            Self::set(true);
        }
        Self { active: on }
    }

    #[cfg(windows)]
    fn set(on: bool) {
        use windows::Win32::System::Power::*;
        let flags = if on {
            ES_CONTINUOUS | ES_SYSTEM_REQUIRED | ES_DISPLAY_REQUIRED
        } else {
            ES_CONTINUOUS
        };
        unsafe {
            SetThreadExecutionState(flags);
        }
    }

    #[cfg(not(windows))]
    fn set(_on: bool) {}
}

impl Drop for KeepAwake {
    fn drop(&mut self) {
        if self.active {
            Self::set(false);
        }
    }
}
