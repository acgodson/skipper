//! v5 strict decoding of the relayed signaling messages (`sdp`, `ice`, `pake`).
//!
//! Mirrors `protocol/relay.go`: a payload decodes only into its exact schema — exact-case keys,
//! each once, no `null`, no unknown key, every field within its limits — and a server relays
//! only its own re-encoding. `protocol/vectors/vectors.json` (`relay`) pins both sides.

use serde::{Deserialize, Serialize};
use serde_json::Value;

use crate::consts::{msg, relay as lim};
use crate::envelope::valid_session_id;
use crate::signaling::{Pake, Sdp};

/// The wire form of `ice`: unlike [`crate::signaling::Ice`], an explicit `sdpMLineIndex` of 0
/// survives re-encoding.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Ice {
    #[serde(rename = "sessionId")]
    pub session_id: String,
    pub candidate: String,
    #[serde(rename = "sdpMid", default, skip_serializing_if = "String::is_empty")]
    pub sdp_mid: String,
    #[serde(
        rename = "sdpMLineIndex",
        default,
        skip_serializing_if = "Option::is_none"
    )]
    pub sdp_mline_index: Option<i32>,
}

#[derive(Debug, Clone, PartialEq)]
pub enum Relay {
    Sdp(Sdp),
    Ice(Ice),
    Pake(Pake),
}

#[derive(Debug, thiserror::Error, PartialEq)]
pub enum RelayError {
    #[error("{0:?} is not a relayed type")]
    Type(String),
    #[error("payload is not a JSON object without null members")]
    Shape,
    #[error("payload does not match the schema: {0}")]
    Schema(String),
    #[error("{0} is out of range or malformed")]
    Field(&'static str),
}

impl Relay {
    pub fn session_id(&self) -> &str {
        match self {
            Relay::Sdp(m) => &m.session_id,
            Relay::Ice(m) => &m.session_id,
            Relay::Pake(m) => &m.session_id,
        }
    }

