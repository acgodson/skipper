//! The capture -> encode -> track path, and its lifecycle.
//!
//! Two threads, one slot between them. The capture thread reads the screen at
//! the ladder's frame rate, sizes each frame for the encoder, and puts it in a
//! [`FrameSlot`]; the encode thread takes whatever is in the slot. The slot
//! holds one frame, and a new one replaces it: a slow encoder drops frames, it
//! never delays them, so what the controller sees is at most one encode behind
//! the screen however far behind the encoder falls.
//!
//! Both threads are blocking (`AcquireNextFrame`, a software encoder), so
//! cancellation is cooperative: a stop flag checked between frames and inside
//! every wait. The capture thread is the pump's task; it joins the encode
//! thread before it ends and **hands the frame source back**, so nothing here
//! outlives [`CapturePump::stop`] and the next session can reuse the source.

use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};
use std::sync::{Arc, Condvar, Mutex};
use std::time::{Duration, Instant};

use bytes::Bytes;
use rc_input::DisplayGeometry;
use rc_proto::ctrl::QualityMode;
use tokio::sync::mpsc;

use crate::media::{
    fit_for_encode, frame_budget, CaptureStatus, FrameSource, LoadResponse, RawFrame, VideoEncoder,
};
use crate::quality::QualityProfile;

/// Where encoded samples go. Abstracted so the lifecycle is testable without a
/// peer connection, and because the pump must not know about WebRTC.
pub trait VideoSink: Send + Sync + 'static {
    /// Blocking: the pump is already on a blocking thread. `captured_at` is
    /// when the screen looked like this, which is what the sample's media
    /// timestamp must follow.
    fn write(&self, sample: Bytes, captured_at: Instant) -> Result<(), String>;
}

/// Counters for one diagnostics interval, so a real session can say where its
/// time goes.
#[derive(Debug, Clone, PartialEq)]
pub struct MediaStats {
    pub interval: Duration,
    pub encoded: u32,
    /// Frames openh264's rate control declined; each is offered again.
    pub skipped: u32,
    /// Frames replaced in the slot before the encoder reached them.
    pub superseded: u64,
    pub mean_encode: Duration,
    pub max_encode: Duration,
    /// Capture to encode start: time spent waiting for the encoder.
    pub age_at_encode: AgeSummary,
    /// Capture to the write onto the track: everything before the network.
    pub age_at_send: AgeSummary,
    pub width: usize,
    pub height: usize,
    pub size_mode: QualityMode,
}

/// What the pump tells the host about, so the host can suspend input, publish
/// `display_info`, and log the encode path.
#[derive(Debug, Clone, PartialEq)]
pub enum PumpEvent {
    Status(CaptureStatus),
    Geometry(Option<DisplayGeometry>),
    /// The encode size moved a rung because of the measured encode cost.
    LoadStep { size_mode: QualityMode, mean_encode: Duration },
    Stats(MediaStats),
}

/// Builds an encoder for a given bitrate and frame rate. Called again when the
/// quality changes, so the rate controller always budgets for the live profile.
pub type EncoderFactory =
    Arc<dyn Fn(u32, f32) -> Result<Box<dyn VideoEncoder>, String> + Send + Sync>;

pub struct PumpConfig {
    /// The mode the host gate permitted; the pump never sees a request.
    pub quality: QualityMode,
    /// Publish [`PumpEvent::Stats`] every [`STATS_INTERVAL`].
    pub diagnostics: bool,
}

pub const STATS_INTERVAL: Duration = Duration::from_secs(1);

/// Median and worst of the frame ages seen in one interval.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct AgeSummary {
    pub p50: Duration,
    pub max: Duration,
}

impl AgeSummary {
    fn of(mut ages: Vec<Duration>) -> Self {
        ages.sort_unstable();
        Self {
            p50: ages.get(ages.len() / 2).copied().unwrap_or_default(),
            max: ages.last().copied().unwrap_or_default(),
        }
    }
}

