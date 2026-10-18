//! Keeping the PC awake, by the rule `StayAwake.swift` holds on the Mac:
//!
//! - while this host is reachable (signalling authenticated) or a session is
//!   connecting, awaiting consent, live or reconnecting, idle *system* sleep is
//!   prevented (`ES_SYSTEM_REQUIRED`, the Mac's `idleSystemSleep`);
//! - only while such a session exists is idle *display* sleep prevented as well
//!   (`ES_DISPLAY_REQUIRED`, the Mac's `displaySleep`), and setting it resets the
//!   display idle timer, which is what brings the screen back as the Mac's
//!   declared user activity does.
//!
//! Like the Mac assertions this prevents *idle* sleep only. It cannot wake a
//! machine that is already asleep — that needs Wake-on-LAN, which is out of
//! scope (WINDOWS-HOST.md §5) — and a user who puts the PC to sleep still can.

use rc_session::SessionPhase;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum StayAwake {
    Idle,
    ReachableHost,
    Session,
}

impl StayAwake {
    pub fn for_host(online: bool, phase: &SessionPhase) -> Self {
        match phase {
            SessionPhase::Connecting
            | SessionPhase::AwaitingConsent
            | SessionPhase::Live
            | SessionPhase::Reconnecting => Self::Session,
            SessionPhase::Idle | SessionPhase::Closed { .. } => match online {
                true => Self::ReachableHost,
                false => Self::Idle,
            },
        }
    }

    pub fn holds_system(self) -> bool {
        self != Self::Idle
    }

    pub fn holds_display(self) -> bool {
        self == Self::Session
    }
}

/// Owns this process's execution state. `SetThreadExecutionState` is
/// per-thread and is dropped when the thread that set it exits, and the async
/// runtime moves tasks between worker threads, so every set and every clear
/// happens on one dedicated thread that lives exactly as long as this value.
/// Dropping it clears the state (`ES_CONTINUOUS` alone) on that thread and
/// waits for it, so normal power behaviour is back before the host exits.
pub struct KeepAwake {
    state: StayAwake,
    requests: Option<std::sync::mpsc::Sender<StayAwake>>,
    holder: Option<std::thread::JoinHandle<()>>,
}

impl KeepAwake {
    pub fn new() -> Self {
        let (requests, received) = std::sync::mpsc::channel::<StayAwake>();
        let holder = std::thread::Builder::new()
            .name("keep-awake".into())
            .spawn(move || {
                for state in received {
                    set_execution_state(state);
                }
                set_execution_state(StayAwake::Idle);
            })
            .map_err(|e| eprintln!("rc-host: this PC may sleep during a session ({e})"))
            .ok();
        Self {
            state: StayAwake::Idle,
            requests: holder.as_ref().map(|_| requests),
            holder,
        }
    }

    pub fn update(&mut self, next: StayAwake) {
        if next == self.state {
            return;
        }
        self.state = next;
        if let Some(requests) = &self.requests {
            let _ = requests.send(next);
        }
    }
}

impl Default for KeepAwake {
    fn default() -> Self {
        Self::new()
    }
}

impl Drop for KeepAwake {
    fn drop(&mut self) {
        self.requests = None;
        if let Some(holder) = self.holder.take() {
            let _ = holder.join();
        }
    }
}

#[cfg(windows)]
fn set_execution_state(state: StayAwake) {
    use windows::Win32::System::Power::*;
    let mut flags = ES_CONTINUOUS;
    if state.holds_system() {
        flags = flags | ES_SYSTEM_REQUIRED;
    }
    if state.holds_display() {
        flags = flags | ES_DISPLAY_REQUIRED;
    }
    unsafe {
        SetThreadExecutionState(flags);
    }
}

/// Non-Windows builds are the diagnostic ones and hold nothing.
#[cfg(not(windows))]
fn set_execution_state(_state: StayAwake) {}

#[cfg(test)]
mod tests;