    /// The exact payload text a v5 server relays in place of the input.
    pub fn encode(&self) -> String {
        match self {
            Relay::Sdp(m) => serde_json::to_string(m),
            Relay::Ice(m) => serde_json::to_string(m),
            Relay::Pake(m) => serde_json::to_string(m),
        }
        .expect("relay types always serialize")
    }
}

/// Decodes and validates one relayed payload, given as the raw JSON text of `payload`.
pub fn decode(msg_type: &str, payload: &str) -> Result<Relay, RelayError> {
    let shape: Value = serde_json::from_str(payload).map_err(|_| RelayError::Shape)?;
    match shape.as_object() {
        Some(o) if o.values().all(|v| !v.is_null()) => {}
        _ => return Err(RelayError::Shape),
    }
    let schema = |e: serde_json::Error| RelayError::Schema(e.to_string());
    let relay = match msg_type {
        msg::SDP => Relay::Sdp(serde_json::from_str(payload).map_err(schema)?),
        msg::ICE => Relay::Ice(serde_json::from_str(payload).map_err(schema)?),
        msg::PAKE => Relay::Pake(serde_json::from_str(payload).map_err(schema)?),
        other => return Err(RelayError::Type(other.to_string())),
    };
    if !valid_session_id(relay.session_id()) {
        return Err(RelayError::Field("sessionId"));
    }
    match &relay {
        Relay::Sdp(m) => validate_sdp(m)?,
        Relay::Ice(m) => validate_ice(m)?,
        Relay::Pake(m) => validate_pake(m)?,
    }
    Ok(relay)
}

fn require(ok: bool, field: &'static str) -> Result<(), RelayError> {
    if ok {
        Ok(())
    } else {
        Err(RelayError::Field(field))
    }
}

fn validate_sdp(m: &Sdp) -> Result<(), RelayError> {
    require(lim::SDP_TYPES.contains(&m.sdp_type.as_str()), "sdpType")?;
    require(
        m.sdp.len() <= lim::MAX_SDP_BYTES
            && m.sdp.starts_with(lim::SDP_VERSION_PREFIX)
            && !m.sdp.contains('\0'),
        "sdp",
    )?;
    require(
        m.fp.len() <= lim::MAX_FINGERPRINT_BYTES && all_bytes(&m.fp, is_fingerprint_byte),
        "fp",
    )?;
    require(
        m.pubkey.len() <= lim::MAX_PUBKEY_CHARS && all_bytes(&m.pubkey, is_base64_byte),
        "pubkey",
    )?;
    require(
        m.sig.len() <= lim::MAX_SIG_CHARS && all_bytes(&m.sig, is_base64_byte),
        "sig",
    )?;
    require(
        m.mac.len() <= lim::MAX_MAC_CHARS && all_bytes(&m.mac, is_base64_byte),
        "mac",
    )
}

fn validate_ice(m: &Ice) -> Result<(), RelayError> {
    require(
        m.candidate.is_empty() || valid_ice_candidate(&m.candidate),
        "candidate",
    )?;
    require(
        m.sdp_mid.len() <= lim::MAX_SDP_MID_BYTES && all_bytes(&m.sdp_mid, is_mid_byte),
        "sdpMid",
    )?;
    require(m.sdp_mline_index.is_none_or(|i| i >= 0), "sdpMLineIndex")
}

fn validate_pake(m: &Pake) -> Result<(), RelayError> {
    require(
        (lim::PAKE_STEP_FIRST..=lim::PAKE_STEP_LAST).contains(&m.step),
        "step",
    )?;
    require(
        m.payload.len() <= crate::consts::MAX_PAKE_PAYLOAD_BYTES && valid_padded_base64(&m.payload),
        "payload",
    )
}

/// The §2.13 grammar: `candidate:` foundation SP component SP transport SP priority SP address
/// SP port SP `typ` SP type, then up to 16 SP name SP value pairs.
pub fn valid_ice_candidate(line: &str) -> bool {
    let Some(rest) = line.strip_prefix(lim::CANDIDATE_PREFIX) else {
        return false;
    };
    if line.len() > lim::MAX_CANDIDATE_BYTES {
        return false;
    }
    let f: Vec<&str> = rest.split(' ').collect();
    if f.len() < 8 || (f.len() - 8) % 2 != 0 || (f.len() - 8) / 2 > lim::MAX_CANDIDATE_EXTENSIONS {
        return false;
    }
    let fixed = bounded_token(f[0], 32, is_ice_char)
        && decimal_between(f[1], 3, 1, 256)
        && (f[2].eq_ignore_ascii_case("udp") || f[2].eq_ignore_ascii_case("tcp"))
        && decimal_between(f[3], 10, 0, u32::MAX as u64)
        && valid_candidate_address(f[4])
        && decimal_between(f[5], 5, 0, 65535)
        && f[6] == "typ"
        && lim::CANDIDATE_TYPES.contains(&f[7]);
    fixed
        && f[8..].chunks(2).all(|pair| {
            bounded_token(pair[0], 32, is_ext_name_byte)
                && bounded_token(pair[1], 256, is_ext_value_byte)
        })
}

fn valid_candidate_address(s: &str) -> bool {
    if s.parse::<std::net::IpAddr>().is_ok() {
        return true;
    }
    let Some(name) = s.strip_suffix(".local") else {
        return false;
    };
    name.len() == 36
        && name.bytes().enumerate().all(|(i, c)| {
            if matches!(i, 8 | 13 | 18 | 23) {
                c == b'-'
            } else {
                c.is_ascii_hexdigit()
            }
        })
}

/// Non-empty padded standard base64, checked by shape without decoding.
pub fn valid_padded_base64(s: &str) -> bool {
    let body = s.trim_end_matches('=');
    !s.is_empty() && s.len() % 4 == 0 && s.len() - body.len() <= 2 && all_bytes(body, is_ice_char)
}

fn all_bytes(s: &str, ok: fn(u8) -> bool) -> bool {
    s.bytes().all(ok)
}

fn bounded_token(s: &str, max: usize, ok: fn(u8) -> bool) -> bool {
    !s.is_empty() && s.len() <= max && all_bytes(s, ok)
}

fn decimal_between(s: &str, digits: usize, min: u64, max: u64) -> bool {
    bounded_token(s, digits, |c| c.is_ascii_digit())
        && s.parse::<u64>().is_ok_and(|n| (min..=max).contains(&n))
}

fn is_ice_char(c: u8) -> bool {
    c.is_ascii_alphanumeric() || c == b'+' || c == b'/'
}

fn is_base64_byte(c: u8) -> bool {
    is_ice_char(c) || c == b'='
}

fn is_fingerprint_byte(c: u8) -> bool {
    c.is_ascii_alphanumeric() || b":- \n".contains(&c)
}

fn is_mid_byte(c: u8) -> bool {
    c.is_ascii_alphanumeric() || b"_.+/-".contains(&c)
}

fn is_ext_name_byte(c: u8) -> bool {
    c.is_ascii_digit() || c.is_ascii_lowercase() || c == b'-'
}

fn is_ext_value_byte(c: u8) -> bool {
    c.is_ascii_alphanumeric() || b"+/=.:_-".contains(&c)
}