/// A captured frame already sized for the encoder.
pub struct CapturedFrame {
    pub frame: RawFrame,
    pub captured_at: Instant,
    /// The capture's own size, before fitting, which the load response needs.
    pub source_size: (u32, u32),
}

#[derive(Default)]
struct Slot {
    frame: Option<CapturedFrame>,
    superseded: u64,
    closed: bool,
}

/// One frame between capture and encode; the newest wins.
#[derive(Default)]
pub struct FrameSlot {
    slot: Mutex<Slot>,
    ready: Condvar,
}

impl FrameSlot {
    fn lock(&self) -> std::sync::MutexGuard<'_, Slot> {
        self.slot.lock().unwrap_or_else(|e| e.into_inner())
    }

    /// Replaces whatever the encoder has not reached yet.
    pub fn put(&self, frame: CapturedFrame) {
        let mut slot = self.lock();
        if slot.frame.replace(frame).is_some() {
            slot.superseded += 1;
        }
        self.ready.notify_one();
    }

    /// The newest frame, waiting at most `timeout` for one.
    pub fn take(&self, timeout: Duration) -> Option<CapturedFrame> {
        let slot = self.lock();
        let (mut slot, _) = self
            .ready
            .wait_timeout_while(slot, timeout, |s| s.frame.is_none() && !s.closed)
            .unwrap_or_else(|e| e.into_inner());
        slot.frame.take()
    }

    /// How many frames were replaced unseen, since the slot was made.
    pub fn superseded(&self) -> u64 {
        self.lock().superseded
    }

    pub fn close(&self) {
        self.lock().closed = true;
        self.ready.notify_all();
    }
}

/// State both pump threads and the host share.
struct Shared {
    stop: AtomicBool,
    keyframe: AtomicBool,
    requested: Mutex<Option<QualityMode>>,
    size_rank: AtomicUsize,
    slot: FrameSlot,
}

impl Shared {
    fn stopped(&self) -> bool {
        self.stop.load(Ordering::Acquire)
    }

    fn size_mode(&self) -> QualityMode {
        QualityMode::LADDER[self.size_rank.load(Ordering::Acquire)]
    }

    fn set_size_mode(&self, mode: QualityMode) {
        self.size_rank.store(mode.rank(), Ordering::Release);
    }
}

/// A running pump. [`CapturePump::stop`] is the only path that recovers the
/// frame source; dropping one instead ends the loop but loses the source.
pub struct CapturePump<F> {
    shared: Arc<Shared>,
    handle: Option<tokio::task::JoinHandle<F>>,
}

impl<F: FrameSource + 'static> CapturePump<F> {
    pub fn start(
        source: F,
        sink: Arc<dyn VideoSink>,
        events: mpsc::Sender<PumpEvent>,
        config: PumpConfig,
        encoders: EncoderFactory,
    ) -> Self {
        let shared = Arc::new(Shared {
            stop: AtomicBool::new(false),
            keyframe: AtomicBool::new(true),
            requested: Mutex::new(None),
            size_rank: AtomicUsize::new(config.quality.rank()),
            slot: FrameSlot::default(),
        });
        let handle = {
            let shared = shared.clone();
            tokio::task::spawn_blocking(move || {
                run(source, sink, events, config, encoders, shared)
            })
        };
        Self { shared, handle: Some(handle) }
    }

    /// Ask for an IDR on the next frame. This is what a PLI from the peer means:
    /// its decoder has lost reference frames and nothing it receives will decode
    /// until a keyframe arrives.
    pub fn request_keyframe(&self) {
        self.shared.keyframe.store(true, Ordering::Release);
    }

    /// Reconfigure for a newly permitted mode without ending the session: the
    /// encoder is rebuilt at the mode's bitrate and the size follows.
    pub fn set_quality(&self, mode: QualityMode) {
        *self.shared.requested.lock().unwrap_or_else(|e| e.into_inner()) = Some(mode);
    }

    /// Stop the loop and take the frame source back.
    ///
    /// `None` means the loop did not finish inside `grace` — it is still asked
    /// to stop and will drop the source itself, but the caller must treat the
    /// source as gone and open a new one rather than wait on a hung device.
    pub async fn stop(mut self, grace: Duration) -> Option<F> {
        self.shared.stop.store(true, Ordering::Release);
        self.shared.slot.close();
        let handle = self.handle.take()?;
        match tokio::time::timeout(grace, handle).await {
            Ok(Ok(source)) => Some(source),
            Ok(Err(_)) | Err(_) => None,
        }
    }
}

