//! The one construction of every byte string a device key signs:
//! `"skipperdesk/" purpose "/v1|" ‖ payload`. A signature made for one purpose
//! never verifies for another, so a server that chooses a challenge nonce
//! cannot harvest a signature that means anything else.

use base64::engine::general_purpose::STANDARD as B64;
use base64::Engine;
use p256::ecdsa::signature::Verifier;
use p256::ecdsa::{DerSignature, VerifyingKey};
use p256::pkcs8::{DecodePublicKey, EncodePublicKey};

pub const NONCE_LEN: usize = 32;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SigningPurpose {
    Hello,
    Register,
    Sdp,
    ApiChallenge,
}

#[derive(Debug, thiserror::Error, PartialEq, Eq)]
pub enum SigningError {
    #[error("a {purpose} nonce must be exactly {NONCE_LEN} bytes, got {len}")]
    BadNonceLength { purpose: &'static str, len: usize },
    #[error("an sdp signing payload must not be empty")]
    EmptyPayload,
    #[error("unknown signing purpose {0}")]
    UnknownPurpose(i32),
}

impl SigningPurpose {
    pub const ALL: [SigningPurpose; 4] = [
        SigningPurpose::Hello,
        SigningPurpose::Register,
        SigningPurpose::Sdp,
        SigningPurpose::ApiChallenge,
    ];

    pub fn label(self) -> &'static str {
        match self {
            SigningPurpose::Hello => "hello",
            SigningPurpose::Register => "register",
            SigningPurpose::Sdp => "sdp",
            SigningPurpose::ApiChallenge => "api-challenge",
        }
    }

    pub fn code(self) -> i32 {
        match self {
            SigningPurpose::Hello => 0,
            SigningPurpose::Register => 1,
            SigningPurpose::Sdp => 2,
            SigningPurpose::ApiChallenge => 3,
        }
    }

    pub fn from_code(code: i32) -> Result<Self, SigningError> {
        Self::ALL
            .into_iter()
            .find(|purpose| purpose.code() == code)
            .ok_or(SigningError::UnknownPurpose(code))
    }

    pub fn takes_nonce(self) -> bool {
        !matches!(self, SigningPurpose::Sdp)
    }

    pub fn prefix(self) -> String {
        format!("skipperdesk/{}/v1|", self.label())
    }
}

pub fn signing_message(purpose: SigningPurpose, payload: &[u8]) -> Result<Vec<u8>, SigningError> {
    if purpose.takes_nonce() && payload.len() != NONCE_LEN {
        return Err(SigningError::BadNonceLength {
            purpose: purpose.label(),
            len: payload.len(),
        });
    }
    if payload.is_empty() {
        return Err(SigningError::EmptyPayload);
    }
    let prefix = purpose.prefix();
    let mut message = Vec::with_capacity(prefix.len() + payload.len());
    message.extend_from_slice(prefix.as_bytes());
    message.extend_from_slice(payload);
    Ok(message)
}

#[derive(Debug, thiserror::Error, PartialEq, Eq)]
pub enum VerifyError {
    #[error("pubkey is not base64 of a P-256 DER SPKI key")]
    BadPubkey,
    #[error("sig is not base64 of an ASN.1 DER signature")]
    BadSignature,
    #[error("the signature does not verify against the presented pubkey")]
    SignatureRejected,
    #[error(transparent)]
    Message(#[from] SigningError),
}

/// The one spelling of a device key: base64 of the DER SPKI encoding of a
/// valid P-256 point, as [`crate::DeviceKey::public_key_spki_base64`] writes it.
pub fn canonical_public_key(pubkey_base64: &str) -> Result<String, VerifyError> {
    let canonical = parse_public_key(pubkey_base64)?
        .to_public_key_der()
        .map_err(|_| VerifyError::BadPubkey)?;
    Ok(B64.encode(canonical.as_bytes()))
}

/// Refuses any spelling of a key other than its canonical one.
pub fn require_canonical_public_key(pubkey_base64: &str) -> Result<(), VerifyError> {
    match canonical_public_key(pubkey_base64)? == pubkey_base64 {
        true => Ok(()),
        false => Err(VerifyError::BadPubkey),
    }
}

fn parse_public_key(pubkey_base64: &str) -> Result<VerifyingKey, VerifyError> {
    let der = B64
        .decode(pubkey_base64.as_bytes())
        .map_err(|_| VerifyError::BadPubkey)?;
    VerifyingKey::from_public_key_der(&der).map_err(|_| VerifyError::BadPubkey)
}

pub fn verify(
    purpose: SigningPurpose,
    payload: &[u8],
    pubkey_base64: &str,
    sig_base64: &str,
) -> Result<(), VerifyError> {
    let message = signing_message(purpose, payload)?;
    let key = parse_public_key(pubkey_base64)?;
    let raw_sig = B64
        .decode(sig_base64.as_bytes())
        .map_err(|_| VerifyError::BadSignature)?;
    let signature = DerSignature::from_bytes(&raw_sig).map_err(|_| VerifyError::BadSignature)?;
    key.verify(&message, &signature)
        .map_err(|_| VerifyError::SignatureRejected)
}

#[cfg(test)]
pub(crate) mod tests;
