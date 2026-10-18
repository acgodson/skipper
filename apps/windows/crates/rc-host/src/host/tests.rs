use std::sync::Mutex as StdMutex;
use std::time::Instant;

use super::*;
use crate::api::Entitlement;
use crate::inject::RecordingInjector;
use crate::media::{SyntheticBackend, SyntheticSource};

struct Scratch(std::path::PathBuf);

impl Scratch {
    fn new(tag: &str) -> Self {
        let path = std::env::temp_dir().join(format!("rc-host-{tag}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&path);
        Self(path)
    }
}

impl Drop for Scratch {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}

struct DiscardingSink;

impl VideoSink for DiscardingSink {
    fn write(&self, _sample: bytes::Bytes, _captured_at: Instant) -> Result<(), String> {
        Ok(())
    }
}

struct NullEncoder;

impl VideoEncoder for NullEncoder {
    fn encode(&mut self, _frame: &crate::media::RawFrame, _keyframe: bool) -> Result<bytes::Bytes, String> {
        Ok(bytes::Bytes::from_static(b"au"))
    }

    fn name(&self) -> &'static str {
        "null"
    }
}

fn host(scratch: &Scratch, ceiling: QualityCeiling) -> Host<RecordingInjector, SyntheticBackend> {
    let key = DeviceKey::generate();
    let identity = IdentityRecord::new_unregistered(
        &key,
        rc_identity::access_code::generate(),
        "unix:0".into(),
    );
    let config = HostConfig {
        signaling_url: "wss://api.example.invalid/ws".into(),
        label: "test".into(),
        unattended_override: Some(false),
        force_relay: false,
        quality_ceiling: ceiling,
        media_stats: false,
    };
    let (host, _events) = Host::new(
        config,
        identity,
        key,
        RecordingInjector::default(),
        SyntheticBackend { width: 64, height: 48 },
        SecretStore::open(scratch.0.clone()).unwrap(),
    );
    host
}

fn entitlement(max_quality: &str) -> Entitlement {
    serde_json::from_str(&format!(
        r#"{{"status":"active","limits":{{"maxQuality":"{max_quality}"}},"refreshAfterSec":60}}"#
    ))
    .unwrap()
}

fn quality(mode: &str) -> rc_proto::envelope::Envelope {
    rc_proto::envelope::Envelope::new(
        ctrl_msg::QUALITY,
        "",
        "",
        0,
        Some(&ctrlp::Quality { mode: mode.into() }),
    )
    .unwrap()
}

/// Starts a pump on the host whose encoder factory records each bitrate asked
/// for. The pump ends when its event receiver goes, so the caller holds it.
fn start_pump(
    host: &mut Host<RecordingInjector, SyntheticBackend>,
) -> (Arc<StdMutex<Vec<u32>>>, mpsc::Receiver<PumpEvent>) {
    let bitrates = Arc::new(StdMutex::new(Vec::new()));
    let recorded = bitrates.clone();
    let factory: EncoderFactory = Arc::new(move |bitrate, _fps| {
        recorded.lock().unwrap().push(bitrate);
        Ok(Box::new(NullEncoder) as Box<dyn VideoEncoder>)
    });
    let (tx, events) = mpsc::channel(1024);
    host.pump = Some(CapturePump::start(
        SyntheticSource::new(64, 48),
        Arc::new(DiscardingSink),
        tx,
        PumpConfig { quality: host.permitted_quality(), diagnostics: false },
        factory,
    ));
    (bitrates, events)
}

async fn settle() {
    tokio::time::sleep(Duration::from_millis(150)).await;
}

#[tokio::test]
async fn a_quality_message_reconfigures_the_running_encoder_within_the_ceiling() {
    let scratch = Scratch::new("quality-sharp");
    let ceiling = QualityCeiling::default();
    ceiling.record(Some(&entitlement("sharp")), now_ms());
    let mut host = host(&scratch, ceiling);
    let (bitrates, _events) = start_pump(&mut host);
    settle().await;

    host.on_ctrl(quality("sharp"));
    settle().await;
    host.on_ctrl(quality("smooth"));
    settle().await;
    host.stop_capture().await;

    assert_eq!(*bitrates.lock().unwrap(), vec![2_000_000, 8_000_000, 1_000_000]);
}

#[tokio::test]
async fn sharp_without_an_entitlement_is_configured_as_auto() {
    let scratch = Scratch::new("quality-none");
    let mut host = host(&scratch, QualityCeiling::default());
    let (bitrates, _events) = start_pump(&mut host);
    settle().await;

    host.on_ctrl(quality("sharp"));
    settle().await;
    host.stop_capture().await;

    assert_eq!(host.permitted_quality(), QualityMode::Auto);
    assert_eq!(
        *bitrates.lock().unwrap(),
        vec![2_000_000],
        "nothing above the auto ceiling is ever built"
    );
}

#[tokio::test]
async fn a_stale_ceiling_clamps_to_auto_and_a_trial_ceiling_holds() {
    let scratch = Scratch::new("quality-stale");
    let ceiling = QualityCeiling::default();
    ceiling.record(Some(&entitlement("sharp")), now_ms() - 61_000);
    let mut host = host(&scratch, ceiling.clone());
    host.apply_quality(QualityMode::Sharp);
    assert_eq!(host.permitted_quality(), QualityMode::Auto, "stale");

    ceiling.record(Some(&entitlement("auto")), now_ms());
    assert_eq!(host.permitted_quality(), QualityMode::Auto, "stated auto");

    ceiling.record(Some(&entitlement("sharp")), now_ms());
    host.apply_quality(QualityMode::Smooth);
    assert_eq!(host.permitted_quality(), QualityMode::Smooth, "a request below the ceiling stands");
}
