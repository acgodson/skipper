//! Host consent rate limit (PROTOCOL.md §2.17 Consent). Pure policy over the
//! host's [`GuessLedger`]: the controller counter carries that key's declines,
//! the host counter carries every prompt shown. A prompt is counted as a
//! decline and a spent prompt the moment it opens; only Allow gives either
//! back, so a hang-up, a replaced session or a crash during the prompt costs
//! the controller as much as a click on Decline.

use crate::pake::GuessLedger;

pub const WINDOW_MS: i64 = 10 * 60 * 1000;
pub const DECLINES_BEFORE_AUTO_DECLINE: usize = 2;
pub const PROMPTS_PER_WINDOW: usize = 3;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ConsentDecision {
    Prompt,
    AutoDecline { retry_after_ms: i64 },
}

impl ConsentDecision {
    pub fn should_prompt(&self) -> bool {
        matches!(self, ConsentDecision::Prompt)
    }

    pub fn retry_after_ms(&self) -> i64 {
        match self {
            ConsentDecision::Prompt => 0,
            ConsentDecision::AutoDecline { retry_after_ms } => *retry_after_ms,
        }
    }
}

fn recent(times: &[i64], now_ms: i64, keep: usize) -> Vec<i64> {
    let since = now_ms.saturating_sub(WINDOW_MS);
    let mut recent: Vec<i64> = times
        .iter()
        .copied()
        .filter(|&at| at > since && at <= now_ms)
        .collect();
    recent.sort_unstable();
    let excess = recent.len().saturating_sub(keep);
    recent.drain(..excess);
    recent
}

fn exhausted(times: &[i64], now_ms: i64, limit: usize) -> Option<i64> {
    let recent = recent(times, now_ms, limit);
    (recent.len() >= limit).then(|| recent[0].saturating_add(WINDOW_MS) - now_ms)
}

pub fn admit(ledger: &GuessLedger, now_ms: i64) -> ConsentDecision {
    [
        exhausted(
            &ledger.controller.decline_times_ms,
            now_ms,
            DECLINES_BEFORE_AUTO_DECLINE,
        ),
        exhausted(&ledger.host.prompt_times_ms, now_ms, PROMPTS_PER_WINDOW),
    ]
    .into_iter()
    .flatten()
    .max()
    .map_or(ConsentDecision::Prompt, |retry_after_ms| {
        ConsentDecision::AutoDecline { retry_after_ms }
    })
}

pub fn prompted(ledger: &GuessLedger, now_ms: i64) -> GuessLedger {
    let mut next = ledger.clone();
    next.controller.decline_times_ms.push(now_ms);
    next.controller.decline_times_ms = recent(
        &next.controller.decline_times_ms,
        now_ms,
        DECLINES_BEFORE_AUTO_DECLINE,
    );
    next.host.prompt_times_ms.push(now_ms);
    next.host.prompt_times_ms = recent(&next.host.prompt_times_ms, now_ms, PROMPTS_PER_WINDOW);
    next
}

pub fn allowed(ledger: &GuessLedger, now_ms: i64) -> GuessLedger {
    let mut next = ledger.clone();
    next.controller.decline_times_ms.clear();
    let mut prompts = recent(&ledger.host.prompt_times_ms, now_ms, PROMPTS_PER_WINDOW);
    prompts.pop();
    next.host.prompt_times_ms = prompts;
    next
}

#[cfg(test)]
mod tests;
