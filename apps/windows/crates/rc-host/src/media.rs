//! Frames, encoders, and the load response that keeps encoding on time.
//!
//! `FrameSource` is the seam between the platform capture (DXGI Desktop
//! Duplication on Windows, a synthetic pattern elsewhere) and the encoder. It
//! reports not just frames but *whether capture is working*, because a host that
//! cannot see the screen must say so rather than send something.
//!
//! `VideoEncoder` is the second seam. `SoftwareEncoder` (openh264) is the
//! baseline that works on every platform this binary compiles for; on Windows
//! the Media Foundation hardware encoder (`media_windows.rs`) sits behind the
//! same trait and is tried first, with openh264 as the fallback
//! ([`hardware_or_software`]).
//! The encode size comes from the quality ladder ([`crate::quality`]), and
//! [`LoadResponse`] steps it down a rung when the software encoder's measured
//! cost does not fit the frame budget, so a slow machine gets a smaller picture
//! on time rather than a full-size one late.

use std::time::Duration;

use bytes::Bytes;
use openh264::encoder::{Encoder, EncoderConfig, RateControlMode, UsageType};
use openh264::formats::{RgbSliceU8, YUVBuffer};
use openh264::OpenH264API;
use rc_input::DisplayGeometry;
use rc_proto::ctrl::QualityMode;

use crate::quality::{encode_size, ACTIVE_FRAMERATE};

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
    fn name(&self) -> &str;

    /// A hardware encoder that fails mid-session is replaced by openh264 rather
    /// than ending the session; a software one has nothing to fall back to.
    fn is_hardware(&self) -> bool {
        false
    }
}

/// What the pump asks the encoder factory for. `hardware` turns `false` once a
/// hardware encoder has failed in this session.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct EncoderRequest {
    pub bitrate_bps: u32,
    pub fps: f32,
    pub hardware: bool,
}

pub type EncoderResult = Result<Box<dyn VideoEncoder>, String>;

/// Whether this build has a hardware encoder to try at all.
pub const HAS_HARDWARE_ENCODER: bool = cfg!(windows);

/// The hardware encoder when the request allows it and one can be built, else
/// the software one. A hardware encoder that cannot be built is logged with its
/// reason, because which path is live is otherwise invisible.
pub fn hardware_or_software(
    request: EncoderRequest,
    hardware: impl FnOnce(&EncoderRequest) -> EncoderResult,
    software: impl FnOnce(&EncoderRequest) -> EncoderResult,
) -> EncoderResult {
    if request.hardware {
        match hardware(&request) {
            Ok(encoder) => return Ok(encoder),
            Err(reason) => eprintln!("rc-host: no hardware encoder ({reason}) — using openh264"),
        }
    }
    software(&request)
}

pub fn software_encoder(request: &EncoderRequest) -> EncoderResult {
    SoftwareEncoder::new(request.bitrate_bps, request.fps)
        .map(|e| Box::new(e) as Box<dyn VideoEncoder>)
}

#[cfg(windows)]
pub fn hardware_encoder(request: &EncoderRequest) -> EncoderResult {
    crate::media_windows::MediaFoundationEncoder::new(request.bitrate_bps, request.fps)
        .map(|e| Box::new(e) as Box<dyn VideoEncoder>)
}

#[cfg(not(windows))]
pub fn hardware_encoder(_request: &EncoderRequest) -> EncoderResult {
    Err("no hardware encoder on this platform".into())
}

/// openh264, the software baseline.
///
/// Every setting is chosen for latency on a desktop, and these are all the
/// knobs the crate exposes:
///
/// * `ScreenContentRealTime` — the default is camera video, which tunes for
///   noisy continuous-tone input rather than for the large flat areas and sharp
///   text edges of a desktop.
/// * `RateControlMode::Bitrate` with frame skipping — the default `Quality`
///   mode treats the target bitrate as advisory, which on a metered link is the
///   wrong knob to leave loose. A skipped frame comes back empty and the pump
///   offers it again rather than losing the screen's final state.
/// * `max_frame_rate` — the rate controller needs to know the cadence it is
///   budgeting for.
/// * Threads are left to openh264's auto mode (one per core).
///
/// openh264 has no B-frames and no lookahead, so every frame out is the frame
/// in; its default intra period is zero, so IDRs come only when asked for.
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
            .enable_skip_frame(true)
            .set_multiple_thread_idc(0);
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

    fn name(&self) -> &str {
        "openh264 (software)"
    }
}

