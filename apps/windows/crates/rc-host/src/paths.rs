//! Where this PC's host keeps its files: the identity, the sealed secrets and
//! the log, all in one per-user directory.

use std::path::PathBuf;

/// `RC_IDENTITY_DIR` when set, otherwise `SkipperDesk` under the per-user
/// config directory.
pub fn data_directory() -> PathBuf {
    if let Ok(dir) = std::env::var("RC_IDENTITY_DIR") {
        return PathBuf::from(dir);
    }
    config_directory().join("SkipperDesk")
}

/// Minimal per-OS config dir without pulling the `dirs` crate. `LOCALAPPDATA`
/// is preferred over `APPDATA`: a roaming profile would copy this PC's device
/// key to another machine, and two machines with one key fight over the id.
fn config_directory() -> PathBuf {
    #[cfg(windows)]
    {
        for key in ["LOCALAPPDATA", "APPDATA"] {
            if let Ok(dir) = std::env::var(key) {
                return PathBuf::from(dir);
            }
        }
    }
    if let Ok(home) = std::env::var("HOME") {
        return PathBuf::from(home).join(".config");
    }
    std::env::temp_dir()
}

pub fn secrets_directory() -> PathBuf {
    data_directory().join("secrets")
}

pub fn log_file() -> PathBuf {
    data_directory().join("rc-host.log")
}
