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
}

impl PeerSession {
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
            ice_servers: config
                .ice_servers
                .iter()
                .map(|s| RTCIceServer {
                    urls: s.urls.clone(),
                    username: s.username.clone(),
                    credential: s.credential.clone(),
                    ..Default::default()
                })
                .collect(),
            ice_transport_policy: if config.force_relay {
                RTCIceTransportPolicy::Relay
            } else {
                RTCIceTransportPolicy::All
            },
            ..Default::default()
        };
        let pc = Arc::new(api.new_peer_connection(rtc_config).await?);

        // The screen track. H.264 — the encoder (Media Foundation on Windows,
        // a synthetic source in the macOS interop harness) hands us Annex-B
        // access units; webrtc-rs packetises.
        let video = Arc::new(TrackLocalStaticSample::new(
            RTCRtpCodecCapability {
                mime_type: MIME_TYPE_H264.to_owned(),
                clock_rate: 90000,
                // Constrained Baseline 3.1, packetization-mode 1: the honest
                // capability floor (WINDOWS-HOST.md §4), matched against
                // whatever the Mac offers.
                sdp_fmtp_line: "level-asymmetry-allowed=1;packetization-mode=1;profile-level-id=42e01f"
                    .to_owned(),
                ..Default::default()
            },
            "screen".to_owned(),
            "rc-media".to_owned(),
        ));
        let sender = pc.add_track(video.clone() as Arc<_>).await?;

        let (tx, rx) = mpsc::channel::<TransportEvent>(256);

        // Nothing read this sender's RTCP before, so a PLI was never seen and a
        // decoder that lost reference frames stayed broken for the rest of the
        // session. Reading it is also what drives the interceptors' own
        // bookkeeping; `read_rtcp` returning an error means the sender closed.
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

        // ICE connection state -> owner.
        {
            let tx = tx.clone();
            pc.on_ice_connection_state_change(Box::new(move |state| {
                let tx = tx.clone();
                Box::pin(async move {
                    let _ = tx.send(TransportEvent::IceState(state.into())).await;
                })
            }));
        }

        // Trickle candidates -> owner -> signaling.
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

        // The offerer's in-band channels arrive here.
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
                        // §6: nothing else may exist. Ignore, don't kill the session.
                        return;
                    }
                    if is_ctrl {
                        *ctrl_slot.lock().await = Some(channel.clone());
                    }

                    // Track readiness: ChannelsReady once both are open.
                    {
                        let tx = tx.clone();
                        let ctrl_slot = ctrl_slot.clone();
                        let this = channel.clone();
                        channel.on_open(Box::new(move || {
                            let tx = tx.clone();
                            let ctrl_slot = ctrl_slot.clone();
                            Box::pin(async move {
                                // `hi` opening is the later of the two in
                                // practice; announce readiness when ctrl is
                                // known and this channel opened. A false early
                                // signal is impossible because sends on an
                                // unopened channel error and the owner retries
                                // nothing before ChannelsReady.
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
                            // §5/§6 frames are text JSON envelopes.
                            let Ok(env) = Envelope::decode(&msg.data) else {
                                return; // unknown/broken frames are ignored (§0)
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

        Ok((Self { pc, ctrl: ctrl_slot, video }, rx))
    }

    /// Apply the controller's offer and produce this host's answer. Also the
    /// path for ICE-restart offers — same call, new offer in, new answer out.
    pub async fn handle_offer(&self, sdp: &str) -> Result<String, TransportError> {
        let offer = RTCSessionDescription::offer(sdp.to_string())?;
        self.pc.set_remote_description(offer).await?;
        let answer = self.pc.create_answer(None).await?;
        self.pc.set_local_description(answer).await?;
        let local = self
            .pc
            .local_description()
            .await
            .ok_or_else(|| TransportError::WebRtc("no local description".into()))?;
        Ok(local.sdp)
    }

    pub async fn add_remote_candidate(&self, ice: &sig::Ice) -> Result<(), TransportError> {
        if ice.candidate.is_empty() {
            return Ok(()); // end-of-candidates; webrtc-rs needs no explicit signal
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

    pub async fn close(&self) {
        let _ = self.pc.close().await;
    }
}