impl<F> Drop for CapturePump<F> {
    /// A pump that is dropped rather than stopped would otherwise hold its
    /// capture device and keep encoding until the runtime shut down. This cannot
    /// recover the frame source — only `stop` awaits the thread — but it does
    /// guarantee that no path leaves the loop running.
    fn drop(&mut self) {
        self.shared.stop.store(true, Ordering::Release);
        self.shared.slot.close();
    }
}

/// Sleep in slices, so a stop is noticed in milliseconds rather than at the end
/// of a frame budget.
fn nap(stop: &AtomicBool, total: Duration) {
    const SLICE: Duration = Duration::from_millis(4);
    let deadline = Instant::now() + total;
    while Instant::now() < deadline {
        if stop.load(Ordering::Acquire) {
            return;
        }
        std::thread::sleep(SLICE.min(deadline.saturating_duration_since(Instant::now())));
    }
}

/// Publish one event, waiting for room if the host is momentarily behind but
/// giving up the moment a stop is asked for.
///
/// `blocking_send` would be simpler and wrong: between the host's loop ending
/// and teardown nobody is draining, so a full channel would park this thread
/// past the stop grace and the frame source would be given up for lost.
/// Returns `false` when the pump should end.
fn publish(events: &mpsc::Sender<PumpEvent>, stop: &AtomicBool, event: PumpEvent) -> bool {
    let mut event = event;
    loop {
        match events.try_send(event) {
            Ok(()) => return true,
            Err(mpsc::error::TrySendError::Closed(_)) => return false,
            Err(mpsc::error::TrySendError::Full(unsent)) => {
                if stop.load(Ordering::Acquire) {
                    return false;
                }
                event = unsent;
                std::thread::sleep(Duration::from_millis(4));
            }
        }
    }
}

/// How many consecutive encoder failures are tolerated before capture is called
/// unavailable. One is a hiccup; a run of them is a broken encoder, and
/// pretending otherwise would spin at full speed producing nothing.
const ENCODER_FAILURE_LIMIT: u32 = 3;

fn build(encoders: &EncoderFactory, profile: &QualityProfile) -> Result<Box<dyn VideoEncoder>, String> {
    encoders(profile.max_bitrate_bps, profile.max_framerate as f32)
}

/// The capture thread. The encoder is built here, before anything is
/// published, so a host is never told the screen is live by a pump that has
/// no encoder.
fn run<F: FrameSource>(
    mut source: F,
    sink: Arc<dyn VideoSink>,
    events: mpsc::Sender<PumpEvent>,
    config: PumpConfig,
    encoders: EncoderFactory,
    shared: Arc<Shared>,
) -> F {
    let profile = QualityProfile::for_mode(config.quality);
    let encoder = match build(&encoders, &profile) {
        Ok(e) => e,
        Err(e) => {
            publish(
                &events,
                &shared.stop,
                PumpEvent::Status(CaptureStatus::Unavailable(format!("encoder: {e}"))),
            );
            return source;
        }
    };
    let worker = {
        let shared = shared.clone();
        let events = events.clone();
        std::thread::spawn(move || {
            EncodeLoop::new(shared, sink, events, encoders, encoder, profile, config.diagnostics)
                .run()
        })
    };

    capture(&mut source, &events, &shared);

    shared.stop.store(true, Ordering::Release);
    shared.slot.close();
    let _ = worker.join();
    source
}

