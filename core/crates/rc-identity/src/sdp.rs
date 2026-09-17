use base64::engine::general_purpose::STANDARD as B64;
use base64::Engine;
use hkdf::Hkdf;
use hmac::{Hmac, Mac};
use rc_session::input::{self, InputError};
use sha2::Sha256;

use crate::signing::{self, signing_message, SigningPurpose, VerifyError};

pub const MAC_KEY_INFO: &str = "skipperdesk/sdp-mac/v1";
pub const MAC_KEY_LEN: usize = 32;

const FINGERPRINT_ATTRIBUTE: &str = "a=fingerprint:";
const CANDIDATE_ATTRIBUTE: &str = "a=candidate";
const END_OF_CANDIDATES: &str = "a=end-of-candidates";

type HmacSha256 = Hmac<Sha256>;

#[derive(Debug, thiserror::Error, PartialEq, Eq)]
pub enum SdpAuthError {
    #[error("the SDP carries no a=fingerprint attribute")]
    NoFingerprint,
    #[error("the SDP contains a NUL byte or a carriage return that does not end a line")]
    MalformedSdp,
    #[error("sessionId and sdpType are required")]
    MissingContext,
    #[error("{0}")]
    BadContext(InputError),
    #[error("the expected peer key is missing or is not a canonical P-256 key")]
    NoExpectedPeer,
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
    #[error("the sdp carries no mac")]
    MissingMac,
    #[error("the mac does not match the access-code exchange of this session")]
    MacRejected,
}

impl From<VerifyError> for SdpAuthError {
    fn from(error: VerifyError) -> Self {
        match error {
            VerifyError::BadPubkey => SdpAuthError::BadPubkey,
            VerifyError::BadSignature => SdpAuthError::BadSignature,
            VerifyError::SignatureRejected => SdpAuthError::SignatureRejected,
            VerifyError::Message(_) => SdpAuthError::MissingContext,
        }
    }
}

/// A NUL, or a CR that is not part of CRLF, is where two SDP parsers can
/// disagree about which lines exist; such an SDP is never interpreted.
pub fn require_well_formed(sdp: &str) -> Result<(), SdpAuthError> {
    let bytes = sdp.as_bytes();
    let malformed = bytes.iter().enumerate().any(|(index, byte)| match byte {
        0 => true,
        b'\r' => bytes.get(index + 1) != Some(&b'\n'),
        _ => false,
    });
    if malformed {
        Err(SdpAuthError::MalformedSdp)
    } else {
        Ok(())
    }
}

