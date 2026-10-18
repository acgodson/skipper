//! The Windows host's peer transport, mirroring `PeerSession.swift` from the
//! answerer's seat.
//!
//! Division of labour, fixed by the Mac controller's behaviour:
//!
//! * The **controller is the offerer**. It creates both data channels in-band
//!   (`ctrl` reliable/ordered, `hi` unreliable/unordered) and offers a
//!   `recvonly` video transceiver. This host therefore never creates channels
//!   and never offers — it answers, attaches its sending track to the offered
//!   m-line, and re-answers on ICE-restart offers.
//! * Data-channel frames are **text** (JSON envelopes, PROTOCOL.md §5/§6),
//!   matching `channel.sendData(RTCDataBuffer(data:, isBinary: false))` on the
//!   Mac side.

#![forbid(unsafe_code)]

use std::sync::Arc;

use bytes::Bytes;
use rc_proto::envelope::Envelope;
use rc_proto::signaling as sig;
use tokio::sync::{mpsc, Mutex};
use webrtc::api::interceptor_registry::register_default_interceptors;
use webrtc::api::media_engine::{MediaEngine, MIME_TYPE_H264};
use webrtc::api::APIBuilder;
use webrtc::data_channel::data_channel_message::DataChannelMessage;
use webrtc::data_channel::RTCDataChannel;
use webrtc::ice_transport::ice_candidate::{RTCIceCandidate, RTCIceCandidateInit};
use webrtc::ice_transport::ice_connection_state::RTCIceConnectionState;
use webrtc::ice_transport::ice_server::RTCIceServer;
use webrtc::interceptor::registry::Registry;
use webrtc::media::Sample;
use webrtc::peer_connection::configuration::RTCConfiguration;
use webrtc::peer_connection::policy::ice_transport_policy::RTCIceTransportPolicy;
use webrtc::peer_connection::sdp::session_description::RTCSessionDescription;
use webrtc::peer_connection::RTCPeerConnection;
use webrtc::rtp_transceiver::rtp_codec::RTCRtpCodecCapability;
use webrtc::track::track_local::track_local_static_sample::TrackLocalStaticSample;

#[derive(Debug, thiserror::Error)]
pub enum TransportError {
    #[error("webrtc: {0}")]
    WebRtc(String),
    #[error("channel not open")]
    NotOpen,
}

impl From<webrtc::Error> for TransportError {
    fn from(e: webrtc::Error) -> Self {
        Self::WebRtc(e.to_string())
    }
}

/// Mirror of the Swift `ICELinkState`, so `rc-session` plugs straight in.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum IceState {
    New,
    Checking,
    Connected,
    Completed,
    Disconnected,
    Failed,
    Closed,
}

impl From<RTCIceConnectionState> for IceState {
    fn from(s: RTCIceConnectionState) -> Self {
        match s {
            RTCIceConnectionState::New => Self::New,
            RTCIceConnectionState::Checking => Self::Checking,
            RTCIceConnectionState::Connected => Self::Connected,
            RTCIceConnectionState::Completed => Self::Completed,
            RTCIceConnectionState::Disconnected => Self::Disconnected,
            RTCIceConnectionState::Failed => Self::Failed,
            RTCIceConnectionState::Closed => Self::Closed,
            _ => Self::New,
        }
    }
}

/// Everything the owner needs to react to, in one stream.
#[derive(Debug)]
pub enum TransportEvent {
    IceState(IceState),
    /// A local candidate to relay via signaling; `None` is end-of-candidates.
    LocalCandidate(Option<RTCIceCandidateInit>),
    /// A decoded `ctrl` envelope. §5 handling belongs to the input layer.
    Ctrl(Envelope),
    /// A decoded `hi` envelope (only `mouse_move` is legal there, §6).
    Hi(Envelope),
    /// Both channels are open; the session is usable for control.
    ChannelsReady,
    /// The peer's decoder asked for a keyframe (RTCP PLI, or FIR). Until one
    /// arrives nothing it receives will decode, so this is not advisory.
    KeyframeRequested,
}

fn ice_servers(servers: &[sig::IceServer]) -> Vec<RTCIceServer> {
    servers
        .iter()
        .map(|s| RTCIceServer {
            urls: s.urls.clone(),
            username: s.username.clone(),
            credential: s.credential.clone(),
            ..Default::default()
        })
        .collect()
}

fn transport_policy(force_relay: bool) -> RTCIceTransportPolicy {
    match force_relay {
        true => RTCIceTransportPolicy::Relay,
        false => RTCIceTransportPolicy::All,
    }
}

