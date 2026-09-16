//! Loopback integration: a fake controller shaped exactly like the Mac app —
//! offerer, in-band `ctrl` (reliable/ordered) and `hi` (unreliable, ordered:
//! false, maxRetransmits: 0) channels, a recvonly video transceiver — against
//! the real `PeerSession`.
//!
//! Runs entirely on this machine: webrtc-rs is pure Rust, so ICE, DTLS, SCTP
//! and SRTP all execute for real over loopback. What this cannot prove is
//! interop with Google libwebrtc — that is what the synthetic-host run against
//! the actual Mac app is for (see WINDOWS-HOST.md §10).

use std::sync::Arc;
use std::time::Duration;

use bytes::Bytes;
use rc_proto::consts::ctrl as ctrl_msg;
use rc_transport::{PeerConfig, PeerSession, TransportEvent};
use tokio::sync::mpsc;
use webrtc::api::interceptor_registry::register_default_interceptors;
use webrtc::api::media_engine::MediaEngine;
use webrtc::api::APIBuilder;
use webrtc::data_channel::data_channel_init::RTCDataChannelInit;
use webrtc::ice_transport::ice_candidate::RTCIceCandidateInit;
use webrtc::interceptor::registry::Registry;
use webrtc::peer_connection::configuration::RTCConfiguration;
use webrtc::rtp_transceiver::rtp_codec::RTPCodecType;
use webrtc::rtp_transceiver::rtp_transceiver_direction::RTCRtpTransceiverDirection;
use webrtc::rtp_transceiver::RTCRtpTransceiverInit;

async fn next_event(
    rx: &mut mpsc::Receiver<TransportEvent>,
    what: &str,
    mut want: impl FnMut(&TransportEvent) -> bool,
) -> TransportEvent {
    let deadline = tokio::time::Instant::now() + Duration::from_secs(15);
    loop {
        let remaining = deadline.saturating_duration_since(tokio::time::Instant::now());
        let ev = tokio::time::timeout(remaining, rx.recv())
            .await
            .unwrap_or_else(|_| panic!("timed out waiting for {what}"))
            .unwrap_or_else(|| panic!("event stream ended waiting for {what}"));
        if want(&ev) {
            return ev;
        }
    }
}