/// De-duplicated, sorted `a=fingerprint` values joined with `\n` — the `fp` field.
pub fn fingerprints(sdp: &str) -> Result<String, SdpAuthError> {
    require_well_formed(sdp)?;
    let mut found: Vec<String> = Vec::new();
    for line in sdp.lines() {
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

/// `sessionId "|" sdpType "|" fp` — the `sdp`-purpose payload.
pub fn payload(
    session_id: &str,
    sdp_type: &str,
    fingerprints: &str,
) -> Result<Vec<u8>, SdpAuthError> {
    if session_id.is_empty() || sdp_type.is_empty() {
        return Err(SdpAuthError::MissingContext);
    }
    input::session_id(session_id)
        .and_then(|_| input::sdp_type(sdp_type))
        .map_err(SdpAuthError::BadContext)?;
    if fingerprints.is_empty() {
        return Err(SdpAuthError::NoFingerprint);
    }
    Ok(format!("{session_id}|{sdp_type}|{fingerprints}").into_bytes())
}

/// The bytes the device key signs and the PAKE key MACs.
pub fn message_to_sign(
    session_id: &str,
    sdp_type: &str,
    fingerprints: &str,
) -> Result<Vec<u8>, SdpAuthError> {
    let payload = payload(session_id, sdp_type, fingerprints)?;
    signing_message(SigningPurpose::Sdp, &payload).map_err(|_| SdpAuthError::MissingContext)
}

pub fn mac_key(session_key: &[u8]) -> [u8; MAC_KEY_LEN] {
    let hkdf = Hkdf::<Sha256>::new(None, session_key);
    let mut key = [0u8; MAC_KEY_LEN];
    hkdf.expand(MAC_KEY_INFO.as_bytes(), &mut key)
        .expect("32 bytes is a legal HKDF-SHA256 output length");
    key
}

fn mac_over(mac_key: &[u8; MAC_KEY_LEN], message: &[u8]) -> HmacSha256 {
    let mut mac = HmacSha256::new_from_slice(mac_key).expect("HMAC accepts any key length");
    mac.update(message);
    mac
}

pub fn mac_base64(mac_key: &[u8; MAC_KEY_LEN], message: &[u8]) -> String {
    B64.encode(mac_over(mac_key, message).finalize().into_bytes())
}

pub struct Signable {
    pub fingerprints: String,
    pub message: Vec<u8>,
    pub mac: String,
}

pub fn signable(
    mac_key: &[u8; MAC_KEY_LEN],
    session_id: &str,
    sdp_type: &str,
    sdp: &str,
) -> Result<Signable, SdpAuthError> {
    let fingerprints = fingerprints(sdp)?;
    let message = message_to_sign(session_id, sdp_type, &fingerprints)?;
    let mac = mac_base64(mac_key, &message);
    Ok(Signable {
        fingerprints,
        message,
        mac,
    })
}

pub struct Presented<'a> {
    pub fingerprints: &'a str,
    pub pubkey: &'a str,
    pub sig: &'a str,
    pub mac: &'a str,
}

/// Everything a receiver must check before `setRemoteDescription`. The peer
/// key is always pinned: the MAC key is the same in both directions, so the
/// pin is what stops an SDP being reflected back to its sender.
pub fn verify(
    mac_key: &[u8; MAC_KEY_LEN],
    session_id: &str,
    sdp_type: &str,
    sdp: &str,
    presented: &Presented<'_>,
    expected_pubkey_base64: &str,
) -> Result<(), SdpAuthError> {
    if presented.fingerprints.is_empty() {
        return Err(SdpAuthError::NoFingerprint);
    }
    if fingerprints(sdp)? != presented.fingerprints {
        return Err(SdpAuthError::FingerprintMismatch);
    }
    signing::require_canonical_public_key(expected_pubkey_base64)
        .map_err(|_| SdpAuthError::NoExpectedPeer)?;
    signing::require_canonical_public_key(presented.pubkey)?;
    if expected_pubkey_base64 != presented.pubkey {
        return Err(SdpAuthError::UnexpectedPeer);
    }
    let message = message_to_sign(session_id, sdp_type, presented.fingerprints)?;
    if presented.mac.is_empty() {
        return Err(SdpAuthError::MissingMac);
    }
    let presented_mac = B64
        .decode(presented.mac.as_bytes())
        .map_err(|_| SdpAuthError::MacRejected)?;
    mac_over(mac_key, &message)
        .verify_slice(&presented_mac)
        .map_err(|_| SdpAuthError::MacRejected)?;
    let payload = payload(session_id, sdp_type, presented.fingerprints)?;
    signing::verify(
        SigningPurpose::Sdp,
        &payload,
        presented.pubkey,
        presented.sig,
    )
    .map_err(SdpAuthError::from)
}

/// The SDP a receiver hands to `setRemoteDescription`: every candidate line
/// removed, because candidates arrive only as `ice` messages, after the
/// installed fingerprints have been re-checked.
pub fn without_candidates(sdp: &str) -> Result<String, SdpAuthError> {
    require_well_formed(sdp)?;
    Ok(sdp
        .split_inclusive('\n')
        .filter(|line| {
            let attribute = line.trim_start();
            !attribute.starts_with(CANDIDATE_ATTRIBUTE) && attribute.trim_end() != END_OF_CANDIDATES
        })
        .collect())
}

#[cfg(test)]
mod tests;
