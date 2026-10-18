//! Asking the owner (PROTOCOL.md §2.17 Consent). Unattended access is **off**
//! by default, so the normal case is that a controller which proved the code
//! still waits for whoever is at this PC.
//!
//! The Mac shows a window; this host is a console, so the prompt is the console
//! and the answer is a line of input. What matters is that the rules are the
//! same ones, and all of them live in the shared core: the 30-second deadline
//! and the 1.5-second guard against a reflexive Enter are the session state
//! machine's, the per-key and host-wide prompt budgets are
//! `rc_identity::consent`, and this file only renders and reads.

use std::io::Write;

use tokio::sync::mpsc;

/// What the owner typed, or that they walked away. A deadline is **not** read
/// here: the state machine's own `tick` times the prompt out, so a prompt
/// survives a signalling flap exactly as §4.2 requires.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ConsentAnswer {
    Allow,
    Decline,
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
        let mut out = std::io::stdout().lock();
        let _ = writeln!(out);
        let _ = writeln!(out, "  ---------------------------------------------");
        let _ = writeln!(out, "  Allow this computer to be controlled?");
        if self.replaces_previous {
            let _ = writeln!(out, "  A different request replaced the previous one.");
        }
        let _ = writeln!(
            out,
            "  It entered this PC's access code. If you do not answer,"
        );
        let _ = writeln!(out, "  the connection is declined.");
        let _ = writeln!(out);
        let _ = writeln!(
            out,
            "  Device ID     {}",
            rc_identity::access_code::formatted_device_id(&self.controller_device_id)
        );
        let _ = writeln!(out, "  Fingerprint   {}", self.controller_fingerprint);
        let _ = writeln!(out, "  ---------------------------------------------");
        let _ = writeln!(out, "  Type  y  to allow,  n  to decline. Declines in 30 s.");
        let _ = out.flush();
    }

    pub fn dismissed(outcome: rc_session::ConsentOutcome) {
        let said = match outcome {
            rc_session::ConsentOutcome::Allowed => "allowed",
            rc_session::ConsentOutcome::Declined => "declined",
            rc_session::ConsentOutcome::TimedOut => "declined — nobody answered",
            rc_session::ConsentOutcome::Cancelled => "withdrawn",
        };
        println!("  Request {said}.");
    }
}

/// Reads console lines on a blocking thread and forwards the ones that answer a
/// prompt. One reader for the whole process: a prompt is answered by whatever
/// is typed while it is open, and anything typed while none is open is ignored
/// by the caller rather than queued into the next prompt.
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

/// Only an unambiguous yes allows. Anything else that was clearly an answer is
/// a decline; anything that was not an answer at all is ignored, so a stray
/// Enter neither allows nor declines.
fn parse(line: &str) -> Option<ConsentAnswer> {
    match line.trim().to_ascii_lowercase().as_str() {
        "y" | "yes" | "allow" => Some(ConsentAnswer::Allow),
        "n" | "no" | "decline" | "d" => Some(ConsentAnswer::Decline),
        _ => None,
    }
}

#[cfg(test)]
mod tests;
