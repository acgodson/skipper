//! The exact shape of a relayed `sdp`, `ice` or `pake` payload (protocol v5),
//! the same grammar a v5 server applies before it re-encodes a payload. A
//! client refuses anything else before a field reaches the exchange, the peer
//! connection or a log.
// TODO: once the server v5 branch lands, check frames with rc_proto::relay::decode and delete this module.

use std::fmt;
use std::ops::RangeInclusive;

pub const PAKE_STEPS: RangeInclusive<i64> = 1..=3;
pub const PAKE_PAYLOAD_MAX_BASE64: usize = 4096;
pub const SDP_MAX_BYTES: usize = 64 * 1024;
pub const SDP_PREFIX: &str = "v=0";
pub const CANDIDATE_MAX_BYTES: usize = 1024;
pub const CANDIDATE_PREFIX: &str = "candidate:";
pub const CANDIDATE_TYPES: [&str; 4] = ["host", "srflx", "prflx", "relay"];
pub const CANDIDATE_MAX_EXTENSIONS: usize = 16;
pub const SDP_MID_MAX_BYTES: usize = 32;
pub const M_LINE_INDEX: RangeInclusive<i64> = 0..=65_535;
pub const FINGERPRINTS_MAX_BYTES: usize = 1024;
pub const PUBKEY_MAX_BYTES: usize = 256;
pub const SIGNATURE_MAX_BYTES: usize = 256;
pub const MAC_MAX_BYTES: usize = 128;

const FOUNDATION_MAX: usize = 32;
const EXTENSION_NAME_MAX: usize = 32;
const EXTENSION_VALUE_MAX: usize = 256;
const MDNS_SUFFIX: &str = ".local";
const MDNS_UUID_LEN: usize = 36;
const MDNS_UUID_DASHES: [usize; 4] = [8, 13, 18, 23];

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum RelayError {
    PakeStep,
    PakePayload,
    Sdp,
    Candidate,
    SdpMid,
    MLineIndex,
    Field(&'static str),
}

impl fmt::Display for RelayError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::PakeStep => f.write_str("pake step must be an integer from 1 to 3"),
            Self::PakePayload => write!(
                f,
                "pake payload must be padded base64 of at most {PAKE_PAYLOAD_MAX_BASE64} characters"
            ),
            Self::Sdp => write!(
                f,
                "sdp must begin with {SDP_PREFIX:?}, hold no NUL and be at most {SDP_MAX_BYTES} bytes"
            ),
            Self::Candidate => write!(
                f,
                "candidate must be an ICE candidate line of at most {CANDIDATE_MAX_BYTES} bytes"
            ),
            Self::SdpMid => write!(
                f,
                "sdpMid must be at most {SDP_MID_MAX_BYTES} media-id characters"
            ),
            Self::MLineIndex => f.write_str("sdpMLineIndex must be an integer from 0 to 65535"),
            Self::Field(name) => write!(f, "{name} is too long or malformed"),
        }
    }
}

impl std::error::Error for RelayError {}

fn all_bytes(value: &str, ok: fn(u8) -> bool) -> bool {
    value.bytes().all(ok)
}

fn bounded_token(value: &str, max: usize, ok: fn(u8) -> bool) -> bool {
    !value.is_empty() && value.len() <= max && all_bytes(value, ok)
}

fn decimal_between(value: &str, digits: usize, range: RangeInclusive<u64>) -> bool {
    bounded_token(value, digits, |b| b.is_ascii_digit())
        && value.parse::<u64>().is_ok_and(|n| range.contains(&n))
}

fn is_ice_char(b: u8) -> bool {
    b.is_ascii_alphanumeric() || b == b'+' || b == b'/'
}

fn is_base64_byte(b: u8) -> bool {
    is_ice_char(b) || b == b'='
}

fn is_fingerprint_byte(b: u8) -> bool {
    b.is_ascii_alphanumeric() || b":- \n".contains(&b)
}

fn is_mid_byte(b: u8) -> bool {
    b.is_ascii_alphanumeric() || b"_.+/-".contains(&b)
}

fn is_extension_name_byte(b: u8) -> bool {
    b.is_ascii_digit() || b.is_ascii_lowercase() || b == b'-'
}

fn is_extension_value_byte(b: u8) -> bool {
    b.is_ascii_alphanumeric() || b"+/=.:_-".contains(&b)
}

fn padded_base64(value: &str) -> bool {
    let body = value.trim_end_matches('=');
    !value.is_empty()
        && value.len() % 4 == 0
        && value.len() - body.len() <= 2
        && all_bytes(body, is_ice_char)
}

