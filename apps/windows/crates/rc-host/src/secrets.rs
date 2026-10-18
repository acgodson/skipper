//! Persisted secrets, mirroring `SecretStore.swift` account for account. The
//! Mac keeps these in the Keychain; Windows has no Keychain, so each account is
//! one file whose bytes are wrapped by DPAPI (`CryptProtectData`, user scope)
//! and whose directory carries a DACL that names only this user.
//!
//! Three rules the Mac side also holds to, and the reason each is here:
//!
//! 1. **An unreadable secret is never silently regenerated.** A new device key
//!    would mean a new Device ID and a new access code, so every Mac that saved
//!    them stops connecting. [`SecretError::Unreadable`] is returned and the
//!    caller surfaces it; only an explicit reset discards anything.
//! 2. **A failed write is never ignored.** [`SecretStore::save`] returns the
//!    error, so a guess that was counted but not stored cannot be spent twice.
//! 3. **Nothing in here is logged.** The accounts hold the access code, device
//!    tokens and the device private key; [`SecretError`] names the account and
//!    the operating-system failure, never a value.

use std::collections::BTreeMap;
use std::path::{Path, PathBuf};

use serde::de::DeserializeOwned;
use serde::Serialize;

#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord)]
pub enum SecretAccount {
    AccessCode,
    DeviceIdCertificates,
    TrustedControllers,
    GuessCounters,
    DeviceToken,
    PendingUnlink,
    HostSettings,
    /// The `skipperdesk://link` URL the shell handed to a second process, for
    /// the one that is waiting for it. It carries the one-time sign-in code, so
    /// it is sealed like every other secret and removed as soon as it is read.
    LinkCallback,
}

impl SecretAccount {
    pub fn file_name(self) -> &'static str {
        match self {
            Self::AccessCode => "access-code",
            Self::DeviceIdCertificates => "device-id-cert",
            Self::TrustedControllers => "trusted-controllers",
            Self::GuessCounters => "guess-counters",
            Self::DeviceToken => "device-token",
            Self::PendingUnlink => "pending-unlink",
            Self::HostSettings => "host-settings",
            Self::LinkCallback => "link-callback",
        }
    }
}

#[derive(Debug, thiserror::Error)]
pub enum SecretError {
    #[error("the stored {account} could not be read ({detail}); it has NOT been replaced")]
    Unreadable { account: &'static str, detail: String },
    #[error("the {account} could not be saved ({detail})")]
    NotSaved { account: &'static str, detail: String },
    #[error("the secret directory {path} could not be secured ({detail})")]
    NotSecured { path: String, detail: String },
}

impl SecretError {
    fn unreadable(account: SecretAccount, detail: impl std::fmt::Display) -> Self {
        Self::Unreadable {
            account: account.file_name(),
            detail: detail.to_string(),
        }
    }

    fn not_saved(account: SecretAccount, detail: impl std::fmt::Display) -> Self {
        Self::NotSaved {
            account: account.file_name(),
            detail: detail.to_string(),
        }
    }
}

pub struct SecretStore {
    directory: PathBuf,
}

impl SecretStore {
    /// Creates the directory if it is missing and restricts it to this user
    /// before anything is written into it.
    pub fn open(directory: PathBuf) -> Result<Self, SecretError> {
        std::fs::create_dir_all(&directory).map_err(|e| SecretError::NotSecured {
            path: directory.display().to_string(),
            detail: e.to_string(),
        })?;
        restrict_to_current_user(&directory).map_err(|detail| SecretError::NotSecured {
            path: directory.display().to_string(),
            detail,
        })?;
        Ok(Self { directory })
    }

    fn path(&self, account: SecretAccount) -> PathBuf {
        self.directory.join(format!("{}.bin", account.file_name()))
    }

    pub fn load_blob(&self, account: SecretAccount) -> Result<Option<Vec<u8>>, SecretError> {
        let path = self.path(account);
        let sealed = match std::fs::read(&path) {
            Ok(bytes) => bytes,
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Ok(None),
            Err(e) => return Err(SecretError::unreadable(account, e)),
        };
        unseal(&sealed)
            .map(Some)
            .map_err(|detail| SecretError::unreadable(account, detail))
    }

    pub fn save_blob(&self, account: SecretAccount, plaintext: &[u8]) -> Result<(), SecretError> {
        let sealed = seal(plaintext).map_err(|detail| SecretError::not_saved(account, detail))?;
        let path = self.path(account);
        write_atomically(&path, &sealed).map_err(|detail| SecretError::not_saved(account, detail))
    }

    pub fn remove(&self, account: SecretAccount) -> Result<(), SecretError> {
        match std::fs::remove_file(self.path(account)) {
            Ok(()) => Ok(()),
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(()),
            Err(e) => Err(SecretError::not_saved(account, e)),
        }
    }

    pub fn load<T: DeserializeOwned>(
        &self,
        account: SecretAccount,
    ) -> Result<Option<T>, SecretError> {
        let Some(bytes) = self.load_blob(account)? else {
            return Ok(None);
        };
        serde_json::from_slice(&bytes)
            .map(Some)
            .map_err(|e| SecretError::unreadable(account, e))
    }

    pub fn save<T: Serialize>(
        &self,
        account: SecretAccount,
        value: &T,
    ) -> Result<(), SecretError> {
        let bytes =
            serde_json::to_vec(value).map_err(|e| SecretError::not_saved(account, e))?;
        self.save_blob(account, &bytes)
    }

    pub fn map<T: DeserializeOwned>(
        &self,
        account: SecretAccount,
    ) -> Result<BTreeMap<String, T>, SecretError> {
        Ok(self.load(account)?.unwrap_or_default())
    }

    /// Everything an explicit reset discards. `HostSettings` survives, exactly
    /// as `SecretAccount.survivesIdentityReset` has it on the Mac: a reset
    /// changes who this machine is, not whether its owner wanted unattended
    /// access off.
    pub fn discard_identity(&self) -> Result<(), SecretError> {
        for account in [
            SecretAccount::AccessCode,
            SecretAccount::DeviceIdCertificates,
            SecretAccount::TrustedControllers,
            SecretAccount::GuessCounters,
            SecretAccount::DeviceToken,
            SecretAccount::PendingUnlink,
            SecretAccount::LinkCallback,
        ] {
            self.remove(account)?;
        }
        Ok(())
    }
}

/// Temp file in the same directory, then rename: a crash leaves either the old
/// blob or the new one, never a half-written secret.
fn write_atomically(path: &Path, bytes: &[u8]) -> Result<(), String> {
    let temporary = path.with_extension("bin.tmp");
    std::fs::write(&temporary, bytes).map_err(|e| e.to_string())?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        std::fs::set_permissions(&temporary, std::fs::Permissions::from_mode(0o600))
            .map_err(|e| e.to_string())?;
    }
    std::fs::rename(&temporary, path).map_err(|e| e.to_string())
}

#[cfg(windows)]
mod platform {
    use std::os::windows::ffi::OsStrExt;
    use std::path::Path;

