use super::*;

struct Scratch(std::path::PathBuf);

impl Scratch {
    fn new(tag: &str) -> Self {
        let path = std::env::temp_dir().join(format!(
            "rc-settings-{tag}-{}-{:?}",
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

fn args(words: &[&str]) -> Vec<String> {
    words.iter().map(|w| w.to_string()).collect()
}

#[test]
fn a_new_install_asks_before_each_connection() {
    let scratch = Scratch::new("default");
    assert!(!HostSettings::load(&scratch.store()).unattended_access);
}

#[test]
fn the_setting_round_trips_in_the_macs_json_shape() {
    let scratch = Scratch::new("roundtrip");
    let store = scratch.store();
    HostSettings { unattended_access: true }.save(&store).unwrap();
    assert!(HostSettings::load(&scratch.store()).unattended_access);
    assert_eq!(
        store.load_blob(SecretAccount::HostSettings).unwrap().unwrap(),
        br#"{"unattendedAccess":true}"#.to_vec()
    );
    HostSettings { unattended_access: false }.save(&store).unwrap();
    assert!(!HostSettings::load(&store).unattended_access);
}

#[test]
fn an_identity_reset_keeps_the_owners_choice() {
    let scratch = Scratch::new("reset");
    let store = scratch.store();
    HostSettings { unattended_access: true }.save(&store).unwrap();
    store.discard_identity().unwrap();
    assert!(HostSettings::load(&store).unattended_access);
}

#[test]
fn an_unreadable_setting_means_asking_and_is_left_in_place() {
    let scratch = Scratch::new("unreadable");
    let store = scratch.store();
    store.save_blob(SecretAccount::HostSettings, b"not json").unwrap();
    assert!(!HostSettings::load(&store).unattended_access);
    assert_eq!(
        store.load_blob(SecretAccount::HostSettings).unwrap().unwrap(),
        b"not json".to_vec()
    );
}

#[test]
fn the_environment_override_is_only_an_explicit_one_or_zero() {
    assert_eq!(unattended_override(Some("1")), Some(true));
    assert_eq!(unattended_override(Some("0")), Some(false));
    for ignored in [None, Some(""), Some("yes"), Some("true")] {
        assert_eq!(unattended_override(ignored), None, "{ignored:?}");
    }
}

#[test]
fn the_unattended_command_takes_on_or_off_and_nothing_else() {
    assert_eq!(unattended_argument(&args(&["--unattended", "on"])), Some(Ok(true)));
    assert_eq!(unattended_argument(&args(&["--unattended", "OFF"])), Some(Ok(false)));
    assert_eq!(unattended_argument(&args(&["--synthetic"])), None);
    for bad in [&["--unattended"][..], &["--unattended", "yes"], &["--unattended", "--synthetic"]] {
        assert!(
            matches!(unattended_argument(&args(bad)), Some(Err(_))),
            "{bad:?} must not change the setting"
        );
    }
}