pub struct PeerConfig {
    pub ice_servers: Vec<sig::IceServer>,
    /// `RC_ICE_POLICY=relay` — force TURN, the switch that proved the relay on
    /// the Mac side and the fallback when direct paths fail.
    pub force_relay: bool,
}

pub struct PeerSession {
    pc: Arc<RTCPeerConnection>,
    ctrl: Arc<Mutex<Option<Arc<RTCDataChannel>>>>,
    video: Arc<TrackLocalStaticSample>,
    video_clock: Mutex<RtpClock>,
    has_turn: bool,
}

impl PeerSession {
    /// The screen track is H.264: the encoder (Media Foundation on Windows, a synthetic source in the macOS interop harness) hands over Annex-B access units and webrtc-rs packetises.
    ///
    /// The advertised codec is Constrained Baseline, level 5.0, packetization-mode 1. The level is 5.0 (`...32`) and not 3.1 (`...1f`) because 3.1 caps at 3600 macroblocks (1280x720) and this host sends up to 2560x1440 (14400). Advertising a level we exceed is the same dishonesty WINDOWS-HOST.md §4 warns about, pointing the other way. Level 5.0 allows 22080 macroblocks, comfortably more than the sharp rung's widest frame (2560 wide).
    ///
    /// Stating it is safe: RFC 6184 §8.2.2 excludes the level part of profile-level-id from symmetric use, and webrtc-rs compares only profile_idc and profile_iop (`42e0`) when matching an offer, so the level does not affect negotiation. With `level-asymmetry-allowed=1` it describes what this host sends, not what it could decode.
    ///
    /// The video sender's RTCP is read continuously. Nothing read it before, so a PLI was never seen and a decoder that lost reference frames stayed broken for the rest of the session. Reading it is also what drives the interceptors' own bookkeeping; `read_rtcp` returning an error means the sender closed.
    ///
    /// §6: nothing else may exist. An unexpected channel is ignored rather than killing the session.
    ///
    /// `hi` opening is the later of the two in practice, so readiness is announced when ctrl is known and this channel opened. A false early signal is impossible because sends on an unopened channel error and the owner retries nothing before `ChannelsReady`.
    ///
    /// §5/§6 frames are text JSON envelopes; unknown or broken frames are ignored (§0).
    pub async fn new(
        config: PeerConfig,
    ) -> Result<(Self, mpsc::Receiver<TransportEvent>), TransportError> {
        let mut media = MediaEngine::default();
        media.register_default_codecs()?;
        let mut registry = Registry::new();
        registry = register_default_interceptors(registry, &mut media)?;
        let api = APIBuilder::new()
            .with_media_engine(media)
            .with_interceptor_registry(registry)
            .build();

        let rtc_config = RTCConfiguration {
            ice_servers: ice_servers(&config.ice_servers),
            ice_transport_policy: transport_policy(config.force_relay),
            ..Default::default()
        };
        let pc = Arc::new(api.new_peer_connection(rtc_config).await?);

        let video = Arc::new(TrackLocalStaticSample::new(
            RTCRtpCodecCapability {
                mime_type: MIME_TYPE_H264.to_owned(),
                clock_rate: 90000,
                sdp_fmtp_line: "level-asymmetry-allowed=1;packetization-mode=1;profile-level-id=42e032"
                    .to_owned(),
                ..Default::default()
            },
            "screen".to_owned(),
            "rc-media".to_owned(),
        ));
        let sender = pc.add_track(video.clone() as Arc<_>).await?;

        let (tx, rx) = mpsc::channel::<TransportEvent>(256);

        {
            let tx = tx.clone();
            tokio::spawn(async move {
                while let Ok((packets, _)) = sender.read_rtcp().await {
                    let asked = packets.iter().any(|p| {
                        let any = p.as_any();
                        any.downcast_ref::<webrtc::rtcp::payload_feedbacks::picture_loss_indication::PictureLossIndication>().is_some()
                            || any.downcast_ref::<webrtc::rtcp::payload_feedbacks::full_intra_request::FullIntraRequest>().is_some()
                    });
                    if asked && tx.send(TransportEvent::KeyframeRequested).await.is_err() {
                        break;
                    }
                }
            });
        }
        let ctrl_slot: Arc<Mutex<Option<Arc<RTCDataChannel>>>> = Arc::new(Mutex::new(None));

        {
            let tx = tx.clone();
            pc.on_ice_connection_state_change(Box::new(move |state| {
                let tx = tx.clone();
                Box::pin(async move {
                    let _ = tx.send(TransportEvent::IceState(state.into())).await;
                })
            }));
        }

        {
            let tx = tx.clone();
            pc.on_ice_candidate(Box::new(move |candidate: Option<RTCIceCandidate>| {
                let tx = tx.clone();
                Box::pin(async move {
                    let init = match candidate {
                        Some(c) => c.to_json().ok(),
                        None => None,
                    };
                    let _ = tx.send(TransportEvent::LocalCandidate(init)).await;
                })
            }));
        }

        {
            let tx = tx.clone();
            let ctrl_slot = ctrl_slot.clone();
            pc.on_data_channel(Box::new(move |channel: Arc<RTCDataChannel>| {
                let tx = tx.clone();
                let ctrl_slot = ctrl_slot.clone();
                Box::pin(async move {
                    let label = channel.label().to_string();
                    let is_ctrl = label == "ctrl";
                    let is_hi = label == "hi";
                    if !is_ctrl && !is_hi {
                        return;
                    }
                    if is_ctrl {
                        *ctrl_slot.lock().await = Some(channel.clone());
                    }

                    {
                        let tx = tx.clone();
                        let ctrl_slot = ctrl_slot.clone();
                        let this = channel.clone();
                        channel.on_open(Box::new(move || {
                            let tx = tx.clone();
                            let ctrl_slot = ctrl_slot.clone();
                            Box::pin(async move {
                                let ctrl_known = ctrl_slot.lock().await.is_some();
                                if ctrl_known && this.label() == "hi" {
                                    let _ = tx.send(TransportEvent::ChannelsReady).await;
                                }
                            })
                        }));
                    }

                    let tx2 = tx.clone();
                    channel.on_message(Box::new(move |msg: DataChannelMessage| {
                        let tx = tx2.clone();
                        let is_ctrl = is_ctrl;
                        Box::pin(async move {
                            let Ok(env) = Envelope::decode(&msg.data) else {
                                return;
                            };
                            let event = if is_ctrl {
                                TransportEvent::Ctrl(env)
                            } else {
                                TransportEvent::Hi(env)
                            };
                            let _ = tx.send(event).await;
                        })
                    }));
                })
            }));
        }

        let has_turn = config
            .ice_servers
            .iter()
            .any(|s| !s.credential.is_empty() || !s.username.is_empty());
        Ok((
            Self { pc, ctrl: ctrl_slot, video, video_clock: Mutex::new(RtpClock::default()), has_turn },
            rx,
        ))
    }

