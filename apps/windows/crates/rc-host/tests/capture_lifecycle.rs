//! Tests the capture pump's lifecycle and pacing.
//!
//! The defects these close all cost a session rather than a frame: a blocking
//! pump that `abort()` could not stop, a frame source taken once so the second
//! session had none, an encoder left running after the peer went away, and a
//! software encoder let loose at full monitor resolution.

use std::sync::atomic::{AtomicU32, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use bytes::Bytes;
use rc_host::pump::{CapturePump, CapturedFrame, EncoderFactory, FrameSlot, PumpConfig, PumpEvent, VideoSink};
use rc_host::{
    fit_for_encode, hardware_or_software, resample, CaptureStatus, EncoderRequest, EncoderResult,
    FrameSource, LoadResponse, RawFrame, SoftwareEncoder, VideoEncoder,
};
use rc_proto::ctrl::QualityMode;
use rc_input::DisplayGeometry;
use tokio::sync::mpsc;

/// A source that blocks for `block` on every frame, counts its frames, and can
/// be told to report a status. Blocking is the point: it is what makes
/// cancellation a real question.
struct SlowSource {
    block: Duration,
    frames: Arc<AtomicU32>,
    status: Arc<Mutex<CaptureStatus>>,
    geometry: Arc<Mutex<Option<DisplayGeometry>>>,
    label: u32,
}

impl SlowSource {
    fn new(block: Duration) -> Self {
        Self {
            block,
            frames: Arc::new(AtomicU32::new(0)),
            status: Arc::new(Mutex::new(CaptureStatus::Live)),
            geometry: Arc::new(Mutex::new(Some(DisplayGeometry::single(640, 480, 1.0)))),
            label: 0,
        }
    }
}

impl FrameSource for SlowSource {
    fn next_frame(&mut self) -> Option<RawFrame> {
        std::thread::sleep(self.block);
        self.frames.fetch_add(1, Ordering::Relaxed);
        Some(RawFrame { width: 16, height: 16, rgb: vec![7u8; 16 * 16 * 3] })
    }

    fn geometry(&self) -> Option<DisplayGeometry> {
        *self.geometry.lock().unwrap()
    }

    fn status(&self) -> CaptureStatus {
        self.status.lock().unwrap().clone()
    }
}

#[derive(Default)]
struct CountingSink {
    samples: AtomicU32,
    open: Arc<Mutex<bool>>,
}

impl VideoSink for CountingSink {
    fn write(&self, _sample: Bytes, _captured_at: Instant) -> Result<(), String> {
        if !*self.open.lock().unwrap() {
            return Err("track closed".into());
        }
        self.samples.fetch_add(1, Ordering::Relaxed);
        Ok(())
    }
}

/// Records whether each frame was asked to be a keyframe, and how long it
/// pretends to take.
struct FakeEncoder {
    cost: Duration,
    keyframes: Arc<Mutex<Vec<bool>>>,
    fail_first: Arc<AtomicU32>,
}

impl VideoEncoder for FakeEncoder {
    fn encode(&mut self, _frame: &RawFrame, keyframe: bool) -> Result<Bytes, String> {
        std::thread::sleep(self.cost);
        self.keyframes.lock().unwrap().push(keyframe);
        if self.fail_first.load(Ordering::Relaxed) > 0 {
            self.fail_first.fetch_sub(1, Ordering::Relaxed);
            return Err("synthetic encoder failure".into());
        }
        Ok(Bytes::from_static(b"au"))
    }

    fn name(&self) -> &str {
        "fake"
    }
}

struct Fakes {
    keyframes: Arc<Mutex<Vec<bool>>>,
    builds: Arc<AtomicU32>,
    factory: EncoderFactory,
}

fn fake_encoders(cost: Duration, failures: u32) -> Fakes {
    let keyframes = Arc::new(Mutex::new(Vec::new()));
    let builds = Arc::new(AtomicU32::new(0));
    let fail_first = Arc::new(AtomicU32::new(failures));
    let (k, b, f) = (keyframes.clone(), builds.clone(), fail_first.clone());
    let factory: EncoderFactory = Arc::new(move |_request| {
        b.fetch_add(1, Ordering::Relaxed);
        Ok(Box::new(FakeEncoder { cost, keyframes: k.clone(), fail_first: f.clone() })
            as Box<dyn VideoEncoder>)
    });
    Fakes { keyframes, builds, factory }
}

fn config() -> PumpConfig {
    PumpConfig { quality: QualityMode::Auto, diagnostics: false }
}

async fn drain(rx: &mut mpsc::Receiver<PumpEvent>) -> Vec<PumpEvent> {
    let mut out = Vec::new();
    while let Ok(Some(event)) = tokio::time::timeout(Duration::from_millis(50), rx.recv()).await {
        out.push(event);
    }
    out
}

/// The defect: the frame source was `take()`n once and the pump `abort()`ed, so
/// a second session found no source and the first pump's encoder outlived it.
#[tokio::test]
async fn three_sessions_in_a_row_each_get_the_source_back() {
    let fakes = fake_encoders(Duration::ZERO, 0);
    let mut source = SlowSource::new(Duration::from_millis(2));
    let frames = source.frames.clone();

    for session in 1..=3 {
        source.label = session;
        let sink = Arc::new(CountingSink { open: Arc::new(Mutex::new(true)), ..Default::default() });
        let (tx, mut rx) = mpsc::channel(32);
        let pump =
            CapturePump::start(source, sink.clone(), tx, config(), fakes.factory.clone());

        tokio::time::sleep(Duration::from_millis(80)).await;
        let returned = pump.stop(Duration::from_secs(2)).await;
        source = returned.expect("session {session} must hand the source back");
        assert_eq!(source.label, session, "the same source came back, not a new one");
        assert!(
            sink.samples.load(Ordering::Relaxed) > 0,
            "session {session} produced no frames"
        );
        assert!(!drain(&mut rx).await.is_empty(), "session {session} reported nothing");
    }
    assert!(frames.load(Ordering::Relaxed) > 3);
    assert!(
        fakes.builds.load(Ordering::Relaxed) >= 3,
        "each session builds its own encoder, so none is shared or leaked"
    );
}

/// `abort()` on a blocking task does nothing until the closure yields. The stop
/// has to be cooperative, and it has to be noticed in well under a frame.
#[tokio::test]
async fn a_blocking_pump_stops_cooperatively_and_promptly() {
    let fakes = fake_encoders(Duration::ZERO, 0);
    let source = SlowSource::new(Duration::from_millis(25));
    let sink = Arc::new(CountingSink { open: Arc::new(Mutex::new(true)), ..Default::default() });
    let (tx, _rx) = mpsc::channel(32);
    let pump = CapturePump::start(source, sink, tx, config(), fakes.factory.clone());
    tokio::time::sleep(Duration::from_millis(40)).await;

    let started = Instant::now();
    let returned = pump.stop(Duration::from_secs(2)).await;
    let took = started.elapsed();
    assert!(returned.is_some(), "the source must come back");
    assert!(took < Duration::from_millis(400), "stopping took {took:?}");
}

#[tokio::test]
async fn nothing_is_encoded_after_the_pump_is_stopped() {
    let fakes = fake_encoders(Duration::ZERO, 0);
    let source = SlowSource::new(Duration::from_millis(1));
    let frames = source.frames.clone();
    let sink = Arc::new(CountingSink { open: Arc::new(Mutex::new(true)), ..Default::default() });
    let (tx, _rx) = mpsc::channel(64);
    let pump =
        CapturePump::start(source, sink.clone(), tx, config(), fakes.factory.clone());
    tokio::time::sleep(Duration::from_millis(60)).await;
    pump.stop(Duration::from_secs(2)).await.expect("source back");

    let frames_at_stop = frames.load(Ordering::Relaxed);
    let samples_at_stop = sink.samples.load(Ordering::Relaxed);
    tokio::time::sleep(Duration::from_millis(120)).await;
    assert_eq!(frames.load(Ordering::Relaxed), frames_at_stop, "no orphaned capture loop");
    assert_eq!(sink.samples.load(Ordering::Relaxed), samples_at_stop, "no orphaned encoder");
}

#[tokio::test]
async fn dropping_a_pump_without_stopping_it_still_ends_the_loop() {
    let fakes = fake_encoders(Duration::ZERO, 0);
    let source = SlowSource::new(Duration::from_millis(1));
    let frames = source.frames.clone();
    let sink = Arc::new(CountingSink { open: Arc::new(Mutex::new(true)), ..Default::default() });
    let (tx, _rx) = mpsc::channel(64);
    drop(CapturePump::start(source, sink, tx, config(), fakes.factory.clone()));
    tokio::time::sleep(Duration::from_millis(60)).await;
    let at_drop = frames.load(Ordering::Relaxed);
    tokio::time::sleep(Duration::from_millis(120)).await;
    assert_eq!(
        frames.load(Ordering::Relaxed),
        at_drop,
        "no path may leave the capture loop running"
    );
}

/// A closed track is the session ending. The pump must notice and release the
/// source rather than encode into nothing for the rest of the process's life.
#[tokio::test]
async fn a_closed_video_track_ends_the_pump() {
    let fakes = fake_encoders(Duration::ZERO, 0);
    let source = SlowSource::new(Duration::from_millis(1));
    let sink = Arc::new(CountingSink { open: Arc::new(Mutex::new(false)), ..Default::default() });
    let (tx, _rx) = mpsc::channel(32);
    let pump = CapturePump::start(source, sink, tx, config(), fakes.factory.clone());
    let returned = tokio::time::timeout(Duration::from_secs(2), pump.stop(Duration::from_secs(2)))
        .await
        .expect("must not hang");
    assert!(returned.is_some());
}

#[tokio::test]
async fn a_protected_desktop_is_reported_and_nothing_is_sent() {
    let fakes = fake_encoders(Duration::ZERO, 0);
    let source = SlowSource::new(Duration::from_millis(1));
    *source.status.lock().unwrap() = CaptureStatus::DesktopUnavailable;
    let sink = Arc::new(CountingSink { open: Arc::new(Mutex::new(true)), ..Default::default() });
    let (tx, mut rx) = mpsc::channel(32);
    let pump =
        CapturePump::start(source, sink.clone(), tx, config(), fakes.factory.clone());
    tokio::time::sleep(Duration::from_millis(60)).await;

    let events = drain(&mut rx).await;
    assert!(
        events.contains(&PumpEvent::Status(CaptureStatus::DesktopUnavailable)),
        "the host must say the desktop is not available, got {events:?}"
    );
    assert_eq!(
        sink.samples.load(Ordering::Relaxed),
        0,
        "a protected desktop must not be streamed"
    );
    pump.stop(Duration::from_secs(2)).await.expect("source back");
}

/// Knowing where the screen is is what unsuspends input, so it must not be
/// announced before the host has said whether the screen is available. A host
/// that starts up on a locked desktop would otherwise accept clicks for the
/// gap between the two events.
#[tokio::test]
async fn availability_is_announced_before_the_geometry_that_unsuspends_input() {
    let fakes = fake_encoders(Duration::ZERO, 0);
    let source = SlowSource::new(Duration::from_millis(1));
    *source.status.lock().unwrap() = CaptureStatus::DesktopUnavailable;
    let sink = Arc::new(CountingSink { open: Arc::new(Mutex::new(true)), ..Default::default() });
    let (tx, mut rx) = mpsc::channel(32);
    let pump = CapturePump::start(source, sink, tx, config(), fakes.factory.clone());
    let events = drain(&mut rx).await;
    pump.stop(Duration::from_secs(2)).await.expect("source back");

    let status_at = events.iter().position(|e| matches!(e, PumpEvent::Status(_)));
    let geometry_at = events.iter().position(|e| matches!(e, PumpEvent::Geometry(_)));
    assert_eq!(status_at, Some(0), "got {events:?}");
    assert!(geometry_at > status_at, "got {events:?}");
}

#[tokio::test]
async fn coming_back_from_unavailable_forces_a_keyframe() {
    let fakes = fake_encoders(Duration::ZERO, 0);
    let source = SlowSource::new(Duration::from_millis(1));
    let status = source.status.clone();
    *status.lock().unwrap() = CaptureStatus::DesktopUnavailable;
    let sink = Arc::new(CountingSink { open: Arc::new(Mutex::new(true)), ..Default::default() });
    let (tx, _rx) = mpsc::channel(64);
    let pump =
        CapturePump::start(source, sink, tx, config(), fakes.factory.clone());
    tokio::time::sleep(Duration::from_millis(40)).await;
    assert!(fakes.keyframes.lock().unwrap().is_empty(), "nothing encoded while unavailable");

    *status.lock().unwrap() = CaptureStatus::Live;
    tokio::time::sleep(Duration::from_millis(60)).await;
    pump.stop(Duration::from_secs(2)).await.expect("source back");

    let keyframes = fakes.keyframes.lock().unwrap().clone();
    assert_eq!(
        keyframes.first(),
        Some(&true),
        "the first frame after the screen returns must be an IDR; the peer's references are gone"
    );
}

#[tokio::test]
async fn a_geometry_change_is_published_and_forces_a_keyframe() {
    let fakes = fake_encoders(Duration::ZERO, 0);
    let source = SlowSource::new(Duration::from_millis(1));
    let geometry = source.geometry.clone();
    let sink = Arc::new(CountingSink { open: Arc::new(Mutex::new(true)), ..Default::default() });
    let (tx, mut rx) = mpsc::channel(64);
    let pump = CapturePump::start(source, sink, tx, config(), fakes.factory.clone());
    tokio::time::sleep(Duration::from_millis(30)).await;
    let _ = drain(&mut rx).await;
    fakes.keyframes.lock().unwrap().clear();

    let changed = DisplayGeometry::single(1280, 800, 2.0);
    *geometry.lock().unwrap() = Some(changed);
    tokio::time::sleep(Duration::from_millis(50)).await;
    let events = drain(&mut rx).await;
    pump.stop(Duration::from_secs(2)).await.expect("source back");

    assert!(
        events.contains(&PumpEvent::Geometry(Some(changed))),
        "a resolution or DPI change must be published, got {events:?}"
    );
    assert!(
        fakes.keyframes.lock().unwrap().contains(&true),
        "a resolution change invalidates every reference frame the peer holds"
    );
}

#[tokio::test]
async fn a_run_of_encoder_failures_becomes_unavailable_rather_than_a_hot_loop() {
    let fakes = fake_encoders(Duration::ZERO, 1_000);
    let source = SlowSource::new(Duration::from_millis(1));
    let sink = Arc::new(CountingSink { open: Arc::new(Mutex::new(true)), ..Default::default() });
    let (tx, mut rx) = mpsc::channel(64);
    let pump =
        CapturePump::start(source, sink.clone(), tx, config(), fakes.factory.clone());
    tokio::time::sleep(Duration::from_millis(80)).await;
    let events = drain(&mut rx).await;
    let returned = pump.stop(Duration::from_secs(2)).await;

    assert!(returned.is_some(), "a failed encoder still hands the source back");
    assert!(
        events.iter().any(|e| matches!(e, PumpEvent::Status(CaptureStatus::Unavailable(_)))),
        "a broken encoder must surface as unavailable, got {events:?}"
    );
    assert_eq!(sink.samples.load(Ordering::Relaxed), 0);
}

#[tokio::test]
async fn an_encoder_that_cannot_be_built_is_unavailable_not_a_panic() {
    let factory: EncoderFactory = Arc::new(|_| Err("no encoder here".into()));
    let source = SlowSource::new(Duration::from_millis(1));
    let sink = Arc::new(CountingSink { open: Arc::new(Mutex::new(true)), ..Default::default() });
    let (tx, mut rx) = mpsc::channel(32);
    let pump = CapturePump::start(source, sink, tx, config(), factory);
    let events = drain(&mut rx).await;
    assert!(pump.stop(Duration::from_secs(2)).await.is_some());
    assert!(events.iter().any(|e| matches!(e, PumpEvent::Status(CaptureStatus::Unavailable(_)))));
}

#[tokio::test]
async fn the_first_frame_of_a_session_is_a_keyframe() {
    let fakes = fake_encoders(Duration::ZERO, 0);
    let source = SlowSource::new(Duration::from_millis(1));
    let sink = Arc::new(CountingSink { open: Arc::new(Mutex::new(true)), ..Default::default() });
    let (tx, _rx) = mpsc::channel(64);
    let pump = CapturePump::start(source, sink, tx, config(), fakes.factory.clone());
    tokio::time::sleep(Duration::from_millis(60)).await;
    pump.stop(Duration::from_secs(2)).await.expect("source back");
    let keyframes = fakes.keyframes.lock().unwrap().clone();
    assert_eq!(keyframes.first(), Some(&true), "a joining decoder needs SPS/PPS and an IDR");
    assert!(keyframes.iter().any(|k| !k), "and not every frame after it");
}

/// A PLI means the peer's decoder has lost reference frames. Until an IDR
/// arrives nothing it receives decodes, so this is the whole recovery path.
#[tokio::test]
async fn a_keyframe_request_is_honoured_on_the_next_frame() {
    let fakes = fake_encoders(Duration::ZERO, 0);
    let source = SlowSource::new(Duration::from_millis(1));
    let sink = Arc::new(CountingSink { open: Arc::new(Mutex::new(true)), ..Default::default() });
    let (tx, _rx) = mpsc::channel(64);
    let pump = CapturePump::start(source, sink, tx, config(), fakes.factory.clone());
    tokio::time::sleep(Duration::from_millis(50)).await;
    fakes.keyframes.lock().unwrap().clear();

    pump.request_keyframe();
    tokio::time::sleep(Duration::from_millis(60)).await;
    pump.stop(Duration::from_secs(2)).await.expect("source back");

    let keyframes = fakes.keyframes.lock().unwrap().clone();
    assert_eq!(keyframes.first(), Some(&true), "the request applies to the very next frame");
}

/// The first encode fails, and it was the session's opening keyframe. If the request were consumed by the failed call the peer would never get an IDR.
#[tokio::test]
async fn a_keyframe_lost_to_an_encode_failure_is_asked_for_again() {
    let fakes = fake_encoders(Duration::ZERO, 1);
    let source = SlowSource::new(Duration::from_millis(1));
    let sink = Arc::new(CountingSink { open: Arc::new(Mutex::new(true)), ..Default::default() });
    let (tx, _rx) = mpsc::channel(64);
    let pump = CapturePump::start(source, sink, tx, config(), fakes.factory.clone());
    tokio::time::sleep(Duration::from_millis(60)).await;
    pump.stop(Duration::from_secs(2)).await.expect("source back");

    let keyframes = fakes.keyframes.lock().unwrap().clone();
    assert!(keyframes.len() >= 2, "the pump recovered and kept encoding");
    assert!(keyframes[1], "the keyframe the failed encode swallowed is requested again");
}

fn labelled(label: u32) -> RawFrame {
    let mut rgb = vec![0u8; 16 * 16 * 3];
    rgb[..4].copy_from_slice(&label.to_le_bytes());
    RawFrame { width: 16, height: 16, rgb }
}

fn label_of(frame: &RawFrame) -> u32 {
    u32::from_le_bytes(frame.rgb[..4].try_into().unwrap())
}

#[test]
fn three_frames_captured_while_the_encoder_is_busy_leave_only_the_newest() {
    let slot = FrameSlot::default();
    for label in 1..=3 {
        slot.put(CapturedFrame {
            frame: labelled(label),
            captured_at: Instant::now(),
            source_size: (16, 16),
        });
    }
    let taken = slot.take(Duration::ZERO).expect("a frame is waiting");
    assert_eq!(label_of(&taken.frame), 3, "the encoder gets the newest frame");
    assert!(slot.take(Duration::ZERO).is_none(), "and only that one");
    assert_eq!(slot.superseded(), 2, "the two it never saw are counted as dropped");
}

/// A source that never blocks and stamps every frame with a counter.
struct CountingSource {
    next: u32,
    stop_after: Option<u32>,
}

impl FrameSource for CountingSource {
    fn next_frame(&mut self) -> Option<RawFrame> {
        if self.stop_after.is_some_and(|last| self.next >= last) {
            return None;
        }
        self.next += 1;
        Some(labelled(self.next))
    }

    fn geometry(&self) -> Option<DisplayGeometry> {
        Some(DisplayGeometry::single(16, 16, 1.0))
    }
}

/// Encodes slowly, and declines the first `skips` frames the way openh264's
/// rate control does: with an empty access unit.
struct LabelEncoder {
    cost: Duration,
    skips: u32,
    seen: Arc<Mutex<Vec<u32>>>,
}

impl VideoEncoder for LabelEncoder {
    fn encode(&mut self, frame: &RawFrame, _keyframe: bool) -> Result<Bytes, String> {
        std::thread::sleep(self.cost);
        self.seen.lock().unwrap().push(label_of(frame));
        if self.skips > 0 {
            self.skips -= 1;
            return Ok(Bytes::new());
        }
        Ok(Bytes::from(label_of(frame).to_le_bytes().to_vec()))
    }

    fn name(&self) -> &str {
        "label"
    }
}

fn label_encoders(cost: Duration, skips: u32) -> (EncoderFactory, Arc<Mutex<Vec<u32>>>) {
    let seen = Arc::new(Mutex::new(Vec::new()));
    let recorded = seen.clone();
    let factory: EncoderFactory = Arc::new(move |_| {
        Ok(Box::new(LabelEncoder { cost, skips, seen: recorded.clone() }) as Box<dyn VideoEncoder>)
    });
    (factory, seen)
}

/// What reached the track, and how long after capture it got there.
#[derive(Default)]
struct TimingSink {
    sent: Mutex<Vec<(u32, Duration)>>,
}

impl VideoSink for TimingSink {
    fn write(&self, sample: Bytes, captured_at: Instant) -> Result<(), String> {
        let label = u32::from_le_bytes(sample[..4].try_into().unwrap());
        self.sent.lock().unwrap().push((label, captured_at.elapsed()));
        Ok(())
    }
}

#[tokio::test]
async fn a_slow_encoder_drops_frames_and_never_falls_behind_the_screen() {
    let cost = Duration::from_millis(80);
    let (factory, _) = label_encoders(cost, 0);
    let sink = Arc::new(TimingSink::default());
    let (tx, _rx) = mpsc::channel(256);
    let source = CountingSource { next: 0, stop_after: None };
    let pump = CapturePump::start(source, sink.clone(), tx, config(), factory);
    tokio::time::sleep(Duration::from_millis(900)).await;
    pump.stop(Duration::from_secs(2)).await.expect("source back");

    let sent = sink.sent.lock().unwrap().clone();
    assert!(sent.len() >= 4, "got {sent:?}");
    assert!(sent.windows(2).all(|w| w[1].0 > w[0].0), "frames go out in capture order");
    assert!(sent.windows(2).any(|w| w[1].0 > w[0].0 + 1), "frames the encoder could not reach are dropped");
    let worst = sent.iter().map(|(_, lag)| *lag).max().unwrap();
    assert!(
        worst < cost * 2 + rc_host::media::frame_budget() * 2,
        "every frame is at most one encode behind its capture, worst {worst:?}"
    );
}

#[tokio::test]
async fn a_frame_the_rate_controller_skipped_is_sent_once_it_can_be() {
    let (factory, seen) = label_encoders(Duration::ZERO, 3);
    let sink = Arc::new(TimingSink::default());
    let (tx, _rx) = mpsc::channel(256);
    let source = CountingSource { next: 0, stop_after: Some(1) };
    let pump = CapturePump::start(source, sink.clone(), tx, config(), factory);
    tokio::time::sleep(Duration::from_millis(400)).await;
    pump.stop(Duration::from_secs(2)).await.expect("source back");

    assert_eq!(*seen.lock().unwrap(), vec![1, 1, 1, 1], "the one frame is offered until it goes");
    let sent: Vec<u32> = sink.sent.lock().unwrap().iter().map(|(label, _)| *label).collect();
    assert_eq!(sent, vec![1], "the screen's last state reaches the controller although nothing moved after it");
}

#[tokio::test]
async fn a_quality_change_rebuilds_the_encoder_at_the_new_bitrate_mid_session() {
    let bitrates = Arc::new(Mutex::new(Vec::new()));
    let recorded = bitrates.clone();
    let factory: EncoderFactory = Arc::new(move |request: EncoderRequest| {
        recorded.lock().unwrap().push((request.bitrate_bps, request.fps));
        Ok(Box::new(LabelEncoder { cost: Duration::ZERO, skips: 0, seen: Default::default() })
            as Box<dyn VideoEncoder>)
    });
    let sink = Arc::new(TimingSink::default());
    let (tx, _rx) = mpsc::channel(256);
    let source = CountingSource { next: 0, stop_after: None };
    let pump = CapturePump::start(source, sink.clone(), tx, config(), factory);
    tokio::time::sleep(Duration::from_millis(80)).await;
    pump.set_quality(QualityMode::Sharp);
    tokio::time::sleep(Duration::from_millis(80)).await;
    pump.set_quality(QualityMode::Smooth);
    tokio::time::sleep(Duration::from_millis(80)).await;
    pump.stop(Duration::from_secs(2)).await.expect("the session survived both changes");

    assert_eq!(
        *bitrates.lock().unwrap(),
        vec![(2_000_000, 30.0), (8_000_000, 30.0), (1_000_000, 30.0)]
    );
    assert!(sink.sent.lock().unwrap().len() > 3, "frames kept flowing across the changes");
}

fn window(load: &mut LoadResponse, cost: Duration) -> Option<rc_host::LoadStep> {
    let mut step = None;
    for _ in 0..LoadResponse::WINDOW {
        step = step.or(load.observe(cost, 2560, 1440));
    }
    step
}

#[test]
fn an_encode_that_fits_the_budget_changes_nothing() {
    let mut load = LoadResponse::new(QualityMode::Sharp);
    assert_eq!(load.measured_encode_time(), None, "nothing is claimed before it is measured");
    for _ in 0..5 {
        assert_eq!(window(&mut load, Duration::from_millis(20)), None);
    }
    assert_eq!(load.size_mode(), QualityMode::Sharp);
    assert_eq!(load.measured_encode_time(), Some(Duration::from_millis(20)));
}

#[test]
fn an_encode_over_budget_steps_down_one_rung_per_window_and_stops_at_the_bottom() {
    let mut load = LoadResponse::new(QualityMode::Sharp);
    let slow = Duration::from_millis(45);
    assert_eq!(window(&mut load, slow).map(|s| s.size_mode), Some(QualityMode::Auto));
    assert_eq!(window(&mut load, slow).map(|s| s.size_mode), Some(QualityMode::Smooth));
    assert_eq!(window(&mut load, slow), None, "the ladder's floor holds");
    assert_eq!(load.size_mode(), QualityMode::Smooth);
}

#[test]
fn the_load_response_never_goes_above_the_permitted_mode() {
    let mut load = LoadResponse::new(QualityMode::Auto);
    for _ in 0..10 {
        assert_eq!(window(&mut load, Duration::from_millis(1)), None);
    }
    assert_eq!(load.size_mode(), QualityMode::Auto);
}

#[test]
fn it_steps_back_up_only_when_the_rung_above_is_predicted_to_fit() {
    let mut load = LoadResponse::new(QualityMode::Sharp);
    window(&mut load, Duration::from_millis(45));
    assert_eq!(load.size_mode(), QualityMode::Auto);

    for _ in 0..6 {
        assert_eq!(
            window(&mut load, Duration::from_millis(20)),
            None,
            "20 ms at 1920 predicts ~36 ms at 2560, which would not fit"
        );
    }
    assert_eq!(window(&mut load, Duration::from_millis(10)), None);
    assert_eq!(window(&mut load, Duration::from_millis(10)), None);
    assert_eq!(
        window(&mut load, Duration::from_millis(10)).map(|s| s.size_mode),
        Some(QualityMode::Sharp),
        "three calm windows in a row"
    );
}

#[test]
fn a_frame_wider_than_the_rung_is_resampled_to_the_ladder_size() {
    let frame = RawFrame { width: 3840, height: 2160, rgb: vec![0u8; 3840 * 2160 * 3] };
    let fitted = fit_for_encode(frame, QualityMode::Auto);
    assert_eq!((fitted.width, fitted.height), (1920, 1080));
    assert_eq!(fitted.rgb.len(), 1920 * 1080 * 3);

    let frame = RawFrame { width: 2560, height: 1440, rgb: vec![200u8; 2560 * 1440 * 3] };
    let fitted = fit_for_encode(frame, QualityMode::Auto);
    assert_eq!((fitted.width, fitted.height), (1920, 1080), "a 4:3 ratio, not an integer one");
    assert!(fitted.rgb.iter().all(|&v| v == 200), "a flat colour stays flat");
}

#[test]
fn an_odd_sized_frame_is_cropped_even_rather_than_resampled() {
    let frame = RawFrame { width: 801, height: 601, rgb: vec![9u8; 801 * 601 * 3] };
    let fitted = fit_for_encode(frame, QualityMode::Sharp);
    assert_eq!((fitted.width, fitted.height), (800, 600));
}

#[test]
fn reduction_averages_rather_than_dropping_pixels() {
    let rgb = vec![
        0, 0, 0, 255, 255, 255, 0, 0, 0, 255, 255, 255, //
        255, 255, 255, 0, 0, 0, 255, 255, 255, 0, 0, 0, //
        0, 0, 0, 255, 255, 255, 0, 0, 0, 255, 255, 255, //
        255, 255, 255, 0, 0, 0, 255, 255, 255, 0, 0, 0,
    ];
    let fitted = resample(RawFrame { width: 4, height: 4, rgb }, 2, 2);
    assert_eq!((fitted.width, fitted.height), (2, 2));
    assert!(fitted.rgb.iter().all(|&v| v == 127 || v == 128), "got {:?}", fitted.rgb);

    let rgb: Vec<u8> = [0u8, 90, 180].iter().flat_map(|&v| [v, v, v]).collect();
    let fitted = resample(RawFrame { width: 3, height: 1, rgb }, 2, 1);
    assert_eq!(fitted.rgb, vec![30, 30, 30, 150, 150, 150], "a 1.5:1 reduction weighs by coverage");
}

/// The real encoder, on the real frames, producing a real Annex-B start code —
/// so the seam is not only exercised by the fake.
#[test]
fn the_software_encoder_produces_an_annex_b_keyframe() {
    let mut encoder = SoftwareEncoder::new(1_000_000, 30.0).expect("openh264 builds");
    let frame = RawFrame { width: 320, height: 240, rgb: vec![64u8; 320 * 240 * 3] };
    let sample = encoder.encode(&frame, true).expect("encodes");
    assert!(sample.len() > 4, "an IDR is not empty");
    assert_eq!(&sample[..4], &[0, 0, 0, 1], "Annex-B start code");
}

/// Stands in for Media Foundation: a hardware encoder that works for
/// `good_frames` frames and then fails, the way a driver reset looks mid-session.
struct PretendHardware {
    good_frames: u32,
}

impl VideoEncoder for PretendHardware {
    fn encode(&mut self, _frame: &RawFrame, _keyframe: bool) -> Result<Bytes, String> {
        if self.good_frames == 0 {
            return Err("device removed".into());
        }
        self.good_frames -= 1;
        Ok(Bytes::from_static(b"hw"))
    }

    fn name(&self) -> &str {
        "pretend-hardware"
    }

    fn is_hardware(&self) -> bool {
        true
    }
}

/// Stands in for openh264, failing every frame when `broken`.
struct PretendSoftware {
    broken: bool,
}

impl VideoEncoder for PretendSoftware {
    fn encode(&mut self, _frame: &RawFrame, _keyframe: bool) -> Result<Bytes, String> {
        if self.broken {
            return Err("software failed too".into());
        }
        Ok(Bytes::from_static(b"sw"))
    }

    fn name(&self) -> &str {
        "pretend-software"
    }
}

fn request(hardware: bool) -> EncoderRequest {
    EncoderRequest { bitrate_bps: 2_000_000, fps: 30.0, hardware }
}

fn chosen(result: EncoderResult) -> String {
    result.expect("an encoder is built").name().to_owned()
}

#[test]
fn the_factory_prefers_hardware_and_falls_back_to_software_when_it_cannot_be_built() {
    let hardware =
        |_: &EncoderRequest| -> EncoderResult { Ok(Box::new(PretendHardware { good_frames: 1 })) };
    let missing = |_: &EncoderRequest| -> EncoderResult { Err("no hardware H.264 encoder".into()) };
    let software =
        |_: &EncoderRequest| -> EncoderResult { Ok(Box::new(PretendSoftware { broken: false })) };
    let untried = |_: &EncoderRequest| -> EncoderResult { panic!("hardware must not be tried") };

    assert_eq!(chosen(hardware_or_software(request(true), hardware, software)), "pretend-hardware");
    assert_eq!(chosen(hardware_or_software(request(true), missing, software)), "pretend-software");
    assert_eq!(chosen(hardware_or_software(request(false), untried, software)), "pretend-software");
}

/// A factory that builds the pretend hardware encoder whenever it is allowed
/// to, and records whether each build allowed it.
fn hardware_first(
    good_frames: u32,
    software_broken: bool,
) -> (EncoderFactory, Arc<Mutex<Vec<bool>>>) {
    let requests = Arc::new(Mutex::new(Vec::new()));
    let recorded = requests.clone();
    let factory: EncoderFactory = Arc::new(move |request: EncoderRequest| {
        recorded.lock().unwrap().push(request.hardware);
        hardware_or_software(
            request,
            |_| Ok(Box::new(PretendHardware { good_frames })),
            |_| Ok(Box::new(PretendSoftware { broken: software_broken })),
        )
    });
    (factory, requests)
}

fn fallbacks(events: &[PumpEvent]) -> Vec<(String, String)> {
    events
        .iter()
        .filter_map(|e| match e {
            PumpEvent::EncoderFallback { from, detail } => Some((from.clone(), detail.clone())),
            _ => None,
        })
        .collect()
}

#[tokio::test]
async fn a_hardware_encoder_that_fails_mid_session_is_swapped_for_software_once() {
    let (factory, requests) = hardware_first(1, false);
    let source = SlowSource::new(Duration::from_millis(1));
    let sink = Arc::new(CountingSink { open: Arc::new(Mutex::new(true)), ..Default::default() });
    let (tx, mut rx) = mpsc::channel(256);
    let pump = CapturePump::start(source, sink.clone(), tx, config(), factory);
    tokio::time::sleep(Duration::from_millis(150)).await;
    pump.set_quality(QualityMode::Sharp);
    tokio::time::sleep(Duration::from_millis(100)).await;
    let events = drain(&mut rx).await;
    assert!(pump.stop(Duration::from_secs(2)).await.is_some());

    assert_eq!(
        fallbacks(&events),
        vec![("pretend-hardware".to_owned(), "device removed".to_owned())],
        "one fallback, naming the encoder that failed and why"
    );
    assert!(
        !events.iter().any(|e| matches!(e, PumpEvent::Status(CaptureStatus::Unavailable(_)))),
        "the session survives the hardware failure, got {events:?}"
    );
    assert!(sink.samples.load(Ordering::Relaxed) >= 3, "frames keep flowing after the swap");
    assert_eq!(
        *requests.lock().unwrap(),
        vec![true, false, false],
        "after the fallback every rebuild, a quality change included, stays in software"
    );
}

#[tokio::test]
async fn software_that_fails_after_the_fallback_ends_the_session_without_a_second_hop() {
    let (factory, requests) = hardware_first(0, true);
    let source = SlowSource::new(Duration::from_millis(1));
    let sink = Arc::new(CountingSink { open: Arc::new(Mutex::new(true)), ..Default::default() });
    let (tx, mut rx) = mpsc::channel(256);
    let pump = CapturePump::start(source, sink.clone(), tx, config(), factory);
    tokio::time::sleep(Duration::from_millis(250)).await;
    let events = drain(&mut rx).await;
    assert!(pump.stop(Duration::from_secs(2)).await.is_some());

    assert_eq!(fallbacks(&events).len(), 1, "the hop happens once per session");
    assert!(
        events.iter().any(|e| matches!(e, PumpEvent::Status(CaptureStatus::Unavailable(_)))),
        "a software encoder that keeps failing is still a broken session, got {events:?}"
    );
    assert!(requests.lock().unwrap().iter().skip(1).all(|hardware| !hardware));
    assert_eq!(sink.samples.load(Ordering::Relaxed), 0);
}