    use windows::core::PWSTR;
    use windows::Win32::Foundation::{HANDLE, LocalFree, HLOCAL};
    use windows::Win32::Security::Authorization::{
        ConvertSidToStringSidW, ConvertStringSecurityDescriptorToSecurityDescriptorW,
        SetNamedSecurityInfoW, SDDL_REVISION_1, SE_FILE_OBJECT,
    };
    use windows::Win32::Security::Cryptography::{
        CryptProtectData, CryptUnprotectData, CRYPTPROTECT_UI_FORBIDDEN, CRYPT_INTEGER_BLOB,
    };
    use windows::Win32::Foundation::BOOL;
    use windows::Win32::Security::{
        GetSecurityDescriptorDacl, GetTokenInformation, TokenUser, ACL,
        DACL_SECURITY_INFORMATION, PROTECTED_DACL_SECURITY_INFORMATION, PSECURITY_DESCRIPTOR,
        TOKEN_QUERY, TOKEN_USER,
    };
    use windows::Win32::System::Threading::{GetCurrentProcess, OpenProcessToken};

    fn wide(path: &Path) -> Vec<u16> {
        path.as_os_str()
            .encode_wide()
            .chain(std::iter::once(0))
            .collect()
    }

    fn blob(bytes: &[u8]) -> CRYPT_INTEGER_BLOB {
        CRYPT_INTEGER_BLOB {
            cbData: bytes.len() as u32,
            pbData: bytes.as_ptr() as *mut u8,
        }
    }

    unsafe fn take(out: CRYPT_INTEGER_BLOB) -> Vec<u8> {
        let slice = std::slice::from_raw_parts(out.pbData, out.cbData as usize).to_vec();
        let _ = LocalFree(HLOCAL(out.pbData as *mut _));
        slice
    }

    /// `CryptProtectData` with no entropy and no prompt: the key is the user's
    /// logon credential, so the blob is useless to any other account and to the
    /// same account on another machine.
    pub fn seal(plaintext: &[u8]) -> Result<Vec<u8>, String> {
        let mut input = blob(plaintext);
        let mut output = CRYPT_INTEGER_BLOB::default();
        unsafe {
            CryptProtectData(
                &mut input,
                None,
                None,
                None,
                None,
                CRYPTPROTECT_UI_FORBIDDEN,
                &mut output,
            )
            .map_err(|e| e.message())?;
            Ok(take(output))
        }
    }

