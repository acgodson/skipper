use super::*;
use crate::signing::tests::compressed_spki as compressed;
use crate::DeviceKey;

const T0: i64 = 1_700_000_000_000;
const HOUR: i64 = 60 * 60 * 1000;

fn active(at: i64) -> GuessCounter {
    GuessCounter {
        failures: 1,
        last_failure_ms: at,
        ..GuessCounter::default()
    }
}

#[test]
fn a_controller_key_is_its_canonical_spelling() {
    let key = DeviceKey::generate();
    assert_eq!(
        controller_key(&compressed(&key)).unwrap(),
        key.public_key_spki_base64()
    );
    for bad in ["", HOST_KEY, "not a key"] {
        assert_eq!(controller_key(bad), Err(LedgerKeyError::NotADeviceKey));
    }
}

#[test]
fn entries_idle_for_a_day_are_forgotten_and_the_host_budget_is_kept() {
    let recent = DeviceKey::generate().public_key_spki_base64();
    let stale = DeviceKey::generate().public_key_spki_base64();
    let locked = DeviceKey::generate().public_key_spki_base64();
    let now = T0 + 24 * HOUR;
    let counters = BTreeMap::from([
        (recent.clone(), active(T0 + 1)),
        (stale.clone(), active(T0)),
        (
            locked.clone(),
            GuessCounter {
                locked_until_ms: now + 1,
                ..active(T0 - HOUR)
            },
        ),
        (HOST_KEY.to_string(), active(now)),
    ]);
    let pruned = prune(counters, now);
    assert!(pruned.contains_key(&recent));
    assert!(
        !pruned.contains_key(&stale),
        "exactly 24 h idle is forgotten"
    );
    assert!(
        pruned.contains_key(&locked),
        "a lockout still running is kept"
    );
    assert!(pruned.contains_key(HOST_KEY));
}

#[test]
fn spellings_of_one_key_collapse_into_one_entry_that_keeps_the_worst_state() {
    let key = DeviceKey::generate();
    let counters = BTreeMap::from([
        (
            key.public_key_spki_base64(),
            GuessCounter {
                decline_times_ms: vec![T0],
                ..active(T0)
            },
        ),
        (
            compressed(&key),
            GuessCounter {
                failures: 4,
                locked_until_ms: T0 + HOUR,
                decline_times_ms: vec![T0 + 5],
                ..active(T0 + 5)
            },
        ),
        ("garbage".to_string(), active(T0)),
    ]);
    let pruned = prune(counters, T0 + 10);
    assert_eq!(pruned.len(), 1);
    let merged = &pruned[&key.public_key_spki_base64()];
    assert_eq!(merged.failures, 4);
    assert_eq!(merged.locked_until_ms, T0 + HOUR);
    assert_eq!(merged.decline_times_ms, vec![T0, T0 + 5]);
}

#[test]
fn the_map_never_holds_more_than_the_cap_and_keeps_the_newest() {
    let mut counters = BTreeMap::from([(HOST_KEY.to_string(), active(T0))]);
    let mut keys = Vec::new();
    for i in 0..(MAX_ENTRIES as i64 + 20) {
        let key = DeviceKey::generate().public_key_spki_base64();
        counters.insert(key.clone(), active(T0 + i));
        keys.push(key);
    }
    let pruned = prune(counters, T0 + 1_000);
    assert_eq!(pruned.len(), MAX_ENTRIES);
    assert!(pruned.contains_key(HOST_KEY));
    assert!(
        !pruned.contains_key(&keys[20]),
        "the oldest are dropped first"
    );
    assert!(pruned.contains_key(&keys[21]));
    assert!(pruned.contains_key(keys.last().unwrap()));
}
