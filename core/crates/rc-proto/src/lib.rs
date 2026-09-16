//! The RemoteControl wire contract, in Rust.
//!
//! `protocol/PROTOCOL.md` at the repository root is normative. These types must
//! mirror it exactly; where they disagree, the document wins and this crate is
//! the bug. `protocol/protocol.go` is the Go mirror of the same contract, and
//! the two are held together by the shared vector files under `protocol/vectors`.
//!
//! This crate touches no operating system and has no async runtime. That is
//! deliberate: it is the half of the Windows host that can be tested to
//! completion on any machine, including the Mac this was written on.

#![forbid(unsafe_code)]

pub mod consts;
pub mod ctrl;
pub mod envelope;
pub mod signaling;

pub use consts::VERSION;
pub use envelope::{valid_device_id, DecodeError, Envelope};