/// Status goes before geometry, not the other way round. Knowing where the screen is unsuspends input, so geometry first would open a window in which the host accepts clicks before it has said the desktop is locked.
fn capture<F: FrameSource>(source: &mut F, events: &mpsc::Sender<PumpEvent>, shared: &Shared) {
    let mut last_status: Option<CaptureStatus> = None;
    let mut last_geometry: Option<Option<DisplayGeometry>> = None;
    let budget = frame_budget();

    while !shared.stopped() {
        let status = source.status();
        if last_status.as_ref() != Some(&status) {
            last_status = Some(status.clone());
            if !publish(events, &shared.stop, PumpEvent::Status(status.clone())) {
                return;
            }
            if status.is_live() {
                shared.keyframe.store(true, Ordering::Release);
            }
        }

        let geometry = source.geometry();
        if last_geometry.as_ref() != Some(&geometry) {
            last_geometry = Some(geometry);
            if !publish(events, &shared.stop, PumpEvent::Geometry(geometry)) {
                return;
            }
            shared.keyframe.store(true, Ordering::Release);
        }

        if !status.is_live() {
            nap(&shared.stop, budget);
            continue;
        }

        let started = Instant::now();
        if let Some(frame) = source.next_frame() {
            let captured_at = Instant::now();
            let source_size = (frame.width as u32, frame.height as u32);
            let frame = fit_for_encode(frame, shared.size_mode());
            shared.slot.put(CapturedFrame { frame, captured_at, source_size });
        }
        nap(&shared.stop, budget.saturating_sub(started.elapsed()));
    }
}

#[derive(Default)]
struct Tally {
    since: Option<Instant>,
    encoded: u32,
    skipped: u32,
    superseded_before: u64,
    total_encode: Duration,
    max_encode: Duration,
    encode_ages: Vec<Duration>,
    send_ages: Vec<Duration>,
    size: (usize, usize),
}

struct EncodeLoop {
    shared: Arc<Shared>,
    sink: Arc<dyn VideoSink>,
    events: mpsc::Sender<PumpEvent>,
    encoders: EncoderFactory,
    encoder: Box<dyn VideoEncoder>,
    profile: QualityProfile,
    load: LoadResponse,
    diagnostics: bool,
    tally: Tally,
}

impl EncodeLoop {
    fn new(
        shared: Arc<Shared>,
        sink: Arc<dyn VideoSink>,
        events: mpsc::Sender<PumpEvent>,
        encoders: EncoderFactory,
        encoder: Box<dyn VideoEncoder>,
        profile: QualityProfile,
        diagnostics: bool,
    ) -> Self {
        Self {
            load: LoadResponse::new(profile.mode),
            shared,
            sink,
            events,
            encoders,
            encoder,
            profile,
            diagnostics,
            tally: Tally::default(),
        }
    }

    fn end(&self) {
        self.shared.stop.store(true, Ordering::Release);
        self.shared.slot.close();
    }

