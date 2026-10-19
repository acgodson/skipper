//! Asking the owner (PROTOCOL.md §2.17 Consent). Unattended access is **off**
//! by default, so the normal case is that a controller which proved the code
//! still waits for whoever is at this PC.
//!
//! The Mac shows a window, and so does the Windows host (`crate::ui`, which
//! answers through the same channel). The diagnostic build is a terminal, so
//! there the prompt is printed and the answer is a line of input. What matters
//! is that the rules are the same ones, and all of them live in the shared
//! core: the 30-second deadline and the 1.5-second guard against a reflexive
//! click are the session state machine's, the per-key and host-wide prompt
//! budgets are `rc_identity::consent`, and this file only renders and reads.

#[cfg(not(windows))]
use tokio::sync::mpsc;

use crate::status::{ConsentRequest, HostEvent};
use crate::report;
#[cfg(not(windows))]
use crate::say;

/// What the owner chose, or that they walked away. A deadline is **not** read
/// here: the state machine's own `tick` times the prompt out, so a prompt
/// survives a signalling flap exactly as §4.2 requires.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ConsentAnswer {
    Allow,
    /// Allow, and turn unattended access on so the next controller that proves
    /// the code is not asked either. The Mac's equivalent is allowing and then
    /// switching the toggle in the host window.
    AllowAndTurnOnUnattended,
    Decline,
}

impl ConsentAnswer {
    pub fn allows(&self) -> bool {
        !matches!(self, Self::Decline)
    }

    pub fn turns_on_unattended(&self) -> bool {
        matches!(self, Self::AllowAndTurnOnUnattended)
    }
}

pub struct ConsentPrompt {
    pub prompt_id: String,
    pub controller_device_id: String,
    pub controller_fingerprint: String,
    pub replaces_previous: bool,
}

impl ConsentPrompt {
    /// The controller's key fingerprint is shown because it is the one thing
    /// the other machine also shows, as its own: the owner can compare them.
    /// Nothing here names the access code.
    pub fn render(&self) {
        let device_id = rc_identity::access_code::formatted_device_id(&self.controller_device_id);
        report::event(HostEvent::ConsentOpened(ConsentRequest {
            device_id: device_id.clone(),
            fingerprint: self.controller_fingerprint.clone(),
            replaces_previous: self.replaces_previous,
        }));
        #[cfg(windows)]
        report!("asking whoever is at this PC to allow {device_id}");
        #[cfg(not(windows))]
        self.print(&device_id);
    }

    #[cfg(not(windows))]
    fn print(&self, device_id: &str) {
        say!();
        say!("  ---------------------------------------------");
        say!("  Allow this computer to be controlled?");
        if self.replaces_previous {
            say!("  A different request replaced the previous one.");
        }
        say!("  It entered this PC's access code. If you do not answer,");
        say!("  the connection is declined.");
        say!();
        say!("  Device ID     {device_id}");
        say!("  Fingerprint   {}", self.controller_fingerprint);
        say!("  ---------------------------------------------");
        say!("  Type  y  to allow this once,");
        say!("        t  to allow and turn on unattended access (from now on anyone");
        say!("           with this PC's access code connects without asking),");
        say!("        n  to decline. Declines in 30 s.");
    }

    pub fn dismissed(outcome: rc_session::ConsentOutcome) {
        report::event(HostEvent::ConsentClosed);
        let said = match outcome {
            rc_session::ConsentOutcome::Allowed => "allowed",
            rc_session::ConsentOutcome::Declined => "declined",
            rc_session::ConsentOutcome::TimedOut => "declined — nobody answered",
            rc_session::ConsentOutcome::Cancelled => "withdrawn",
        };
        #[cfg(windows)]
        report!("request {said}");
        #[cfg(not(windows))]
        say!("  Request {said}.");
    }
}

/// Reads console lines on a blocking thread and forwards the ones that answer a
/// prompt. One reader for the whole process: a prompt is answered by whatever
/// is typed while it is open, and anything typed while none is open is ignored
/// by the caller rather than queued into the next prompt.
#[cfg(not(windows))]
pub fn spawn_console_reader() -> mpsc::Receiver<ConsentAnswer> {
    let (tx, rx) = mpsc::channel::<ConsentAnswer>(4);
    std::thread::spawn(move || {
        let mut line = String::new();
        loop {
            line.clear();
            match std::io::stdin().read_line(&mut line) {
                Ok(0) | Err(_) => return,
                Ok(_) => {}
            }
            let Some(answer) = parse(&line) else { continue };
            if tx.blocking_send(answer).is_err() {
                return;
            }
        }
    });
    rx
}

/// Only an unambiguous yes, or `t`, allows. Anything else that was clearly an
/// answer is a decline; anything that was not an answer at all is ignored, so a stray
/// Enter neither allows nor declines.
#[cfg(not(windows))]
fn parse(line: &str) -> Option<ConsentAnswer> {
    match line.trim().to_ascii_lowercase().as_str() {
        "y" | "yes" | "allow" => Some(ConsentAnswer::Allow),
        "t" => Some(ConsentAnswer::AllowAndTurnOnUnattended),
        "n" | "no" | "decline" | "d" => Some(ConsentAnswer::Decline),
        _ => None,
    }
}

#[cfg(all(test, not(windows)))]
mod tests;
