//! The RemoteControl host for Windows.
//!
//! The same binary runs on macOS/Linux with `--synthetic` for interop testing
//! against the real Mac controller: the runtime, session logic, signaling and
//! transport are all platform-neutral, and only capture + injection differ.
//! That is deliberate — it means the hard-to-test parts are exercised on the
//! machine this was built on, against the actual peer, before a Windows box is
//! ever involved.
//!
//! `--synthetic` pairs the test pattern with the **recording** injector, never
//! with the real one. A synthetic screen plus live `SendInput` would mean real
//! clicks aimed at a picture that is not the screen.

#![cfg_attr(not(windows), allow(dead_code))]

pub mod host;
pub mod inject;
pub mod keepawake;
pub mod media;
pub mod pump;

#[cfg(windows)]
pub mod inject_windows;
#[cfg(windows)]
pub mod capture_windows;

pub use host::{Host, HostConfig};
pub use inject::{InjectError, InputDispatcher, InputOp, InputState, Injector, RecordingInjector};
pub use media::{
    fit_for_encode, CaptureBackend, CaptureStatus, FrameSource, Pacing, RawFrame,
    SoftwareEncoder, SyntheticBackend, SyntheticSource, VideoEncoder,
};
pub use pump::{CapturePump, EncoderFactory, PumpConfig, PumpEvent, VideoSink};