pub fn pake_step(step: i64) -> Result<u8, RelayError> {
    if !PAKE_STEPS.contains(&step) {
        return Err(RelayError::PakeStep);
    }
    u8::try_from(step).map_err(|_| RelayError::PakeStep)
}

pub fn pake_payload(payload: &str) -> Result<(), RelayError> {
    let legal = payload.len() <= PAKE_PAYLOAD_MAX_BASE64 && padded_base64(payload);
    legal.then_some(()).ok_or(RelayError::PakePayload)
}

pub fn sdp_body(sdp: &str) -> Result<(), RelayError> {
    let legal = sdp.len() <= SDP_MAX_BYTES && sdp.starts_with(SDP_PREFIX) && !sdp.contains('\0');
    legal.then_some(()).ok_or(RelayError::Sdp)
}

pub fn sdp_mid(mid: &str) -> Result<(), RelayError> {
    let legal = mid.len() <= SDP_MID_MAX_BYTES && all_bytes(mid, is_mid_byte);
    legal.then_some(()).ok_or(RelayError::SdpMid)
}

pub fn m_line_index(index: i64) -> Result<u16, RelayError> {
    if !M_LINE_INDEX.contains(&index) {
        return Err(RelayError::MLineIndex);
    }
    u16::try_from(index).map_err(|_| RelayError::MLineIndex)
}

/// `pubkey`, `sig` and `mac`: base64 characters within `max_bytes`; empty
/// means absent.
pub fn base64_field(name: &'static str, value: &str, max_bytes: usize) -> Result<(), RelayError> {
    let legal = value.len() <= max_bytes && all_bytes(value, is_base64_byte);
    legal.then_some(()).ok_or(RelayError::Field(name))
}

/// The `fp` field: `a=fingerprint` values (which contain a space) joined with `\n`.
pub fn fingerprint_list(value: &str) -> Result<(), RelayError> {
    let legal = value.len() <= FINGERPRINTS_MAX_BYTES && all_bytes(value, is_fingerprint_byte);
    legal.then_some(()).ok_or(RelayError::Field("fp"))
}

fn candidate_address(token: &str) -> bool {
    if token.parse::<std::net::IpAddr>().is_ok() {
        return true;
    }
    let Some(name) = token.strip_suffix(MDNS_SUFFIX) else {
        return false;
    };
    name.len() == MDNS_UUID_LEN
        && name.bytes().enumerate().all(|(index, b)| {
            if MDNS_UUID_DASHES.contains(&index) {
                b == b'-'
            } else {
                b.is_ascii_hexdigit()
            }
        })
}

/// RFC 8839 §5.1: `candidate:<foundation> <component> <transport> <priority>
/// <address> <port> typ <type>` and at most 16 `<name> <value>` pairs. An
/// empty line is the end-of-candidates marker.
pub fn candidate(line: &str) -> Result<(), RelayError> {
    if line.is_empty() {
        return Ok(());
    }
    let Some(body) = line.strip_prefix(CANDIDATE_PREFIX) else {
        return Err(RelayError::Candidate);
    };
    let tokens: Vec<&str> = body.split(' ').collect();
    let extensions = tokens.len().saturating_sub(8);
    if line.len() > CANDIDATE_MAX_BYTES
        || tokens.len() < 8
        || extensions % 2 != 0
        || extensions / 2 > CANDIDATE_MAX_EXTENSIONS
    {
        return Err(RelayError::Candidate);
    }
    let fixed = bounded_token(tokens[0], FOUNDATION_MAX, is_ice_char)
        && decimal_between(tokens[1], 3, 1..=256)
        && (tokens[2].eq_ignore_ascii_case("udp") || tokens[2].eq_ignore_ascii_case("tcp"))
        && decimal_between(tokens[3], 10, 0..=u64::from(u32::MAX))
        && candidate_address(tokens[4])
        && decimal_between(tokens[5], 5, 0..=65_535)
        && tokens[6] == "typ"
        && CANDIDATE_TYPES.contains(&tokens[7]);
    let pairs = tokens[8..].chunks(2).all(|pair| {
        bounded_token(pair[0], EXTENSION_NAME_MAX, is_extension_name_byte)
            && bounded_token(pair[1], EXTENSION_VALUE_MAX, is_extension_value_byte)
    });
    (fixed && pairs).then_some(()).ok_or(RelayError::Candidate)
}

#[cfg(test)]
mod tests;
