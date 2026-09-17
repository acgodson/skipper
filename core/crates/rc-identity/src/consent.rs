//! Host consent rate limit (PROTOCOL.md §2.17 Consent). Pure policy: the host
//! stores one ledger per controller key and passes it back on every call.

use serde::{Deserialize, Serialize};

pub const DECLINE_WINDOW_MS: i64 = 10 * 60 * 1000;
pub const DECLINES_BEFORE_AUTO_DECLINE: usize = 2;

#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct ConsentLedger {
    #[serde(default, rename = "declineTimesMs")]
    pub decline_times_ms: Vec<i64>,
}

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

fn recent(times: &[i64], now_ms: i64) -> Vec<i64> {
    let since = now_ms.saturating_sub(DECLINE_WINDOW_MS);
    let mut recent: Vec<i64> = times
        .iter()
        .copied()
        .filter(|&at| at > since && at <= now_ms)
        .collect();
    recent.sort_unstable();
    let excess = recent.len().saturating_sub(DECLINES_BEFORE_AUTO_DECLINE);
    recent.drain(..excess);
    recent
}

impl ConsentLedger {
    pub fn admit(&self, now_ms: i64) -> ConsentDecision {
        let recent = recent(&self.decline_times_ms, now_ms);
        match recent.len() >= DECLINES_BEFORE_AUTO_DECLINE {
            true => ConsentDecision::AutoDecline {
                retry_after_ms: recent[0].saturating_add(DECLINE_WINDOW_MS) - now_ms,
            },
            false => ConsentDecision::Prompt,
        }
    }

    pub fn declined(&self, now_ms: i64) -> Self {
        let mut times = self.decline_times_ms.clone();
        times.push(now_ms);
        Self {
            decline_times_ms: recent(&times, now_ms),
        }
    }

    pub fn allowed(&self) -> Self {
        Self::default()
    }
}

#[cfg(test)]
mod tests;
