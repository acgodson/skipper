//! The owner's host settings, mirroring the Mac's `HostSettings`. They live in
//! [`SecretAccount::HostSettings`] with the Mac's JSON shape,
//! `{"unattendedAccess": …}`, and survive an identity reset there exactly as
//! they do on the Mac: a reset changes who this PC is, not what its owner chose.
//!
//! Unattended access means what it means on the Mac and nothing more: when it
//! is on, any controller that proves the access code connects without anybody
//! at this PC being asked. There is no trusted-only variant.

use serde::{Deserialize, Serialize};

use crate::secrets::{SecretAccount, SecretError, SecretStore};

#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct HostSettings {
    #[serde(rename = "unattendedAccess")]
    pub unattended_access: bool,
}

impl HostSettings {
    /// Off on a new install, and off when the stored value cannot be read: a
    /// setting nobody can read is never a reason to stop asking the owner.
    pub fn load(secrets: &SecretStore) -> Self {
        match secrets.load(SecretAccount::HostSettings) {
            Ok(stored) => stored.unwrap_or_default(),
            Err(e) => {
                crate::report!("{e}; asking before each connection");
                Self::default()
            }
        }
    }

    pub fn save(self, secrets: &SecretStore) -> Result<(), SecretError> {
        secrets.save(SecretAccount::HostSettings, &self)
    }
}

/// Every surface that changes the setting saves it here: `--unattended`, the
/// window, and the consent answer that turns it on.
pub fn save_unattended(secrets: &SecretStore, on: bool) -> Result<(), String> {
    HostSettings { unattended_access: on }
        .save(secrets)
        .map_err(|e| e.to_string())
}

/// `RC_UNATTENDED=1|0`, a diagnostic override of the persisted setting for one
/// run. Anything else, or nothing, leaves the persisted setting in charge.
pub fn unattended_override(value: Option<&str>) -> Option<bool> {
    match value?.trim() {
        "1" => Some(true),
        "0" => Some(false),
        _ => None,
    }
}

/// `--unattended on|off`. `None` when the flag is absent; an error when it is
/// present without a word this understands, so a typo never flips the setting.
pub fn unattended_argument(args: &[String]) -> Option<Result<bool, String>> {
    let index = args.iter().position(|a| a == "--unattended")?;
    let word = args.get(index + 1).map(|w| w.trim().to_ascii_lowercase());
    Some(match word.as_deref() {
        Some("on") => Ok(true),
        Some("off") => Ok(false),
        _ => Err("use  --unattended on  or  --unattended off".to_string()),
    })
}

/// The window's toggle detail, in the Mac's words.
pub fn unattended_detail(on: bool) -> &'static str {
    match on {
        true => "Anyone with the code can connect without being asked here.",
        false => "You will be asked to allow each connection.",
    }
}

/// Shown in the window while unattended access is off, as on the Mac.
pub const UNATTENDED_OFF_NOTE: &str = "Leaving this PC on its own? Turn on Unattended access below so connections do not wait for someone to click Allow.";

/// The one sentence every surface uses for the setting: the launch panel, the
/// `--unattended` command, and the answer `t` to a consent prompt.
pub fn unattended_line(on: bool) -> String {
    let meaning = match on {
        true => "on — anyone with this PC's access code connects without asking",
        false => "off — each connection asks whoever is at this PC",
    };
    format!("Unattended access  {meaning}")
}

#[cfg(test)]
mod tests;
