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
use rc_host::pump::{CapturePump, EncoderFactory, PumpConfig, PumpEvent, VideoSink};
use rc_host::{
    fit_for_encode, CaptureStatus, FrameSource, Pacing, RawFrame, SoftwareEncoder, VideoEncoder,
};
use rc_input::DisplayGeometry;
use tokio::sync::mpsc;

// ---------------------------------------------------------------------------
// Doubles
// ---------------------------------------------------------------------------

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
    fn write(&self, _sample: Bytes, _duration: Duration) -> Result<(), String> {
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

    fn name(&self) -> &'static str {
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
    let factory: EncoderFactory = Arc::new(move |_bitrate, _fps| {
        b.fetch_add(1, Ordering::Relaxed);
        Ok(Box::new(FakeEncoder { cost, keyframes: k.clone(), fail_first: f.clone() })
            as Box<dyn VideoEncoder>)
    });
    Fakes { keyframes, builds, factory }
}

fn config(fps: f32, max_dimension: u32) -> PumpConfig {
    PumpConfig { bitrate_bps: 1_000_000, pacing: Pacing::new(fps, max_dimension) }
}

async fn drain(rx: &mut mpsc::Receiver<PumpEvent>) -> Vec<PumpEvent> {
    let mut out = Vec::new();
    while let Ok(Some(event)) = tokio::time::timeout(Duration::from_millis(50), rx.recv()).await {
        out.push(event);
    }
    out
}

// ---------------------------------------------------------------------------
// Lifecycle
// ---------------------------------------------------------------------------

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
            CapturePump::start(source, sink.clone(), tx, config(30.0, 1920), fakes.factory.clone());

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
    // One frame per second: if the pump slept the whole budget without checking
    // the flag, stopping would take about a second.
    let pump = CapturePump::start(source, sink, tx, config(1.0, 1920), fakes.factory.clone());
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
        CapturePump::start(source, sink.clone(), tx, config(60.0, 1920), fakes.factory.clone());
    tokio::time::sleep(Duration::from_millis(60)).await;
    pump.stop(Duration::from_secs(2)).await.expect("source back");

    let frames_at_stop = frames.load(Ordering::Relaxed);
    let samples_at_stop = sink.samples.load(Ordering::Relaxed);
    tokio::time::sleep(Duration::from_millis(120)).await;
    assert_eq!(frames.load(Ordering::Relaxed), frames_at_stop, "no orphaned capture loop");
    assert_eq!(sink.samples.load(Ordering::Relaxed), samples_at_stop, "no orphaned encoder");
}

/// A closed track is the session ending. The pump must notice and release the
/// source rather than encode into nothing for the rest of the process's life.
#[tokio::test]
async fn a_closed_video_track_ends_the_pump() {
    let fakes = fake_encoders(Duration::ZERO, 0);
    let source = SlowSource::new(Duration::from_millis(1));
    let sink = Arc::new(CountingSink { open: Arc::new(Mutex::new(false)), ..Default::default() });
    let (tx, _rx) = mpsc::channel(32);
    let pump = CapturePump::start(source, sink, tx, config(60.0, 1920), fakes.factory.clone());
    // No stop flag is set: the pump has to end itself.
    let returned = tokio::time::timeout(Duration::from_secs(2), pump.stop(Duration::from_secs(2)))
        .await
        .expect("must not hang");
    assert!(returned.is_some());
}

// ---------------------------------------------------------------------------
// Capture availability
// ---------------------------------------------------------------------------

