use super::*;

struct Scratch(std::path::PathBuf);

impl Scratch {
    fn new(tag: &str) -> Self {
        let path = std::env::temp_dir().join(format!(
            "rc-urlhandler-{tag}-{}-{:?}",
            std::process::id(),
            std::thread::current().id()
        ));
        let _ = std::fs::remove_dir_all(&path);
        Self(path)
    }

    fn secrets(&self) -> SecretStore {
        SecretStore::open(self.0.clone()).unwrap()
    }
}

impl Drop for Scratch {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}

const CALLBACK: &str = "skipperdesk://link?code=ABC123&nonce=Zm9vYmFyYmF6";

/// The two processes the Windows shell creates have to meet, and the thing
/// they pass carries a one-time sign-in code.
#[test]
fn a_callback_reaches_the_waiting_process_exactly_once() {
    let scratch = Scratch::new("handoff");
    let delivering = scratch.secrets();
    let waiting = scratch.secrets();

    assert_eq!(take(&waiting), None, "nothing is waiting before it arrives");
    deliver(&delivering, CALLBACK).unwrap();
    assert_eq!(take(&waiting).as_deref(), Some(CALLBACK));
    assert_eq!(
        take(&waiting),
        None,
        "a code read once must not be readable again"
    );
}

/// A code left on disk is a code a later sign-in could redeem, so the URL is
/// sealed like any other secret and the file is gone once it is read.
#[test]
fn the_callback_is_not_left_in_plain_sight() {
    let scratch = Scratch::new("sealed");
    let secrets = scratch.secrets();
    deliver(&secrets, CALLBACK).unwrap();

    let path = scratch.0.join("link-callback.bin");
    assert!(path.exists());
    #[cfg(windows)]
    assert!(
        !std::fs::read(&path).unwrap().windows(6).any(|w| w == b"ABC123"),
        "DPAPI must have sealed the code"
    );

    assert!(take(&secrets).is_some());
    assert!(!path.exists(), "the code must not outlive its hand-off");
}
