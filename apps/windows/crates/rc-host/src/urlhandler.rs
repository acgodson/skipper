//! The `skipperdesk://` return handler, and the browser hand-off it needs.
//!
//! The Mac registers the scheme in its bundle's `Info.plist` and receives the
//! URL in-process. Windows registers it in the registry and the shell launches
//! a **second** process with the URL as an argument, so the two have to meet.
//!
//! They meet through one sealed secret: the second process writes the URL to
//! [`SecretAccount::LinkCallback`] and exits; the one that is waiting reads it
//! and removes it at once. The URL carries the one-time sign-in code, so it is
//! DPAPI-sealed in the same user-only directory as the device token, lives for
//! at most the seconds between the two processes, and is never logged.
//!
//! `HKCU` and not `HKLM`: registering per-user needs no elevation and keeps the
//! handler pointing at the executable the user actually ran.

#[cfg(windows)]
use crate::account::CALLBACK_SCHEME;
use crate::secrets::{SecretAccount, SecretStore};

/// Hands a callback URL to the process that is waiting for it.
pub fn deliver(secrets: &SecretStore, url: &str) -> Result<(), String> {
    secrets
        .save_blob(SecretAccount::LinkCallback, url.as_bytes())
        .map_err(|e| e.to_string())
}

/// Takes the callback URL, if one has arrived. Removing it on the way out is
/// what stops a stale code being redeemed by the next sign-in attempt.
pub fn take(secrets: &SecretStore) -> Option<String> {
    let blob = secrets.load_blob(SecretAccount::LinkCallback).ok().flatten();
    if blob.is_some() {
        if let Err(e) = secrets.remove(SecretAccount::LinkCallback) {
            eprintln!("rc-host: {e}");
        }
    }
    String::from_utf8(blob?).ok()
}

/// Opens the sign-in page in the user's own browser.
pub fn open_in_browser(url: &str) -> Result<(), String> {
    #[cfg(windows)]
    let mut command = {
        // `start` is a cmd builtin, and its first quoted argument is taken as
        // a window title — hence the empty one.
        let mut command = std::process::Command::new("cmd");
        command.args(["/C", "start", "", url]);
        command
    };
    #[cfg(target_os = "macos")]
    let mut command = {
        let mut command = std::process::Command::new("open");
        command.arg(url);
        command
    };
    #[cfg(all(not(windows), not(target_os = "macos")))]
    let mut command = {
        let mut command = std::process::Command::new("xdg-open");
        command.arg(url);
        command
    };

    command
        .status()
        .map_err(|e| e.to_string())
        .and_then(|status| match status.success() {
            true => Ok(()),
            false => Err(format!("the browser could not be opened ({status})")),
        })
}

/// Registers this executable as the handler for `skipperdesk://`, replacing
/// whatever was there: the path changes whenever the host is moved or updated,
/// and a handler pointing at a path that no longer exists silently breaks
/// sign-in.
#[cfg(windows)]
pub fn register(executable: &std::path::Path) -> Result<(), String> {
    use windows::core::{w, HSTRING, PCWSTR};
    use windows::Win32::Foundation::ERROR_SUCCESS;
    use windows::Win32::System::Registry::{
        RegCloseKey, RegCreateKeyExW, RegSetValueExW, HKEY, HKEY_CURRENT_USER, KEY_WRITE,
        REG_OPTION_NON_VOLATILE, REG_SZ,
    };

    let command = format!("\"{}\" --link-callback \"%1\"", executable.display());
    let entries: [(HSTRING, Option<&str>, String); 4] = [
        (
            HSTRING::from(format!("Software\\Classes\\{CALLBACK_SCHEME}")),
            None,
            format!("URL:SkipperDesk ({CALLBACK_SCHEME})"),
        ),
        (
            HSTRING::from(format!("Software\\Classes\\{CALLBACK_SCHEME}")),
            Some("URL Protocol"),
            String::new(),
        ),
        (
            HSTRING::from(format!(
                "Software\\Classes\\{CALLBACK_SCHEME}\\DefaultIcon"
            )),
            None,
            format!("\"{}\",0", executable.display()),
        ),
        (
            HSTRING::from(format!(
                "Software\\Classes\\{CALLBACK_SCHEME}\\shell\\open\\command"
            )),
            None,
            command,
        ),
    ];

    for (path, name, value) in entries {
        unsafe {
            let mut key = HKEY::default();
            let opened = RegCreateKeyExW(
                HKEY_CURRENT_USER,
                PCWSTR(path.as_ptr()),
                0,
                PCWSTR::null(),
                REG_OPTION_NON_VOLATILE,
                KEY_WRITE,
                None,
                &mut key,
                None,
            );
            if opened != ERROR_SUCCESS {
                return Err(format!("{path} could not be created ({opened:?})"));
            }
            let wide: Vec<u16> = value.encode_utf16().chain(std::iter::once(0)).collect();
            let bytes = std::slice::from_raw_parts(
                wide.as_ptr() as *const u8,
                std::mem::size_of_val(&wide[..]),
            );
            let named = name.map(HSTRING::from);
            let set = RegSetValueExW(
                key,
                match &named {
                    Some(name) => PCWSTR(name.as_ptr()),
                    None => w!(""),
                },
                0,
                REG_SZ,
                Some(bytes),
            );
            let _ = RegCloseKey(key);
            if set != ERROR_SUCCESS {
                return Err(format!("{path} could not be written ({set:?})"));
            }
        }
    }
    Ok(())
}

/// There is no system-wide URL handler to register on the diagnostic build, so
/// `--link-callback` is the whole hand-off here and is invoked by hand.
#[cfg(not(windows))]
pub fn register(_executable: &std::path::Path) -> Result<(), String> {
    Ok(())
}

#[cfg(test)]
mod tests;
