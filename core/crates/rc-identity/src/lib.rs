//! Device identity: file-based, mirrors the Mac app's `IdentityFileStore.swift`
//! schema. No OS keychain.

use base64::engine::general_purpose::STANDARD as B64;
use base64::Engine;
use p256::ecdsa::signature::Signer;
use p256::ecdsa::{DerSignature, SigningKey};
use p256::pkcs8::EncodePublicKey;
use rand_core::{OsRng, RngCore};
use rc_proto::signaling::CodeVerifier;
use serde::{Deserialize, Serialize};

pub mod pake;
pub mod sdp;
pub mod signing;

pub use signing::{signing_message, SigningError, SigningPurpose};

/// Crockford base32 alphabet.
pub const CROCKFORD: &[u8; 32] = b"0123456789ABCDEFGHJKMNPQRSTVWXYZ";

pub mod access_code {
    use super::*;

    pub const LENGTH: usize = 12;
    pub const GROUP: usize = 4;

    pub fn generate() -> String {
        let mut bytes = [0u8; LENGTH];
        OsRng.fill_bytes(&mut bytes);
        bytes
            .iter()
            .map(|b| CROCKFORD[(b & 0x1F) as usize] as char)
            .collect()
    }

    /// The exact byte string the PAKE uses as its password.
    pub fn normalize(input: &str) -> String {
        input
            .chars()
            .filter(|c| !matches!(c, '-' | ' ' | '\t' | '\n' | '\r'))
            .map(|c| match c.to_ascii_uppercase() {
                'I' | 'L' => '1',
                'O' => '0',
                other => other,
            })
            .collect()
    }

    pub fn canonicalize(input: &str) -> Option<String> {
        let compact = normalize(input);
        let legal = compact.len() == LENGTH && compact.bytes().all(|b| CROCKFORD.contains(&b));
        legal.then_some(compact)
    }

    pub fn formatted_device_id(id: &str) -> String {
        id.as_bytes()
            .chunks(3)
            .map(|c| std::str::from_utf8(c).unwrap_or_default())
            .collect::<Vec<_>>()
            .join(" ")
    }

    pub fn formatted(code: &str) -> String {
        code.as_bytes()
            .chunks(GROUP)
            .map(|c| std::str::from_utf8(c).unwrap_or_default())
            .collect::<Vec<_>>()
            .join("-")
    }
}

pub fn build_verifier(plaintext_code: &str) -> CodeVerifier {
    let mut salt = [0u8; 16];
    OsRng.fill_bytes(&mut salt);
    build_verifier_with_salt(plaintext_code, &salt)
}

pub fn build_verifier_with_salt(plaintext_code: &str, salt: &[u8]) -> CodeVerifier {
    let params = argon2::Params::new(
        CodeVerifier::REC_MEM_KIB,
        CodeVerifier::REC_TIME,
        u32::from(CodeVerifier::REC_PAR),
        Some(CodeVerifier::REC_LEN as usize),
    )
    .expect("recommended Argon2 parameters are valid");
    let argon = argon2::Argon2::new(argon2::Algorithm::Argon2id, argon2::Version::V0x13, params);
    let mut hash = vec![0u8; CodeVerifier::REC_LEN as usize];
    argon
        .hash_password_into(plaintext_code.as_bytes(), salt, &mut hash)
        .expect("argon2id hashing cannot fail with valid parameters");
    CodeVerifier {
        alg: rc_proto::consts::ALG_ARGON2ID.to_string(),
        salt: B64.encode(salt),
        hash: B64.encode(&hash),
        time: CodeVerifier::REC_TIME,
        mem_kib: CodeVerifier::REC_MEM_KIB,
        par: CodeVerifier::REC_PAR,
        len: CodeVerifier::REC_LEN,
    }
}

/// The raw 32-byte scalar is what the identity file stores.
pub struct DeviceKey {
    signing: SigningKey,
}