    /// Install the controller's offer. Also the path for ICE-restart offers.
    ///
    /// Separate from [`Self::answer`] because §2.12 puts a check between the
    /// two: after `setRemoteDescription` and before any remote candidate, the
    /// fingerprints the stack actually installed must equal the verified ones.
    /// [`Self::installed_remote_sdp`] is how that check reads them.
    pub async fn set_remote_offer(&self, sdp: &str) -> Result<(), TransportError> {
        let offer = RTCSessionDescription::offer(sdp.to_string())?;
        self.pc.set_remote_description(offer).await?;
        Ok(())
    }

    /// The remote description as the stack reports it, which is what §2.12's
    /// post-install check reads rather than the bytes that arrived.
    pub async fn installed_remote_sdp(&self) -> Option<String> {
        self.pc.remote_description().await.map(|d| d.sdp)
    }

    pub async fn answer(&self) -> Result<String, TransportError> {
        let answer = self.pc.create_answer(None).await?;
        self.pc.set_local_description(answer).await?;
        let local = self
            .pc
            .local_description()
            .await
            .ok_or_else(|| TransportError::WebRtc("no local description".into()))?;
        Ok(local.sdp)
    }

    /// Whether this connection was built with any TURN credentials, which is
    /// the only moment ICE servers can be chosen: `set_configuration` is not
    /// implemented in webrtc-rs 0.11 (it is commented out in
    /// `peer_connection/mod.rs`), and the gatherer is built with the
    /// connection, so a list that arrives later reaches the *next* one.
    pub fn gathers_relay_candidates(&self) -> bool {
        self.has_turn
    }

    /// An empty candidate is end-of-candidates, which webrtc-rs needs no explicit signal for.
    pub async fn add_remote_candidate(&self, ice: &sig::Ice) -> Result<(), TransportError> {
        if ice.candidate.is_empty() {
            return Ok(());
        }
        self.pc
            .add_ice_candidate(RTCIceCandidateInit {
                candidate: ice.candidate.clone(),
                sdp_mid: Some(ice.sdp_mid.clone()),
                sdp_mline_index: Some(ice.sdp_mline_index as u16),
                ..Default::default()
            })
            .await?;
        Ok(())
    }

