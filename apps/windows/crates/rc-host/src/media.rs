//! Frames, encoders, and the pacing that keeps encoding affordable.
//!
//! `FrameSource` is the seam between the platform capture (DXGI Desktop
//! Duplication on Windows, a synthetic pattern elsewhere) and the encoder. It
//! reports not just frames but *whether capture is working*, because a host that
//! cannot see the screen must say so rather than send something.
//!
//! `VideoEncoder` is the second seam. `SoftwareEncoder` (openh264) is the
//! baseline that works on every platform this binary compiles for; a Media
//! Foundation hardware encoder slots in behind the same trait on Windows.
//! Software H.264 at full monitor resolution is the CPU trap the Mac side fell
//! into once, so [`Pacing`] exists to refuse to walk into it: the encode cost is
//! measured, and the frame rate and then the resolution step down when it stops
//! fitting in the frame budget.

use std::time::Duration;

use bytes::Bytes;
use openh264::encoder::{Encoder, EncoderConfig, RateControlMode, UsageType};
use openh264::formats::{RgbSliceU8, YUVBuffer};
use openh264::OpenH264API;
use rc_input::DisplayGeometry;

/// One frame plus its geometry.
pub struct RawFrame {
    pub width: usize,
    pub height: usize,
    /// Tightly packed RGB (3 bytes/px) — what the encoder eats.
    pub rgb: Vec<u8>,
}

/// Whether the host can currently see the screen, and if not, why.
///
/// Anything but [`CaptureStatus::Live`] suspends remote input: a stale picture
/// with live clicks behind it is the one failure that can do real damage on the
/// host's machine.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum CaptureStatus {
    Live,
    /// A secure or protected desktop is in front — a UAC prompt, the lock
    /// screen, or a session switch. Transient, and not the host's fault.
    DesktopUnavailable,
    /// Capture itself is not working and the reason is worth logging once.
    Unavailable(String),
}

impl CaptureStatus {
    pub fn is_live(&self) -> bool {
        *self == CaptureStatus::Live
    }
}

pub trait FrameSource: Send {
    /// Produce the next frame, or `None` when there is nothing new and the pump
    /// may idle (the dirty-rect signal on Windows). A `None` is not a failure;
    /// [`FrameSource::status`] is where failure is reported.
    fn next_frame(&mut self) -> Option<RawFrame>;

    /// Where the captured display sits in the virtual desktop. `None` while the
    /// geometry is unknown or being re-read, which suspends input.
    fn geometry(&self) -> Option<DisplayGeometry>;

    fn status(&self) -> CaptureStatus {
        CaptureStatus::Live
    }
}

/// A moving diagonal gradient: cheap, obviously alive on screen, and it
/// exercises the whole encode path because every frame differs.
///
/// This is a **diagnostic** source. It is never paired with a real input
/// injector: clicking on a test pattern would send real clicks to whatever is
/// actually on the host's screen.
pub struct SyntheticSource {
    width: usize,
    height: usize,
    tick: u32,
}

impl SyntheticSource {
    pub fn new(width: usize, height: usize) -> Self {
        Self { width, height, tick: 0 }
    }
}

impl FrameSource for SyntheticSource {
    fn next_frame(&mut self) -> Option<RawFrame> {
        self.tick = self.tick.wrapping_add(3);
        let t = self.tick as usize;
        let mut rgb = vec![0u8; self.width * self.height * 3];
        for y in 0..self.height {
            let row = y * self.width * 3;
            for x in 0..self.width {
                let i = row + x * 3;
                rgb[i] = ((x + t) & 0xFF) as u8;
                rgb[i + 1] = ((y + t / 2) & 0xFF) as u8;
                rgb[i + 2] = (((x + y) / 2 + t) & 0xFF) as u8;
            }
        }
        Some(RawFrame { width: self.width, height: self.height, rgb })
    }

    fn geometry(&self) -> Option<DisplayGeometry> {
        Some(DisplayGeometry::single(self.width as i32, self.height as i32, 1.0))
    }
}

/// Opens frame sources on demand.
///
/// A source is a device, and devices break. Holding one for the life of the
/// process means a session that loses it never gets it back; the host therefore
/// keeps the *backend* and asks it for a source at the start of each session,
/// reusing the previous one when it came back cleanly.
pub trait CaptureBackend: Send + 'static {
    type Source: FrameSource + 'static;

    fn open(&mut self) -> Result<Self::Source, String>;

    /// Named in the log line that says which path is live.
    fn describe(&self) -> &'static str;
}