#[derive(Debug, thiserror::Error)]
pub enum IdentityError {
    #[error("identity file {0}: {1}")]
    Corrupt(String, String),
    #[error("io: {0}")]
    Io(#[from] std::io::Error),
}

impl DeviceKey {
    pub fn generate() -> Self {
        Self {
            signing: SigningKey::random(&mut OsRng),
        }
    }

    pub fn from_raw(raw32: &[u8]) -> Result<Self, IdentityError> {
        SigningKey::from_slice(raw32)
            .map(|signing| Self { signing })
            .map_err(|e| IdentityError::Corrupt("privateKey".into(), e.to_string()))
    }

    pub fn raw_private_key(&self) -> Vec<u8> {
        self.signing.to_bytes().to_vec()
    }

    /// base64 of the DER SPKI encoding — the wire `pubkey` field.
    pub fn public_key_spki_base64(&self) -> String {
        let der = self
            .signing
            .verifying_key()
            .to_public_key_der()
            .expect("SPKI encoding of a valid P-256 key cannot fail");
        B64.encode(der.as_bytes())
    }

    /// base64 of the ASN.1 DER ECDSA-SHA256 signature over
    /// [`signing_message`]`(purpose, payload)`; nothing else is ever signed.
    pub fn sign(&self, purpose: SigningPurpose, payload: &[u8]) -> Result<String, SigningError> {
        let message = signing_message(purpose, payload)?;
        let sig: DerSignature = self.signing.sign(&message);
        Ok(B64.encode(sig.as_bytes()))
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct IdentityRecord {
    #[serde(rename = "schemaVersion")]
    pub schema_version: i32,
    #[serde(rename = "deviceId")]
    pub device_id: String,
    #[serde(rename = "accessCode")]
    pub access_code: String,
    /// base64 of the raw 32-byte P-256 private scalar.
    #[serde(rename = "privateKey")]
    pub private_key: String,
    #[serde(rename = "createdAt")]
    pub created_at: String,
    #[serde(rename = "serverRegistered")]
    pub server_registered: bool,
}

pub const SCHEMA_VERSION: i32 = 1;

impl IdentityRecord {
    pub fn new_unregistered(key: &DeviceKey, access_code: String, created_at: String) -> Self {
        Self {
            schema_version: SCHEMA_VERSION,
            device_id: String::new(),
            access_code,
            private_key: B64.encode(key.raw_private_key()),
            created_at,
            server_registered: false,
        }
    }

    pub fn device_key(&self) -> Result<DeviceKey, IdentityError> {
        let raw = B64
            .decode(&self.private_key)
            .map_err(|e| IdentityError::Corrupt("privateKey".into(), e.to_string()))?;
        DeviceKey::from_raw(&raw)
    }

    pub fn load(path: &std::path::Path) -> Result<Self, IdentityError> {
        let bytes = std::fs::read(path)?;
        let record: Self = serde_json::from_slice(&bytes)
            .map_err(|e| IdentityError::Corrupt(path.display().to_string(), e.to_string()))?;
        if record.schema_version != SCHEMA_VERSION {
            return Err(IdentityError::Corrupt(
                path.display().to_string(),
                format!("unsupported schemaVersion {}", record.schema_version),
            ));
        }
        Ok(record)
    }

    /// Atomic write (temp + rename), owner-only permissions on Unix.
    pub fn save(&self, path: &std::path::Path) -> Result<(), IdentityError> {
        if let Some(dir) = path.parent() {
            std::fs::create_dir_all(dir)?;
        }
        let tmp = path.with_extension("json.tmp");
        let bytes = serde_json::to_vec_pretty(self)
            .map_err(|e| IdentityError::Corrupt(path.display().to_string(), e.to_string()))?;
        std::fs::write(&tmp, &bytes)?;
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            std::fs::set_permissions(&tmp, std::fs::Permissions::from_mode(0o600))?;
        }
        std::fs::rename(&tmp, path)?;
        Ok(())
    }
}