/// The time one frame may take at the ladder's frame rate.
pub fn frame_budget() -> Duration {
    Duration::from_secs(1) / ACTIVE_FRAMERATE
}

/// The encode size steps down a rung when the measured encode cost does not
/// fit, and back up when the rung above would.
///
/// This is a load response, not a second ladder: it moves only between the
/// ladder's own sizes, never above the permitted mode, and the bitrate stays
/// the permitted mode's. A software encoder that falls behind would otherwise
/// either lag or drop most frames; a smaller picture on time is the better of
/// the three.
///
/// * Down: the mean encode time over a window of [`LoadResponse::WINDOW`]
///   frames exceeds the frame budget (33 ms at 30 fps).
/// * Up: for [`LoadResponse::RECOVERY_WINDOWS`] windows in a row, the mean
///   scaled by the pixel ratio of the rung above stays under 80% of the budget.
///   Predicting the cost above, rather than reacting to the cost here, is what
///   keeps it from oscillating.
#[derive(Debug, Clone)]
pub struct LoadResponse {
    ceiling: QualityMode,
    steps: usize,
    sum: Duration,
    count: u32,
    calm_windows: u32,
    last_mean: Option<Duration>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct LoadStep {
    pub size_mode: QualityMode,
    pub mean_encode: Duration,
}

impl LoadResponse {
    pub const WINDOW: u32 = 30;
    pub const RECOVERY_WINDOWS: u32 = 3;

    pub fn new(ceiling: QualityMode) -> Self {
        Self { ceiling, steps: 0, sum: Duration::ZERO, count: 0, calm_windows: 0, last_mean: None }
    }

    /// The ladder rung whose size the capture is encoded at.
    pub fn size_mode(&self) -> QualityMode {
        QualityMode::LADDER[self.ceiling.rank().saturating_sub(self.steps)]
    }

    /// The mean of the last complete window, for logging. `None` until one
    /// window has been measured.
    pub fn measured_encode_time(&self) -> Option<Duration> {
        self.last_mean
    }