/// The diagnostic backend behind `--synthetic`.
pub struct SyntheticBackend {
    pub width: usize,
    pub height: usize,
}

impl CaptureBackend for SyntheticBackend {
    type Source = SyntheticSource;

    fn open(&mut self) -> Result<Self::Source, String> {
        Ok(SyntheticSource::new(self.width, self.height))
    }

    fn describe(&self) -> &'static str {
        "synthetic test pattern"
    }
}

/// An H.264 encoder behind one call, so the hardware and software paths are
/// interchangeable and the pump does not know which it has.
pub trait VideoEncoder: Send {
    /// Encode one frame into an Annex-B access unit. `keyframe` forces an IDR —
    /// the only way to recover a decoder that has lost reference frames.
    /// An empty result means the encoder skipped this frame.
    fn encode(&mut self, frame: &RawFrame, keyframe: bool) -> Result<Bytes, String>;

    /// For logging which path is live, since it is not otherwise observable.
    fn name(&self) -> &'static str;
}

/// openh264, the software baseline.
///
/// Three settings differ from the defaults and each is load-bearing:
///
/// * `ScreenContentRealTime` — the default is camera video, which tunes for
///   noisy continuous-tone input rather than for the large flat areas and sharp
///   text edges of a desktop.
/// * `RateControlMode::Bitrate` with frame skipping — the default `Quality`
///   mode treats the target bitrate as advisory, which on a metered link is the
///   wrong knob to leave loose.
/// * `max_frame_rate` — the rate controller needs to know the cadence it is
///   budgeting for.
pub struct SoftwareEncoder {
    encoder: Encoder,
}

impl SoftwareEncoder {
    pub fn new(bitrate_bps: u32, fps: f32) -> Result<Self, String> {
        let config = EncoderConfig::new()
            .set_bitrate_bps(bitrate_bps)
            .max_frame_rate(fps.max(1.0))
            .usage_type(UsageType::ScreenContentRealTime)
            .rate_control_mode(RateControlMode::Bitrate)
            .enable_skip_frame(true);
        let encoder = Encoder::with_api_config(OpenH264API::from_source(), config)
            .map_err(|e| e.to_string())?;
        Ok(Self { encoder })
    }
}

impl VideoEncoder for SoftwareEncoder {
    fn encode(&mut self, frame: &RawFrame, keyframe: bool) -> Result<Bytes, String> {
        if keyframe {
            self.encoder.force_intra_frame();
        }
        let yuv =
            YUVBuffer::from_rgb_source(RgbSliceU8::new(&frame.rgb, (frame.width, frame.height)));
        let bitstream = self.encoder.encode(&yuv).map_err(|e| e.to_string())?;
        Ok(Bytes::from(bitstream.to_vec()))
    }

    fn name(&self) -> &'static str {
        "openh264 (software)"
    }
}

/// The resolution and frame-rate envelope the encoder is held to, and the
/// measured step-down when it does not fit.
///
/// The step-down is one-way within a session. Stepping back up on a brief lull
/// oscillates — resolution changes force an IDR and a controller-side resize,
/// so paying for one repeatedly is worse than staying at the lower setting
/// until the next session.
#[derive(Debug, Clone, Copy)]
pub struct Pacing {
    pub fps: f32,
    pub max_dimension: u32,
    pub floor_fps: f32,
    pub floor_dimension: u32,
    encode_ema: Option<Duration>,
}

impl Pacing {
    /// 2560 on the longest edge, chosen from a measurement rather than a guess.
    ///
    /// openh264 in a release build on the development Mac (Apple Silicon),
    /// mean over 30 synthetic desktop-like frames:
    ///
    /// | source | encode | with the reduction | fits 30 fps? |
    /// |---|---|---|---|
    /// | 3840x2160 | 46.6 ms | — | no, 21 fps ceiling |
    /// | 2560x1440 | 20.4 ms | — | yes |
    /// | 1920x1080 | 14.0 ms | 28 ms from 4K | yes / marginal |
    /// | 1280x720 | 9.9 ms | 16 ms from 1440p | yes |
    ///
    /// So 1440p is affordable at native resolution and 4K is not at any
    /// resolution above this, which is where the cap goes. These numbers are
    /// macOS/arm64, **not** a claim about any Windows machine — a different CPU
    /// moves every row. That is precisely why [`Pacing::observe`] measures the
    /// real cost at runtime instead of trusting this constant.
    pub const DEFAULT_MAX_DIMENSION: u32 = 2560;

