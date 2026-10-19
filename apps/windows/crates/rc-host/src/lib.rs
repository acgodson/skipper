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

pub mod account;
pub mod annexb;
pub mod api;
pub mod backend;
pub mod consent;
pub mod host;
pub mod inject;
pub mod keepawake;
pub mod media;
pub mod nv12;
pub mod pake;
pub mod paths;
pub mod pump;
pub mod quality;
pub mod report;
pub mod secrets;
pub mod settings;
pub mod status;
pub mod urlhandler;

#[cfg(windows)]
pub mod inject_windows;
#[cfg(windows)]
pub mod capture_windows;
#[cfg(windows)]
pub mod media_windows;
#[cfg(windows)]
pub mod ui;

pub use backend::{Backend, BackendUrlError, BaseUrl};
pub use host::{Host, HostConfig, HostControls};
pub use inject::{InjectError, InputDispatcher, InputOp, InputState, Injector, RecordingInjector};
pub use media::{
    fit_for_encode, hardware_or_software, resample, CaptureBackend, CaptureStatus, EncoderRequest,
    EncoderResult, FrameSource, LoadResponse, LoadStep, RawFrame, SoftwareEncoder, SyntheticBackend,
    SyntheticSource, VideoEncoder,
};
pub use pake::{ExchangeError, GuessStore, HostExchange};
pub use pump::{
    CapturedFrame, CapturePump, EncoderFactory, FrameSlot, MediaStats, PumpConfig, PumpEvent, VideoSink,
};
pub use quality::{QualityCeiling, QualityProfile};
pub use secrets::{SecretAccount, SecretError, SecretStore};