#[tokio::test]
async fn a_protected_desktop_is_reported_and_nothing_is_sent() {
    let fakes = fake_encoders(Duration::ZERO, 0);
    let source = SlowSource::new(Duration::from_millis(1));
    *source.status.lock().unwrap() = CaptureStatus::DesktopUnavailable;
    let sink = Arc::new(CountingSink { open: Arc::new(Mutex::new(true)), ..Default::default() });
    let (tx, mut rx) = mpsc::channel(32);
    let pump =
        CapturePump::start(source, sink.clone(), tx, config(60.0, 1920), fakes.factory.clone());
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

#[tokio::test]
async fn coming_back_from_unavailable_forces_a_keyframe() {
    let fakes = fake_encoders(Duration::ZERO, 0);
    let source = SlowSource::new(Duration::from_millis(1));
    let status = source.status.clone();
    *status.lock().unwrap() = CaptureStatus::DesktopUnavailable;
    let sink = Arc::new(CountingSink { open: Arc::new(Mutex::new(true)), ..Default::default() });
    let (tx, _rx) = mpsc::channel(64);
    let pump =
        CapturePump::start(source, sink, tx, config(60.0, 1920), fakes.factory.clone());
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
    let pump = CapturePump::start(source, sink, tx, config(60.0, 1920), fakes.factory.clone());
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
        CapturePump::start(source, sink.clone(), tx, config(60.0, 1920), fakes.factory.clone());
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
    let factory: EncoderFactory = Arc::new(|_, _| Err("no encoder here".into()));
    let source = SlowSource::new(Duration::from_millis(1));
    let sink = Arc::new(CountingSink { open: Arc::new(Mutex::new(true)), ..Default::default() });
    let (tx, mut rx) = mpsc::channel(32);
    let pump = CapturePump::start(source, sink, tx, config(30.0, 1920), factory);
    let events = drain(&mut rx).await;
    assert!(pump.stop(Duration::from_secs(2)).await.is_some());
    assert!(events.iter().any(|e| matches!(e, PumpEvent::Status(CaptureStatus::Unavailable(_)))));
}

// ---------------------------------------------------------------------------
// Keyframes
// ---------------------------------------------------------------------------

#[tokio::test]
async fn the_first_frame_of_a_session_is_a_keyframe() {
    let fakes = fake_encoders(Duration::ZERO, 0);
    let source = SlowSource::new(Duration::from_millis(1));
    let sink = Arc::new(CountingSink { open: Arc::new(Mutex::new(true)), ..Default::default() });
    let (tx, _rx) = mpsc::channel(64);
    let pump = CapturePump::start(source, sink, tx, config(60.0, 1920), fakes.factory.clone());
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
    let pump = CapturePump::start(source, sink, tx, config(60.0, 1920), fakes.factory.clone());
    tokio::time::sleep(Duration::from_millis(50)).await;
    fakes.keyframes.lock().unwrap().clear();

    pump.request_keyframe();
    tokio::time::sleep(Duration::from_millis(60)).await;
    pump.stop(Duration::from_secs(2)).await.expect("source back");

    let keyframes = fakes.keyframes.lock().unwrap().clone();
    assert_eq!(keyframes.first(), Some(&true), "the request applies to the very next frame");
}

#[tokio::test]
async fn a_keyframe_lost_to_an_encode_failure_is_asked_for_again() {
    // The first encode fails, and it was the session's opening keyframe. If the
    // request were consumed by the failed call the peer would never get an IDR.
    let fakes = fake_encoders(Duration::ZERO, 1);
    let source = SlowSource::new(Duration::from_millis(1));
    let sink = Arc::new(CountingSink { open: Arc::new(Mutex::new(true)), ..Default::default() });
    let (tx, _rx) = mpsc::channel(64);
    let pump = CapturePump::start(source, sink, tx, config(60.0, 1920), fakes.factory.clone());
    tokio::time::sleep(Duration::from_millis(60)).await;
    pump.stop(Duration::from_secs(2)).await.expect("source back");

    let keyframes = fakes.keyframes.lock().unwrap().clone();
    assert!(keyframes.len() >= 2, "the pump recovered and kept encoding");
    assert!(keyframes[1], "the keyframe the failed encode swallowed is requested again");
}

// ---------------------------------------------------------------------------
// Pacing: measured, not assumed
// ---------------------------------------------------------------------------

#[test]
fn pacing_claims_nothing_until_it_has_measured_something() {
    let pacing = Pacing::new(30.0, 1920);
    assert_eq!(pacing.measured_encode_time(), None);
    assert_eq!(pacing.frame_budget(), Duration::from_secs_f32(1.0 / 30.0));
}

#[test]
fn an_encode_that_fits_the_budget_changes_nothing() {
    let mut pacing = Pacing::new(30.0, 1920);
    for _ in 0..50 {
        assert!(!pacing.observe(Duration::from_millis(5)));
    }
    assert_eq!(pacing.fps, 30.0);
    assert_eq!(pacing.max_dimension, 1920);
    assert!(pacing.measured_encode_time().is_some());
}

/// The CPU trap, closed: an encode that cannot keep up drops the frame rate
/// first and only then the resolution, and stops at a floor rather than
/// collapsing to nothing.
#[test]
fn an_encode_that_does_not_fit_steps_down_frame_rate_then_resolution() {
    let mut pacing = Pacing::new(30.0, 1920);
    let mut steps = Vec::new();
    for _ in 0..400 {
        if pacing.observe(Duration::from_millis(90)) {
            steps.push((pacing.fps, pacing.max_dimension));
        }
    }
    assert_eq!(
        steps,
        vec![(15.0, 1920), (15.0, 1280)],
        "frame rate is free to change; resolution costs an IDR and a resize"
    );
    for _ in 0..200 {
        assert!(!pacing.observe(Duration::from_millis(90)), "the floor holds");
    }
}

#[test]
fn a_frame_larger_than_the_envelope_is_reduced_to_even_dimensions() {
    let frame = RawFrame { width: 3840, height: 2160, rgb: vec![0u8; 3840 * 2160 * 3] };
    let fitted = fit_for_encode(frame, 1920);
    assert_eq!((fitted.width, fitted.height), (1920, 1080));
    assert_eq!(fitted.rgb.len(), 1920 * 1080 * 3);
}

#[test]
fn an_odd_sized_frame_is_cropped_even_when_it_is_already_small_enough() {
    // 4:2:0 chroma is half-resolution, so an odd edge has no defined last
    // chroma sample and encoders either refuse it or produce a green edge.
    let frame = RawFrame { width: 801, height: 601, rgb: vec![0u8; 801 * 601 * 3] };
    let fitted = fit_for_encode(frame, 1920);
    assert_eq!((fitted.width, fitted.height), (800, 600));
}

#[test]
fn reduction_averages_rather_than_dropping_pixels() {
    // A 2x2 of 0, 255, 255, 0 must average to 127, not pick a corner: dropping
    // pixels is what turns remote text into aliased noise.
    let rgb = vec![
        0, 0, 0, 255, 255, 255, //
        255, 255, 255, 0, 0, 0,
    ];
    let fitted = fit_for_encode(RawFrame { width: 2, height: 2, rgb }, 1);
    assert_eq!((fitted.width, fitted.height), (2, 2), "a 1-pixel target cannot be even; left as-is");

    let rgb = vec![
        0, 0, 0, 255, 255, 255, 0, 0, 0, 255, 255, 255, //
        255, 255, 255, 0, 0, 0, 255, 255, 255, 0, 0, 0, //
        0, 0, 0, 255, 255, 255, 0, 0, 0, 255, 255, 255, //
        255, 255, 255, 0, 0, 0, 255, 255, 255, 0, 0, 0,
    ];
    let fitted = fit_for_encode(RawFrame { width: 4, height: 4, rgb }, 2);
    assert_eq!((fitted.width, fitted.height), (2, 2));
    assert!(fitted.rgb.iter().all(|&v| v == 127), "got {:?}", fitted.rgb);
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
