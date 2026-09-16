//! Signed SDP fingerprints, PROTOCOL.md §2.12.
//!
//! WebRTC is already end-to-end encrypted against anyone who is not the
//! signaling server. The server is the hole: it relays `sdp`, so it could
//! replace the DTLS fingerprint with one of its own, terminate DTLS on both
//! sides and read the desktop. Signing the fingerprint with the device key
//! closes that hole, because the server has neither device key.
//!
//! What is signed:
//!
//! ```text
//! fp      = every `a=fingerprint:` value in the SDP, de-duplicated, sorted,
//!           joined with "\n"
//! message = "skipperdesk/sdp/v1|" sessionId "|" sdpType "|" fp
//! sig     = ECDSA-P256/SHA-256 over `message`, ASN.1 DER, base64
//! ```
//!
//! The `sessionId` binds the signature to one session, so a captured offer
//! cannot be replayed into another one, and `sdpType` stops an offer being
//! replayed as an answer.
//!
//! Signing is **not** here: the device key may live in the Secure Enclave,
//! where the private half never leaves the chip and only the platform can
//! reach it. This module builds the bytes to sign and verifies what arrives —
//! both pure, both identical on every platform.

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

/// Every `a=fingerprint` value in `sdp`, de-duplicated, sorted and joined with
/// `\n` — the exact `fp` field of a `sdp` message.
///
/// libwebrtc repeats one fingerprint per m-line, so de-duplication is what
/// keeps `fp` stable as m-lines come and go; sorting removes the line order,
/// which a renegotiation is free to change.
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

/// The bytes the device key signs. The platform hands these to its own signer,
/// which is the only thing that can reach a Secure Enclave key.
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

/// The two things a sender needs for one `sdp` message: the `fp` field, and the
/// bytes to hand its own signer, base64 so they survive the FFI as text.
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
///
/// `expected_pubkey` is the peer's key as this side already knows it — the
/// controller's, learned in the `pake` exchange, or the host's, learned in
/// `connect_ok`. `None` means this side has not learned it yet, and only the
/// signature and the fingerprint binding are checked.
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