    /// Feed one encode of a `width`×`height` capture.
    pub fn observe(&mut self, cost: Duration, width: u32, height: u32) -> Option<LoadStep> {
        self.sum += cost;
        self.count += 1;
        if self.count < Self::WINDOW {
            return None;
        }
        let mean = self.sum / self.count;
        self.sum = Duration::ZERO;
        self.count = 0;
        self.last_mean = Some(mean);
        let budget = frame_budget();
        let current = self.size_mode();

        if mean > budget {
            self.calm_windows = 0;
            current.cheaper()?;
            self.steps += 1;
            return Some(LoadStep { size_mode: self.size_mode(), mean_encode: mean });
        }
        if self.steps == 0 {
            return None;
        }
        let above = QualityMode::LADDER[current.rank() + 1];
        let predicted = mean.mul_f64(pixel_ratio(width, height, above, current));
        if predicted >= budget.mul_f64(0.8) {
            self.calm_windows = 0;
            return None;
        }
        self.calm_windows += 1;
        if self.calm_windows < Self::RECOVERY_WINDOWS {
            return None;
        }
        self.calm_windows = 0;
        self.steps -= 1;
        Some(LoadStep { size_mode: self.size_mode(), mean_encode: mean })
    }
}

fn pixel_ratio(width: u32, height: u32, larger: QualityMode, smaller: QualityMode) -> f64 {
    let pixels = |mode| {
        let (w, h) = encode_size(width, height, mode);
        (f64::from(w) * f64::from(h)).max(1.0)
    };
    pixels(larger) / pixels(smaller)
}

/// One output sample's footprint on a source axis, in 16-bit fixed point.
struct Taps {
    start: Vec<usize>,
    len: Vec<usize>,
    weights: Vec<u32>,
    stride: usize,
}

const WEIGHT_ONE: u32 = 1 << 16;

impl Taps {
    /// Area weights: each output sample is the coverage-weighted mean of the
    /// source samples under it. Downscaling averages, so text stays legible
    /// rather than aliasing; an upscale degenerates to a near-copy.
    fn area(src: usize, dst: usize) -> Self {
        let scale = src as f64 / dst as f64;
        let stride = scale.ceil() as usize + 2;
        let mut start = Vec::with_capacity(dst);
        let mut len = Vec::with_capacity(dst);
        let mut weights = vec![0u32; dst * stride];
        for i in 0..dst {
            let from = i as f64 * scale;
            let to = ((i + 1) as f64 * scale).min(src as f64);
            let first = from.floor() as usize;
            let last = (to.ceil() as usize).clamp(first + 1, src);
            let row = &mut weights[i * stride..i * stride + stride];
            let mut total = 0u32;
            let mut heaviest = 0;
            for (k, j) in (first..last).enumerate() {
                let overlap = (to.min(j as f64 + 1.0) - from.max(j as f64)).max(0.0);
                row[k] = (overlap / (to - from) * f64::from(WEIGHT_ONE)).round() as u32;
                total += row[k];
                if row[k] > row[heaviest] {
                    heaviest = k;
                }
            }
            row[heaviest] = (row[heaviest] + WEIGHT_ONE).saturating_sub(total);
            start.push(first);
            len.push(last - first);
        }
        Self { start, len, weights, stride }
    }
}

/// Bring a capture to exactly `width`×`height` for the encoder.
///
/// A frame already that size is passed through, and one that only needs an odd
/// edge dropped is cropped: resampling by a hair would soften every pixel. Any
/// real resize is separable area averaging, never pixel dropping.
pub fn resample(frame: RawFrame, width: usize, height: usize) -> RawFrame {
    if width == 0 || height == 0 || (frame.width, frame.height) == (width, height) {
        return frame;
    }
    if (width, height) == (frame.width & !1, frame.height & !1) {
        return crop(frame, width, height);
    }

    let columns = Taps::area(frame.width, width);
    let mut wide = vec![0u8; width * frame.height * 3];
    for y in 0..frame.height {
        let src = &frame.rgb[y * frame.width * 3..(y + 1) * frame.width * 3];
        let dst = &mut wide[y * width * 3..(y + 1) * width * 3];
        for x in 0..width {
            let weights = &columns.weights[x * columns.stride..];
            let mut acc = [WEIGHT_ONE / 2; 3];
            for k in 0..columns.len[x] {
                let i = (columns.start[x] + k) * 3;
                let w = weights[k];
                acc[0] += u32::from(src[i]) * w;
                acc[1] += u32::from(src[i + 1]) * w;
                acc[2] += u32::from(src[i + 2]) * w;
            }
            dst[x * 3] = (acc[0] >> 16) as u8;
            dst[x * 3 + 1] = (acc[1] >> 16) as u8;
            dst[x * 3 + 2] = (acc[2] >> 16) as u8;
        }
    }

    let rows = Taps::area(frame.height, height);
    let row_bytes = width * 3;
    let mut rgb = vec![0u8; row_bytes * height];
    let mut acc = vec![0u32; row_bytes];
    for y in 0..height {
        acc.fill(WEIGHT_ONE / 2);
        let weights = &rows.weights[y * rows.stride..];
        for k in 0..rows.len[y] {
            let w = weights[k];
            let src = &wide[(rows.start[y] + k) * row_bytes..][..row_bytes];
            for (a, &s) in acc.iter_mut().zip(src) {
                *a += u32::from(s) * w;
            }
        }
        for (d, a) in rgb[y * row_bytes..][..row_bytes].iter_mut().zip(&acc) {
            *d = (a >> 16) as u8;
        }
    }
    RawFrame { width, height, rgb }
}

fn crop(frame: RawFrame, width: usize, height: usize) -> RawFrame {
    let mut rgb = Vec::with_capacity(width * height * 3);
    for y in 0..height {
        let row = y * frame.width * 3;
        rgb.extend_from_slice(&frame.rgb[row..row + width * 3]);
    }
    RawFrame { width, height, rgb }
}

/// The frame the encoder is given for a capture under `size_mode`.
pub fn fit_for_encode(frame: RawFrame, size_mode: QualityMode) -> RawFrame {
    let (width, height) = encode_size(frame.width as u32, frame.height as u32, size_mode);
    resample(frame, width as usize, height as usize)
}