#[tokio::test(flavor = "multi_thread")]
async fn a_mac_shaped_controller_negotiates_channels_and_media() {
    // ---- the fake controller, shaped like PeerSession.swift's offerer ------
    let mut media = MediaEngine::default();
    media.register_default_codecs().unwrap();
    let mut registry = Registry::new();
    registry = register_default_interceptors(registry, &mut media).unwrap();
    let api = APIBuilder::new()
        .with_media_engine(media)
        .with_interceptor_registry(registry)
        .build();
    let controller = Arc::new(api.new_peer_connection(RTCConfiguration::default()).await.unwrap());

    let ctrl_ch = controller
        .create_data_channel("ctrl", Some(RTCDataChannelInit { ordered: Some(true), ..Default::default() }))
        .await
        .unwrap();
    let hi_ch = controller
        .create_data_channel(
            "hi",
            Some(RTCDataChannelInit {
                ordered: Some(false),
                max_retransmits: Some(0),
                ..Default::default()
            }),
        )
        .await
        .unwrap();
    controller
        .add_transceiver_from_kind(
            RTPCodecType::Video,
            Some(RTCRtpTransceiverInit {
                direction: RTCRtpTransceiverDirection::Recvonly,
                send_encodings: vec![],
            }),
        )
        .await
        .unwrap();

    // The controller must see RTP arrive on its recvonly transceiver.
    let (track_tx, mut track_rx) = mpsc::channel::<String>(4);
    controller.on_track(Box::new(move |track, _, _| {
        let track_tx = track_tx.clone();
        Box::pin(async move {
            let codec = track.codec().capability.mime_type.clone();
            // Reading one packet proves SRTP actually delivered payload.
            if track.read_rtp().await.is_ok() {
                let _ = track_tx.send(codec).await;
            }
        })
    }));

    // ---- the host under test ----------------------------------------------
    let (host, mut host_events) =
        PeerSession::new(PeerConfig { ice_servers: vec![], force_relay: false }).await.unwrap();

    // ---- SDP + trickle over "signaling" (direct calls here) ----------------
    let offer = controller.create_offer(None).await.unwrap();
    controller.set_local_description(offer.clone()).await.unwrap();
    let answer_sdp = host.handle_offer(&offer.sdp).await.unwrap();
    assert!(
        answer_sdp.contains("H264") || answer_sdp.contains("h264"),
        "the answer must accept H.264:\n{answer_sdp}"
    );
    controller
        .set_remote_description(
            webrtc::peer_connection::sdp::session_description::RTCSessionDescription::answer(
                answer_sdp,
            )
            .unwrap(),
        )
        .await
        .unwrap();

    // Controller candidates -> host.
    let (cand_tx, mut cand_rx) = mpsc::channel::<RTCIceCandidateInit>(16);
    controller.on_ice_candidate(Box::new(move |c| {
        let cand_tx = cand_tx.clone();
        Box::pin(async move {
            if let Some(c) = c {
                if let Ok(init) = c.to_json() {
                    let _ = cand_tx.send(init).await;
                }
            }
        })
    }));
    let host_ref = &host;
    let feed_controller_candidates = async move {
        while let Some(init) = cand_rx.recv().await {
            let ice = rc_proto::signaling::Ice {
                session_id: "loopback".into(),
                candidate: init.candidate,
                sdp_mid: init.sdp_mid.unwrap_or_default(),
                sdp_mline_index: i32::from(init.sdp_mline_index.unwrap_or(0)),
            };
            let _ = host_ref.add_remote_candidate(&ice).await;
        }
    };
    tokio::spawn(async move {});
    // Host candidates -> controller, driven off the host event stream below.

    // ---- assertions --------------------------------------------------------
    let controller2 = controller.clone();
    let drive = async {
        loop {
            match host_events.recv().await.expect("host events") {
                TransportEvent::LocalCandidate(Some(init)) => {
                    let _ = controller2.add_ice_candidate(init).await;
                }
                TransportEvent::ChannelsReady => break,
                _ => {}
            }
        }
    };
    tokio::select! {
        _ = drive => {}
        _ = feed_controller_candidates => panic!("candidate feed ended early"),
        _ = tokio::time::sleep(Duration::from_secs(15)) => panic!("channels never became ready"),
    }

    // ctrl: host -> controller (display_info, as the real host sends on start).
    let (ctrl_seen_tx, mut ctrl_seen_rx) = mpsc::channel::<String>(4);
    ctrl_ch.on_message(Box::new(move |msg| {
        let tx = ctrl_seen_tx.clone();
        Box::pin(async move {
            let _ = tx.send(String::from_utf8_lossy(&msg.data).into_owned()).await;
        })
    }));
    host.send_ctrl(
        ctrl_msg::DISPLAY_INFO,
        &rc_proto::ctrl::DisplayInfo { w: 2560, h: 1440, scale: 1.0, os: "windows".into() },
    )
    .await
    .unwrap();
    let seen = tokio::time::timeout(Duration::from_secs(10), ctrl_seen_rx.recv())
        .await
        .expect("ctrl frame from host")
        .unwrap();
    assert!(seen.contains("\"display_info\"") && seen.contains("\"windows\""), "got {seen}");

    // ctrl: controller -> host (a key_down, §5).
    let env = rc_proto::envelope::Envelope::new(
        ctrl_msg::KEY_DOWN,
        "",
        "",
        1,
        Some(&rc_proto::ctrl::KeyEvent { keycode: 8, mods: 8, chars: String::new() }),
    )
    .unwrap();
    ctrl_ch.send_text(String::from_utf8(env.encode().unwrap()).unwrap()).await.unwrap();
    match next_event(&mut host_events, "ctrl key_down", |e| matches!(e, TransportEvent::Ctrl(_))).await {
        TransportEvent::Ctrl(env) => {
            assert_eq!(env.msg_type, ctrl_msg::KEY_DOWN);
            let key: rc_proto::ctrl::KeyEvent = env.payload_as().unwrap();
            assert_eq!((key.keycode, key.mods), (8, 8));
        }
        _ => unreachable!(),
    }

    // hi: controller -> host (mouse_move with a seq).
    let env = rc_proto::envelope::Envelope::new(
        rc_proto::consts::hi::MOUSE_MOVE,
        "",
        "",
        1,
        Some(&rc_proto::ctrl::MouseMove { x: 0.25, y: 0.75, seq: 42 }),
    )
    .unwrap();
    hi_ch.send_text(String::from_utf8(env.encode().unwrap()).unwrap()).await.unwrap();
    match next_event(&mut host_events, "hi mouse_move", |e| matches!(e, TransportEvent::Hi(_))).await {
        TransportEvent::Hi(env) => {
            let mv: rc_proto::ctrl::MouseMove = env.payload_as().unwrap();
            assert_eq!(mv.seq, 42);
        }
        _ => unreachable!(),
    }

    // Media: write Annex-B-shaped samples until the controller reads RTP. The
    // bytes need not decode; RTP delivery through SRTP is what is asserted.
    let fake_idr: Vec<u8> = {
        let mut v = vec![0, 0, 0, 1, 0x65];
        v.extend(std::iter::repeat(0xAB).take(400));
        v
    };
    let got_codec = loop {
        host.write_video_sample(Bytes::from(fake_idr.clone()), Duration::from_millis(33))
            .await
            .unwrap();
        match tokio::time::timeout(Duration::from_millis(200), track_rx.recv()).await {
            Ok(Some(codec)) => break codec,
            Ok(None) => panic!("track channel closed"),
            Err(_) => continue, // keep feeding until the track pipeline spins up
        }
    };
    assert!(
        got_codec.to_lowercase().contains("h264"),
        "controller received {got_codec}, expected H.264"
    );

    host.close().await;
    let _ = controller.close().await;
}
