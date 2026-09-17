//! Shape checks for every server-supplied value the core stores or signs.
//! A value that fails is refused before it can reach a log, a signature or
//! the owner's screen.

use std::fmt;

pub const SESSION_ID_LEN: usize = 32;
pub const DEVICE_ID_LEN: usize = 9;
pub const SDP_TYPES: [&str; 2] = ["offer", "answer"];

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum InputError {
    SessionId,
    DeviceId,
    SdpType,
    SessionMismatch,
}

impl fmt::Display for InputError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(match self {
            Self::SessionId => "sessionId must be 32 lowercase hex characters",
            Self::DeviceId => "a device id must be exactly 9 digits",
            Self::SdpType => "sdpType must be offer or answer",
            Self::SessionMismatch => "the sessionId is not the one this machine holds",
        })
    }
}

impl std::error::Error for InputError {}

pub fn session_id(value: &str) -> Result<(), InputError> {
    let legal = value.len() == SESSION_ID_LEN
        && value
            .bytes()
            .all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b));
    legal.then_some(()).ok_or(InputError::SessionId)
}

pub fn device_id(value: &str) -> Result<(), InputError> {
    let legal = value.len() == DEVICE_ID_LEN && value.bytes().all(|b| b.is_ascii_digit());
    legal.then_some(()).ok_or(InputError::DeviceId)
}

pub fn sdp_type(value: &str) -> Result<(), InputError> {
    SDP_TYPES
        .contains(&value)
        .then_some(())
        .ok_or(InputError::SdpType)
}

#[cfg(test)]
mod tests;
