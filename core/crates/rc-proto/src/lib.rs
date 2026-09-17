//! RemoteControl wire contract.
//!
//! Mirrors `protocol/PROTOCOL.md`; `protocol/vectors` proves parity with `protocol/protocol.go`.

#![forbid(unsafe_code)]

pub mod consts;
pub mod ctrl;
pub mod envelope;
pub mod signaling;

pub use consts::VERSION;
pub use envelope::{valid_device_id, valid_session_id, DecodeError, Envelope};