    /// Send one `ctrl` envelope (text frame, §5).
    pub async fn send_ctrl<T: serde::Serialize>(
        &self,
        msg_type: &str,
        payload: &T,
    ) -> Result<(), TransportError> {
        let now_ms = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map(|d| d.as_millis() as i64)
            .unwrap_or(0);
        let env = Envelope::new(msg_type, "", "", now_ms, Some(payload))
            .map_err(|e| TransportError::WebRtc(e.to_string()))?;
        let bytes = env.encode().map_err(|e| TransportError::WebRtc(e.to_string()))?;
        let guard = self.ctrl.lock().await;
        let channel = guard.as_ref().ok_or(TransportError::NotOpen)?;
        channel
            .send_text(String::from_utf8(bytes).expect("json is utf8"))
            .await?;
        Ok(())
    }

    /// Feed one encoded H.264 access unit (Annex-B) into the screen track.
    pub async fn write_video_sample(
        &self,
        data: Bytes,
        duration: std::time::Duration,
    ) -> Result<(), TransportError> {
        self.video
            .write_sample(&Sample { data, duration, ..Default::default() })
            .await?;
        Ok(())
    }

    /// Feed one access unit whose picture was captured at `captured_at`, with
    /// its RTP timestamp on the capture clock.
    ///
    /// `write_video_sample` stamps each sample with the running total of the
    /// durations before it, so a fixed per-frame duration lets the RTP clock
    /// fall seconds behind real time whenever the screen sits still or frames
    /// are dropped, and the receiver's timing model is built from exactly that
    /// relation between RTP time and arrival time. An empty
    /// sample carries no packets but advances the timestamp, so it is used to
    /// bring the clock up to `captured_at` before the frame goes out.
    pub async fn write_video_frame(
        &self,
        data: Bytes,
        captured_at: std::time::Instant,
    ) -> Result<(), TransportError> {
        let mut clock = self.video_clock.lock().await;
        let gap = clock.advance_to(captured_at);
        if !gap.is_zero() {
            self.write_video_sample(Bytes::new(), gap).await?;
        }
        self.write_video_sample(data, std::time::Duration::ZERO).await
    }

    pub async fn close(&self) {
        let _ = self.pc.close().await;
    }
}

const VIDEO_CLOCK_RATE: u64 = 90_000;

/// Keeps the video track's RTP timestamps on the capture clock: the first
/// frame is tick zero and every later one sits at its capture time since then.
/// Counted in whole ticks, so rounding in the packetiser never accumulates.
#[derive(Debug, Default)]
pub struct RtpClock {
    origin: Option<std::time::Instant>,
    ticks: u64,
}

impl RtpClock {
    /// How far the RTP clock must move before a frame captured at `at` goes
    /// out. Zero for the first frame and for one captured no later than the
    /// clock already stands; the clock never runs backwards.
    pub fn advance_to(&mut self, at: std::time::Instant) -> std::time::Duration {
        let origin = *self.origin.get_or_insert(at);
        let target = at.saturating_duration_since(origin).as_nanos() as u64 * VIDEO_CLOCK_RATE
            / 1_000_000_000;
        let step = target.saturating_sub(self.ticks);
        self.ticks += step;
        std::time::Duration::from_nanos((step * 1_000_000_000).div_ceil(VIDEO_CLOCK_RATE))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::time::{Duration, Instant};

    fn ticks(d: Duration) -> u64 {
        (d.as_secs_f64() * VIDEO_CLOCK_RATE as f64) as u64
    }

    #[test]
    fn the_rtp_clock_follows_capture_time_across_a_still_screen() {
        let mut clock = RtpClock::default();
        let start = Instant::now();
        assert_eq!(clock.advance_to(start), Duration::ZERO);
        assert_eq!(ticks(clock.advance_to(start + Duration::from_millis(33))), 2970);
        assert_eq!(
            ticks(clock.advance_to(start + Duration::from_millis(5033))),
            450_000,
            "five idle seconds move the clock five seconds, not one frame"
        );
    }

    #[test]
    fn the_rtp_clock_does_not_drift_or_run_backwards() {
        let mut clock = RtpClock::default();
        let start = Instant::now();
        clock.advance_to(start);
        let mut total = 0;
        for frame in 1..=108_000u64 {
            total += ticks(clock.advance_to(start + Duration::from_nanos(frame * 33_333_333)));
        }
        assert_eq!(total, 108_000 * 33_333_333 * 90_000 / 1_000_000_000);
        assert_eq!(clock.advance_to(start), Duration::ZERO);
    }
}
