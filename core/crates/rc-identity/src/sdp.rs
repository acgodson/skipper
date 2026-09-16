use base64::engine::general_purpose::STANDARD as B64;
use base64::Engine;
use p256::ecdsa::signature::Verifier;
use p256::ecdsa::{DerSignature, VerifyingKey};
use p256::pkcs8::DecodePublicKey;

pub const CONTEXT_LABEL: &str = "skipperdesk/sdp/v1";

const FINGERPRINT_ATTRIBUTE: &str = "a=fingerprint:";

#[derive(Debug, thiserror::Error, PartialEq, Eq)]
pub enum SdpAuthError {
    #[error("the SDP carries no a=fingerprint attribute")]
    NoFingerprint,
    #[error("sessionId and sdpType are required")]
    MissingContext,
    #[error("the signed fingerprints are not the ones in the SDP")]
    FingerprintMismatch,
    #[error("pubkey is not base64 of a P-256 DER SPKI key")]
    BadPubkey,
    #[error("sig is not base64 of an ASN.1 DER signature")]
    BadSignature,
    #[error("the signature does not verify against the presented pubkey")]
    SignatureRejected,
    #[error("the SDP was signed by a device key that is not the expected peer's")]
    UnexpectedPeer,
}

/// De-duplicated, sorted `a=fingerprint` values joined with `\n` — the `fp` field.
pub fn fingerprints(sdp: &str) -> Result<String, SdpAuthError> {
    let mut found: Vec<String> = Vec::new();
    for line in sdp.lines() {
        let line = line.trim_end_matches('\r');
        let Some(value) = line.trim_start().strip_prefix(FINGERPRINT_ATTRIBUTE) else {
            continue;
        };
        let value = value.trim().to_string();
        if !value.is_empty() && !found.contains(&value) {
            found.push(value);
        }
    }
    if found.is_empty() {
        return Err(SdpAuthError::NoFingerprint);
    }
    found.sort();
    Ok(found.join("\n"))
}

/// The bytes the device key signs.
pub fn message_to_sign(
    session_id: &str,
    sdp_type: &str,
    fingerprints: &str,
) -> Result<Vec<u8>, SdpAuthError> {
    if session_id.is_empty() || sdp_type.is_empty() {
        return Err(SdpAuthError::MissingContext);
    }
    if fingerprints.is_empty() {
        return Err(SdpAuthError::NoFingerprint);
    }
    Ok(format!("{CONTEXT_LABEL}|{session_id}|{sdp_type}|{fingerprints}").into_bytes())
}

/// Returns (`fp`, base64 message to sign).
pub fn signing_material(
    session_id: &str,
    sdp_type: &str,
    sdp: &str,
) -> Result<(String, String), SdpAuthError> {
    let fingerprints = fingerprints(sdp)?;
    let message = message_to_sign(session_id, sdp_type, &fingerprints)?;
    Ok((fingerprints, B64.encode(&message)))
}

/// Everything a receiver must check before `setRemoteDescription`.
/// `expected_pubkey_base64` of `None` skips peer-identity pinning.
pub fn verify(
    session_id: &str,
    sdp_type: &str,
    sdp: &str,
    signed_fingerprints: &str,
    pubkey_base64: &str,
    sig_base64: &str,
    expected_pubkey_base64: Option<&str>,
) -> Result<(), SdpAuthError> {
    if signed_fingerprints.is_empty() {
        return Err(SdpAuthError::NoFingerprint);
    }
    if fingerprints(sdp)? != signed_fingerprints {
        return Err(SdpAuthError::FingerprintMismatch);
    }
    if let Some(expected) = expected_pubkey_base64 {
        if !expected.is_empty() && expected != pubkey_base64 {
            return Err(SdpAuthError::UnexpectedPeer);
        }
    }
    let der = B64
        .decode(pubkey_base64.as_bytes())
        .map_err(|_| SdpAuthError::BadPubkey)?;
    let key = VerifyingKey::from_public_key_der(&der).map_err(|_| SdpAuthError::BadPubkey)?;
    let raw_sig = B64
        .decode(sig_base64.as_bytes())
        .map_err(|_| SdpAuthError::BadSignature)?;
    let signature = DerSignature::from_bytes(&raw_sig).map_err(|_| SdpAuthError::BadSignature)?;
    let message = message_to_sign(session_id, sdp_type, signed_fingerprints)?;
    key.verify(&message, &signature)
        .map_err(|_| SdpAuthError::SignatureRejected)
}

#[cfg(test)]
mod tests;
