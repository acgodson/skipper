//! The capture -> encode -> track loop, and its lifecycle.
//!
//! The loop is blocking: `AcquireNextFrame` and a software encoder are both
//! blocking calls, so it lives on a `spawn_blocking` thread. That makes
//! cancellation the whole problem. `abort()` on a blocking task does nothing
//! until the closure yields, and a closure that never yields is simply leaked
//! along with its encoder and its capture device — which is why a second session
//! used to find the frame source gone.
//!
//! So the loop is cancelled **cooperatively**: it checks a stop flag between
//! frames and inside every sleep, and when it exits it **hands the frame source
//! back** so the next session can reuse it. Nothing here outlives
//! [`CapturePump::stop`]: the encoder is owned by the closure and dropped with
//! it, and the pump only runs while a session needs it.

use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
use std::time::{Duration, Instant};

use bytes::Bytes;
use rc_input::DisplayGeometry;
use tokio::sync::mpsc;

use crate::media::{fit_for_encode, CaptureStatus, FrameSource, Pacing, VideoEncoder};

/// Where encoded samples go. Abstracted so the lifecycle is testable without a
/// peer connection, and because the pump must not know about WebRTC.
pub trait VideoSink: Send + Sync + 'static {
    /// Blocking: the pump is already on a blocking thread.
    fn write(&self, sample: Bytes, duration: Duration) -> Result<(), String>;
}

/// What the pump tells the host about, so the host can suspend input, publish
/// `display_info`, and log the encode path.
#[derive(Debug, Clone, PartialEq)]
pub enum PumpEvent {
    Status(CaptureStatus),
    Geometry(Option<DisplayGeometry>),
    /// The envelope changed because the measured encode cost did not fit.
    SteppedDown { fps: f32, max_dimension: u32, measured_encode: Option<Duration> },
}

/// Builds an encoder for a given bitrate and frame rate. Called again when the
/// pacing steps down, so the rate controller is never left budgeting for a
/// cadence the pump no longer runs at.
pub type EncoderFactory =
    Arc<dyn Fn(u32, f32) -> Result<Box<dyn VideoEncoder>, String> + Send + Sync>;

pub struct PumpConfig {
    pub bitrate_bps: u32,
    pub pacing: Pacing,
}

/// A running pump. Dropping this does **not** stop the loop; call
/// [`CapturePump::stop`], which is the only path that recovers the source.
pub struct CapturePump<F> {
    stop: Arc<AtomicBool>,
    keyframe: Arc<AtomicBool>,
    handle: tokio::task::JoinHandle<F>,
}

impl<F: FrameSource + 'static> CapturePump<F> {
    pub fn start(
        source: F,
        sink: Arc<dyn VideoSink>,
        events: mpsc::Sender<PumpEvent>,
        config: PumpConfig,
        encoders: EncoderFactory,
    ) -> Self {
        let stop = Arc::new(AtomicBool::new(false));
        let keyframe = Arc::new(AtomicBool::new(true));
        let handle = {
            let stop = stop.clone();
            let keyframe = keyframe.clone();
            tokio::task::spawn_blocking(move || {
                run(source, sink, events, config, encoders, stop, keyframe)
            })
        };
        Self { stop, keyframe, handle }
    }

    /// Ask for an IDR on the next frame. This is what a PLI from the peer means:
    /// its decoder has lost reference frames and nothing it receives will decode
    /// until a keyframe arrives.
    pub fn request_keyframe(&self) {
        self.keyframe.store(true, Ordering::Release);
    }

    /// Stop the loop and take the frame source back.
    ///
    /// `None` means the loop did not finish inside `grace` — it is still asked
    /// to stop and will drop the source itself, but the caller must treat the
    /// source as gone and open a new one rather than wait on a hung device.
    pub async fn stop(self, grace: Duration) -> Option<F> {
        self.stop.store(true, Ordering::Release);
        match tokio::time::timeout(grace, self.handle).await {
            Ok(Ok(source)) => Some(source),
            Ok(Err(_)) | Err(_) => None,
        }
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

fn run<F: FrameSource>(
    mut source: F,
    sink: Arc<dyn VideoSink>,
    events: mpsc::Sender<PumpEvent>,
    config: PumpConfig,
    encoders: EncoderFactory,
    stop: Arc<AtomicBool>,
    keyframe: Arc<AtomicBool>,
) -> F {
    let mut pacing = config.pacing;
    let mut encoder = match encoders(config.bitrate_bps, pacing.fps) {
        Ok(e) => e,
        Err(e) => {
            publish(
                &events,
                &stop,
                PumpEvent::Status(CaptureStatus::Unavailable(format!("encoder: {e}"))),
            );
            return source;
        }
    };

    let mut last_status: Option<CaptureStatus> = None;
    let mut last_geometry: Option<Option<DisplayGeometry>> = None;
    let mut failures = 0u32;

    while !stop.load(Ordering::Acquire) {
        let geometry = source.geometry();
        if last_geometry.as_ref() != Some(&geometry) {
            last_geometry = Some(geometry);
            if !publish(&events, &stop, PumpEvent::Geometry(geometry)) {
                break;
            }
            // A resolution or scale change invalidates every reference frame the
            // peer holds.
            keyframe.store(true, Ordering::Release);
        }

        let status = source.status();
        if last_status.as_ref() != Some(&status) {
            last_status = Some(status.clone());
            if !publish(&events, &stop, PumpEvent::Status(status.clone())) {
                break;
            }
            if status.is_live() {
                keyframe.store(true, Ordering::Release);
            }
        }

        if !status.is_live() {
            // Nothing is sent while the screen is not ours to send.
            nap(&stop, pacing.frame_budget());
            continue;
        }

        let Some(frame) = source.next_frame() else {
            nap(&stop, pacing.frame_budget());
            continue;
        };

        let started = Instant::now();
        let frame = fit_for_encode(frame, pacing.max_dimension);
        let wants_keyframe = keyframe.swap(false, Ordering::AcqRel);
        let encoded = encoder.encode(&frame, wants_keyframe);
        let cost = started.elapsed();

        match encoded {
            Ok(sample) => {
                failures = 0;
                if !sample.is_empty() && sink.write(sample, pacing.frame_budget()).is_err() {
                    break; // the track is gone; so is the session
                }
            }
            Err(detail) => {
                failures += 1;
                // The dropped frame was going to be a keyframe; do not lose that.
                if wants_keyframe {
                    keyframe.store(true, Ordering::Release);
                }
                if failures >= ENCODER_FAILURE_LIMIT {
                    publish(
                        &events,
                        &stop,
                        PumpEvent::Status(CaptureStatus::Unavailable(format!(
                            "encoder failed {failures} times: {detail}"
                        ))),
                    );
                    break;
                }
                match encoders(config.bitrate_bps, pacing.fps) {
                    Ok(fresh) => {
                        encoder = fresh;
                        keyframe.store(true, Ordering::Release);
                    }
                    Err(_) => continue,
                }
            }
        }

        if pacing.observe(cost) {
            let event = PumpEvent::SteppedDown {
                fps: pacing.fps,
                max_dimension: pacing.max_dimension,
                measured_encode: Some(cost),
            };
            if !publish(&events, &stop, event) {
                break;
            }
            if let Ok(fresh) = encoders(config.bitrate_bps, pacing.fps) {
                encoder = fresh;
                keyframe.store(true, Ordering::Release);
            }
        }

        nap(&stop, pacing.frame_budget().saturating_sub(started.elapsed()));
    }

    source
}