    /// A frame the rate controller skipped is offered again until it goes out
    /// or a newer one replaces it. Otherwise the last change before the screen
    /// went still — the final keystroke — could be skipped and then never sent,
    /// because a still screen produces no further frames.
    fn run(mut self) {
        let mut held: Option<CapturedFrame> = None;
        let mut failures = 0u32;
        let budget = frame_budget();

        while !self.shared.stopped() {
            if self.apply_requested_quality() {
                held = None;
            }
            let next = match self.shared.slot.take(budget) {
                Some(frame) => frame,
                None => match held.take() {
                    Some(frame) => frame,
                    None => {
                        self.report();
                        continue;
                    }
                },
            };
            if self.shared.stopped() {
                break;
            }

            let (width, height) = next.source_size;
            let wants_keyframe = self.shared.keyframe.swap(false, Ordering::AcqRel);
            let started = Instant::now();
            let encoded = self.encoder.encode(&next.frame, wants_keyframe);
            let cost = started.elapsed();

            match encoded {
                Ok(sample) if sample.is_empty() => {
                    failures = 0;
                    self.tally.skipped += 1;
                    if wants_keyframe {
                        self.shared.keyframe.store(true, Ordering::Release);
                    }
                    held = Some(next);
                }
                Ok(sample) => {
                    failures = 0;
                    self.count(cost, &next.frame, started - next.captured_at);
                    if self.diagnostics {
                        self.tally.send_ages.push(next.captured_at.elapsed());
                    }
                    if self.sink.write(sample, next.captured_at).is_err() {
                        self.end();
                        break;
                    }
                }
                Err(detail) => {
                    failures += 1;
                    if wants_keyframe {
                        self.shared.keyframe.store(true, Ordering::Release);
                    }
                    if failures >= ENCODER_FAILURE_LIMIT {
                        publish(
                            &self.events,
                            &self.shared.stop,
                            PumpEvent::Status(CaptureStatus::Unavailable(format!(
                                "encoder failed {failures} times: {detail}"
                            ))),
                        );
                        self.end();
                        break;
                    }
                    self.rebuild();
                    continue;
                }
            }

            if let Some(step) = self.load.observe(cost, width, height) {
                self.shared.set_size_mode(step.size_mode);
                let event =
                    PumpEvent::LoadStep { size_mode: step.size_mode, mean_encode: step.mean_encode };
                if !publish(&self.events, &self.shared.stop, event) {
                    break;
                }
            }
            self.report();
        }
    }

    /// Returns `true` when the profile changed.
    fn apply_requested_quality(&mut self) -> bool {
        let requested = self.shared.requested.lock().unwrap_or_else(|e| e.into_inner()).take();
        let Some(mode) = requested.filter(|mode| *mode != self.profile.mode) else {
            return false;
        };
        self.profile = QualityProfile::for_mode(mode);
        self.load = LoadResponse::new(mode);
        self.shared.set_size_mode(mode);
        self.rebuild();
        true
    }

    fn rebuild(&mut self) {
        if let Ok(fresh) = build(&self.encoders, &self.profile) {
            self.encoder = fresh;
            self.shared.keyframe.store(true, Ordering::Release);
        }
    }

    fn count(&mut self, cost: Duration, frame: &RawFrame, age_at_encode: Duration) {
        let tally = &mut self.tally;
        if self.diagnostics {
            tally.encode_ages.push(age_at_encode);
        }
        tally.encoded += 1;
        tally.total_encode += cost;
        tally.max_encode = tally.max_encode.max(cost);
        tally.size = (frame.width, frame.height);
    }

    fn report(&mut self) {
        if !self.diagnostics {
            return;
        }
        let now = Instant::now();
        let since = *self.tally.since.get_or_insert(now);
        if now.duration_since(since) < STATS_INTERVAL {
            return;
        }
        let superseded = self.shared.slot.superseded();
        let tally = std::mem::take(&mut self.tally);
        self.tally.since = Some(now);
        self.tally.superseded_before = superseded;
        let stats = MediaStats {
            interval: now.duration_since(since),
            encoded: tally.encoded,
            skipped: tally.skipped,
            superseded: superseded - tally.superseded_before,
            mean_encode: tally.total_encode.checked_div(tally.encoded).unwrap_or_default(),
            max_encode: tally.max_encode,
            age_at_encode: AgeSummary::of(tally.encode_ages),
            age_at_send: AgeSummary::of(tally.send_ages),
            width: tally.size.0,
            height: tally.size.1,
            size_mode: self.shared.size_mode(),
        };
        publish(&self.events, &self.shared.stop, PumpEvent::Stats(stats));
    }
}
