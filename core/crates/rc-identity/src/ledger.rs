//! The host's stored map of per-controller counters. Keys are canonical
//! device keys, so one key cannot collect a fresh budget per base64 spelling;
//! the map forgets anything a day old and never grows past a fixed size.

use std::collections::BTreeMap;

use crate::pake::GuessCounter;
use crate::signing::canonical_public_key;

pub const HOST_KEY: &str = "host";
pub const RETENTION_MS: i64 = 24 * 60 * 60 * 1000;
pub const MAX_ENTRIES: usize = 256;

#[derive(Debug, thiserror::Error, PartialEq, Eq)]
pub enum LedgerKeyError {
    #[error("a ledger key must be a P-256 device key")]
    NotADeviceKey,
}

/// The one key a controller's counter is stored under.
pub fn controller_key(pubkey_base64: &str) -> Result<String, LedgerKeyError> {
    canonical_public_key(pubkey_base64)
        .ok()
        .filter(|canonical| canonical != HOST_KEY)
        .ok_or(LedgerKeyError::NotADeviceKey)
}

fn merged(kept: GuessCounter, other: GuessCounter) -> GuessCounter {
    let union = |a: &[i64], b: &[i64]| {
        let mut all: Vec<i64> = a.iter().chain(b).copied().collect();
        all.sort_unstable();
        all.dedup();
        all
    };
    GuessCounter {
        failures: kept.failures.max(other.failures),
        last_failure_ms: kept.last_failure_ms.max(other.last_failure_ms),
        locked_until_ms: kept.locked_until_ms.max(other.locked_until_ms),
        failure_times_ms: union(&kept.failure_times_ms, &other.failure_times_ms),
        decline_times_ms: union(&kept.decline_times_ms, &other.decline_times_ms),
        prompt_times_ms: union(&kept.prompt_times_ms, &other.prompt_times_ms),
    }
}

pub fn prune(
    counters: BTreeMap<String, GuessCounter>,
    now_ms: i64,
) -> BTreeMap<String, GuessCounter> {
    let since = now_ms.saturating_sub(RETENTION_MS);
    let mut host = None;
    let mut controllers: BTreeMap<String, GuessCounter> = BTreeMap::new();
    for (key, counter) in counters {
        if counter.last_activity_ms() <= since {
            continue;
        }
        if key == HOST_KEY {
            host = Some(counter);
            continue;
        }
        let Ok(canonical) = controller_key(&key) else {
            continue;
        };
        let combined = match controllers.remove(&canonical) {
            Some(existing) => merged(existing, counter),
            None => counter,
        };
        controllers.insert(canonical, combined);
    }
    let room = MAX_ENTRIES - usize::from(host.is_some());
    let mut newest: Vec<(String, GuessCounter)> = controllers.into_iter().collect();
    newest
        .sort_by_key(|(key, counter)| (std::cmp::Reverse(counter.last_activity_ms()), key.clone()));
    newest.truncate(room);
    let mut pruned: BTreeMap<String, GuessCounter> = newest.into_iter().collect();
    if let Some(host) = host {
        pruned.insert(HOST_KEY.to_string(), host);
    }
    pruned
}

#[cfg(test)]
mod tests;
