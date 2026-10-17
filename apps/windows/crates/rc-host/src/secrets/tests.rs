use super::*;

struct Scratch(PathBuf);

impl Scratch {
    fn new(tag: &str) -> Self {
        let path = std::env::temp_dir().join(format!(
            "rc-secrets-{tag}-{}-{:?}",
            std::process::id(),
            std::thread::current().id()
        ));
        let _ = std::fs::remove_dir_all(&path);
        Self(path)
    }

    fn store(&self) -> SecretStore {
        SecretStore::open(self.0.clone()).unwrap()
    }
}

impl Drop for Scratch {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}

#[test]
fn a_secret_survives_a_reopen_and_a_missing_one_is_none_rather_than_an_error() {
    let scratch = Scratch::new("roundtrip");
    let store = scratch.store();
    assert!(store
        .load::<String>(SecretAccount::AccessCode)
        .unwrap()
        .is_none());
    store
        .save(SecretAccount::AccessCode, &"ABCD1234EFGH".to_string())
        .unwrap();
    let reopened = scratch.store();
    assert_eq!(
        reopened.load::<String>(SecretAccount::AccessCode).unwrap(),
        Some("ABCD1234EFGH".to_string())
    );
}

/// The defect this guards: a corrupt secret read as "absent" means a fresh
/// device key, a new Device ID and a new access code, and every Mac that saved
/// them stops connecting. Damage must be reported, not healed.
#[test]
fn an_unreadable_secret_is_an_error_and_the_bytes_are_left_alone() {
    let scratch = Scratch::new("corrupt");
    let store = scratch.store();
    store
        .save(SecretAccount::GuessCounters, &vec![1u8, 2, 3])
        .unwrap();
    let path = store.path(SecretAccount::GuessCounters);
    let sealed = std::fs::read(&path).unwrap();
    std::fs::write(&path, b"not json, and on Windows not DPAPI either").unwrap();

    let error = store
        .load::<Vec<u8>>(SecretAccount::GuessCounters)
        .expect_err("a damaged secret must not read as absent");
    assert!(matches!(error, SecretError::Unreadable { .. }), "{error}");
    assert_ne!(
        std::fs::read(&path).unwrap(),
        sealed,
        "the test overwrote the file, so this only proves the read did not restore it"
    );
    assert_eq!(
        std::fs::read(&path).unwrap(),
        b"not json, and on Windows not DPAPI either",
        "a failed read must leave the stored bytes untouched"
    );
}

#[test]
fn a_reset_discards_the_identity_secrets_and_keeps_the_owners_settings() {
    let scratch = Scratch::new("reset");
    let store = scratch.store();
    for account in [
        SecretAccount::AccessCode,
        SecretAccount::DeviceToken,
        SecretAccount::TrustedControllers,
        SecretAccount::HostSettings,
    ] {
        store.save(account, &"kept".to_string()).unwrap();
    }
    store.discard_identity().unwrap();
    for account in [
        SecretAccount::AccessCode,
        SecretAccount::DeviceToken,
        SecretAccount::TrustedControllers,
    ] {
        assert!(
            store.load::<String>(account).unwrap().is_none(),
            "{} should be gone",
            account.file_name()
        );
    }
    assert_eq!(
        store.load::<String>(SecretAccount::HostSettings).unwrap(),
        Some("kept".to_string()),
        "unattended access being off is the owner's choice, not part of the identity"
    );
}

#[test]
fn no_temporary_file_is_left_behind_for_another_process_to_read() {
    let scratch = Scratch::new("atomic");
    let store = scratch.store();
    store
        .save(SecretAccount::DeviceToken, &"token".to_string())
        .unwrap();
    let leftovers: Vec<_> = std::fs::read_dir(&scratch.0)
        .unwrap()
        .filter_map(Result::ok)
        .map(|e| e.file_name().to_string_lossy().into_owned())
        .filter(|name| name.ends_with(".tmp"))
        .collect();
    assert!(leftovers.is_empty(), "left behind {leftovers:?}");
}