    pub fn unseal(sealed: &[u8]) -> Result<Vec<u8>, String> {
        let mut input = blob(sealed);
        let mut output = CRYPT_INTEGER_BLOB::default();
        unsafe {
            CryptUnprotectData(
                &mut input,
                None,
                None,
                None,
                None,
                CRYPTPROTECT_UI_FORBIDDEN,
                &mut output,
            )
            .map_err(|e| e.message())?;
            Ok(take(output))
        }
    }

    fn current_user_sid() -> Result<String, String> {
        unsafe {
            let mut token = HANDLE::default();
            OpenProcessToken(GetCurrentProcess(), TOKEN_QUERY, &mut token)
                .map_err(|e| e.message())?;
            let mut needed = 0u32;
            let _ = GetTokenInformation(token, TokenUser, None, 0, &mut needed);
            let mut buffer = vec![0u8; needed as usize];
            GetTokenInformation(
                token,
                TokenUser,
                Some(buffer.as_mut_ptr() as *mut _),
                needed,
                &mut needed,
            )
            .map_err(|e| e.message())?;
            let user = &*(buffer.as_ptr() as *const TOKEN_USER);
            let mut text = PWSTR::null();
            ConvertSidToStringSidW(user.User.Sid, &mut text).map_err(|e| e.message())?;
            let sid = text.to_string().map_err(|e| e.to_string())?;
            let _ = LocalFree(HLOCAL(text.0 as *mut _));
            Ok(sid)
        }
    }

    /// A protected DACL with exactly two entries — this user and SYSTEM — and
    /// inheritance from the parent switched off, so a secret cannot be read by
    /// another account that happens to be able to reach the path.
    ///
    /// `SetNamedSecurityInfoW` takes an `ACL`, not the `SECURITY_DESCRIPTOR`
    /// that SDDL parses into. Handing it the descriptor is accepted — its
    /// header reads as a well-formed ACL carrying zero entries — and a
    /// protected, empty DACL locks every account out of the directory, so each
    /// save afterwards fails with `Access is denied`. The DACL is extracted
    /// first, and a run that finds a directory already in that state repairs it
    /// here, because the owner keeps `WRITE_DAC` no matter what the DACL says.
    pub fn restrict_to_current_user(directory: &Path) -> Result<(), String> {
        let sid = current_user_sid()?;
        let sddl: Vec<u16> = format!("D:P(A;OICI;FA;;;{sid})(A;OICI;FA;;;SY)")
            .encode_utf16()
            .chain(std::iter::once(0))
            .collect();
        unsafe {
            let mut descriptor = PSECURITY_DESCRIPTOR::default();
            ConvertStringSecurityDescriptorToSecurityDescriptorW(
                windows::core::PCWSTR(sddl.as_ptr()),
                SDDL_REVISION_1,
                &mut descriptor,
                None,
            )
            .map_err(|e| e.message())?;
            let outcome = apply_dacl(directory, descriptor);
            let _ = LocalFree(HLOCAL(descriptor.0));
            outcome
        }
    }

    unsafe fn apply_dacl(directory: &Path, descriptor: PSECURITY_DESCRIPTOR) -> Result<(), String> {
        let mut dacl: *mut ACL = std::ptr::null_mut();
        let mut present = BOOL(0);
        let mut defaulted = BOOL(0);
        GetSecurityDescriptorDacl(descriptor, &mut present, &mut dacl, &mut defaulted)
            .map_err(|e| e.message())?;
        if !present.as_bool() || dacl.is_null() {
            return Err("the security descriptor carried no DACL".to_string());
        }
        let mut path = wide(directory);
        let result = SetNamedSecurityInfoW(
            PWSTR(path.as_mut_ptr()),
            SE_FILE_OBJECT,
            DACL_SECURITY_INFORMATION | PROTECTED_DACL_SECURITY_INFORMATION,
            None,
            None,
            Some(dacl),
            None,
        );
        if result.is_err() {
            return Err(format!("SetNamedSecurityInfoW failed: {result:?}"));
        }
        Ok(())
    }
}

/// The non-Windows build is the diagnostic one. It has no DPAPI, so the blob is
/// stored as-is behind owner-only permissions and is never the shipping path:
/// `--synthetic` is the only configuration that runs here.
#[cfg(not(windows))]
mod platform {
    use std::path::Path;

    pub fn seal(plaintext: &[u8]) -> Result<Vec<u8>, String> {
        Ok(plaintext.to_vec())
    }

    pub fn unseal(sealed: &[u8]) -> Result<Vec<u8>, String> {
        Ok(sealed.to_vec())
    }

    pub fn restrict_to_current_user(directory: &Path) -> Result<(), String> {
        use std::os::unix::fs::PermissionsExt;
        std::fs::set_permissions(directory, std::fs::Permissions::from_mode(0o700))
            .map_err(|e| e.to_string())
    }
}

use platform::{restrict_to_current_user, seal, unseal};

#[cfg(test)]
mod tests;