    pub fn new(fps: f32, max_dimension: u32) -> Self {
        Self {
            fps: fps.max(1.0),
            max_dimension: max_dimension.max(320),
            floor_fps: 15.0,
            floor_dimension: 1280,
            encode_ema: None,
        }
    }

    pub fn frame_budget(&self) -> Duration {
        Duration::from_secs_f32(1.0 / self.fps.max(1.0))
    }

    /// The smoothed encode cost so far, for logging. `None` until a frame has
    /// been encoded — this type never guesses what it has not measured.
    pub fn measured_encode_time(&self) -> Option<Duration> {
        self.encode_ema
    }

    /// Feed one measured encode duration. Returns `true` when the envelope was
    /// stepped down, which the caller logs and acts on.
    ///
    /// The threshold is 80% of the frame budget: at 100% the encoder is the only
    /// thing the machine does, and capture, colour conversion and RTP still have
    /// to fit in the same frame.
    pub fn observe(&mut self, encode: Duration) -> bool {
        self.encode_ema = Some(match self.encode_ema {
            None => encode,
            Some(previous) => previous.mul_f32(0.8) + encode.mul_f32(0.2),
        });
        let ema = self.encode_ema.unwrap_or(encode);
        if ema.as_secs_f32() <= self.frame_budget().as_secs_f32() * 0.8 {
            return false;
        }
        // Frame rate first: it is free to change and invisible next to a
        // resolution drop, which costs an IDR and a window resize.
        if self.fps > self.floor_fps {
            self.fps = (self.fps / 2.0).max(self.floor_fps);
            self.encode_ema = None;
            return true;
        }
        if self.max_dimension > self.floor_dimension {
            self.max_dimension = self.floor_dimension;
            self.encode_ema = None;
            return true;
        }
        false
    }
}

/// Bring a frame inside the encode envelope: at most `max_dimension` on its
/// longest edge, and even on both edges.
///
/// Even dimensions are not cosmetic — H.264 4:2:0 chroma is half-resolution, so
/// an odd width has no defined last chroma column and encoders either reject it
/// or quietly produce a green edge column.
///
/// The reduction is by an integer factor and averages the block it replaces.
/// Dropping pixels instead is cheaper and looks it: text aliases into
/// unreadability, which is the one thing a remote desktop must not do.
pub fn fit_for_encode(frame: RawFrame, max_dimension: u32) -> RawFrame {
    let longest = frame.width.max(frame.height) as u32;
    let factor = if longest > max_dimension && max_dimension > 0 {
        longest.div_ceil(max_dimension).max(1) as usize
    } else {
        1
    };
    let out_w = ((frame.width / factor) / 2) * 2;
    let out_h = ((frame.height / factor) / 2) * 2;
    if factor == 1 && out_w == frame.width && out_h == frame.height {
        return frame;
    }
    if out_w == 0 || out_h == 0 {
        return frame;
    }

    let mut rgb = vec![0u8; out_w * out_h * 3];
    let samples = (factor * factor) as u32;
    for y in 0..out_h {
        for x in 0..out_w {
            let mut acc = [0u32; 3];
            for dy in 0..factor {
                let src_y = y * factor + dy;
                for dx in 0..factor {
                    let src_x = x * factor + dx;
                    let i = (src_y * frame.width + src_x) * 3;
                    acc[0] += frame.rgb[i] as u32;
                    acc[1] += frame.rgb[i + 1] as u32;
                    acc[2] += frame.rgb[i + 2] as u32;
                }
            }
            let o = (y * out_w + x) * 3;
            rgb[o] = (acc[0] / samples) as u8;
            rgb[o + 1] = (acc[1] / samples) as u8;
            rgb[o + 2] = (acc[2] / samples) as u8;
        }
    }
    RawFrame { width: out_w, height: out_h, rgb }
}
