import Foundation
import CoreVideo
import WebRTC

/// Everything the rest of the app needs to know about the media path, with no
/// libwebrtc types crossing the boundary.
@MainActor
public protocol PeerSessionDelegate: AnyObject {
    /// A local description is ready to be relayed as `sdp` (PROTOCOL.md §2.12).
    func peerSession(_ session: PeerSession, didCreateLocalDescription type: String, sdp: String, restart: Bool)
    /// A local ICE candidate is ready to be relayed as `ice` (§2.13).
    func peerSession(_ session: PeerSession, didGatherCandidate candidate: String, sdpMid: String?, sdpMLineIndex: Int?)
    func peerSession(_ session: PeerSession, didChangeICEState state: ICELinkState)
    func peerSession(_ session: PeerSession, didOpenDataChannel label: String)
    /// A decoded `ctrl` message. Phase 5 (input injection, clipboard, gestures)
    /// hangs off exactly this callback; nothing in this file needs to change.
    func peerSession(_ session: PeerSession, didReceiveCtrl envelope: Envelope)
    /// A `mouse_move` on the unreliable channel, already de-duplicated by `seq`.
    func peerSession(_ session: PeerSession, didReceiveMouseMove move: MouseMovePayload)
    /// Round-trip time measured by a `ping`/`pong` exchange over `ctrl`.
    func peerSession(_ session: PeerSession, didMeasureRoundTrip seconds: TimeInterval)
    func peerSession(_ session: PeerSession, didReceiveDisplayInfo info: DisplayInfoPayload)
    /// The remote video track arrived (controller side). Phase 4 renders it.
    func peerSessionDidReceiveRemoteVideo(_ session: PeerSession)
}

public extension PeerSessionDelegate {
    func peerSession(_ session: PeerSession, didReceiveMouseMove move: MouseMovePayload) {}
    func peerSession(_ session: PeerSession, didMeasureRoundTrip seconds: TimeInterval) {}
    func peerSession(_ session: PeerSession, didReceiveDisplayInfo info: DisplayInfoPayload) {}
    func peerSessionDidReceiveRemoteVideo(_ session: PeerSession) {}
}

/// Which end of the one video track this session is.
///
/// It is derived from the app role, not from `isOfferer`: the controller offers
/// *and* receives, which is exactly the pair that is easy to get backwards.
public enum PeerMediaRole: Equatable {
    /// Host: adds a send-only screen track.
    case sendScreen
    /// Controller: adds a receive-only video transceiver so the offer carries a
    /// video m-line and the host's answer can attach its track to it — no second
    /// round of negotiation once media starts.
    case receiveScreen
    /// No media at all. Only the headless data-channel tests use this.
    case none
}

public enum PeerSessionError: Swift.Error, LocalizedError {
    case factoryUnavailable
    case noPeerConnection
    case channelNotOpen(String)

    public var errorDescription: String? {
        switch self {
        case .factoryUnavailable: return "The WebRTC peer connection factory could not be created."
        case .noPeerConnection: return "There is no peer connection."
        case .channelNotOpen(let label): return "The '\(label)' data channel is not open."
        }
    }
}

/// The WebRTC half of a session: one `RTCPeerConnection` and the two data
/// channels PROTOCOL.md §5 and §6 define.
///
/// Phase 4 added the single video track through `configureMedia(on:)` — one
/// direction only, decided by `mediaRole`. **Still no input injection**: that is
/// Phase 5 and hangs off `PeerSessionDelegate.didReceiveCtrl`, which does not
/// need this file to change.
@MainActor
public final class PeerSession {

    public static let ctrlLabel = "ctrl"
    public static let hiLabel = "hi"

    public weak var delegate: PeerSessionDelegate?

    public private(set) var iceState: ICELinkState = .new
    public private(set) var isOfferer: Bool
    public private(set) var lastRoundTrip: TimeInterval?
    /// Both channels open. The session is not usable for control until this.
    public var isReady: Bool { ctrlOpen && hiOpen }
    public private(set) var ctrlOpen = false
    public private(set) var hiOpen = false

    private let factory: RTCPeerConnectionFactory
    private var connection: RTCPeerConnection?
    private var ctrl: RTCDataChannel?
    private var hi: RTCDataChannel?
    private var bridge: PeerSessionBridge?
    private let iceServers: [ICEServerSpec]

    private var outgoingMoveSeq: Int64 = 0
    /// PROTOCOL.md §6 stale-packet gate for the unreliable `hi` channel. The
    /// same type the host-side injector uses, so there is exactly one
    /// implementation of "is this position newer than the last one".
    private var moveGate = MoveSequenceGate()
    /// libwebrtc rejects a candidate added before a remote description exists,
    /// and trickle ICE guarantees candidates race the SDP. Buffering them is the
    /// difference between "usually connects" and "connects".
    private var hasRemoteDescription = false
    private var bufferedCandidates: [(sdp: String, mid: String?, index: Int?)] = []

    /// One factory per process is the documented pattern; creating several leaks
    /// worker threads.
    private static let sharedFactory: RTCPeerConnectionFactory = {
        RTCInitializeSSL()
        let encoderFactory = RTCDefaultVideoEncoderFactory()
        // libwebrtc asks the factory for its `preferredCodec` when it builds the
        // codec list it offers. Naming H.264 here is the earliest of the three
        // places we pin it (the other two are `setCodecPreferences` and the SDP
        // rewrite) — and the only one that also affects the *order* the encoder
        // factory itself reports.
        if let h264 = RTCDefaultVideoEncoderFactory.supportedCodecs()
            .first(where: { $0.name == kRTCVideoCodecH264Name
                && $0.parameters["profile-level-id"] == kRTCMaxSupportedH264ProfileLevelConstrainedHigh })
            ?? RTCDefaultVideoEncoderFactory.supportedCodecs()
            .first(where: { $0.name == kRTCVideoCodecH264Name }) {
            encoderFactory.preferredCodec = h264
        }
        return RTCPeerConnectionFactory(
            encoderFactory: encoderFactory,
            decoderFactory: RTCDefaultVideoDecoderFactory())
    }()

    /// Diagnostic: what this build can actually encode, in the order libwebrtc
    /// will offer it. Read by `rc-node codecs`; the reason it exists is that
    /// "H.264 is available" was assumed rather than checked when Phase 4
    /// shipped, and the session quietly negotiated software VP8 instead.
    public static func videoCodecReport() -> [String: [String]] {
        let factory = sharedFactory
        func names(_ capabilities: RTCRtpCapabilities) -> [String] {
            capabilities.codecs.map { codec in
                let fmtp = codec.parameters.isEmpty ? "" : " " + codec.parameters
                    .sorted { $0.key < $1.key }
                    .map { "\($0.key)=\($0.value)" }.joined(separator: ";")
                return codec.mimeType + fmtp
            }
        }
        return [
            "encoderFactory": RTCDefaultVideoEncoderFactory.supportedCodecs().map(\.name),
            "senderCapabilities": names(factory.rtpSenderCapabilities(forKind: kRTCMediaStreamTrackKindVideo)),
            "receiverCapabilities": names(factory.rtpReceiverCapabilities(forKind: kRTCMediaStreamTrackKindVideo)),
        ]
    }

    private let forceRelay: Bool

    // MARK: Media (Phase 4)

    public let mediaRole: PeerMediaRole
    /// Host side: the source every captured frame is pushed into. libwebrtc
    /// scales, drops and hands frames to the VideoToolbox H.264 encoder from
    /// here — we never encode by hand.
    private var videoSource: RTCVideoSource?
    private var videoCapturer: RTCVideoCapturer?
    private var videoTrack: RTCVideoTrack?
    private var videoSender: RTCRtpSender?
    /// Controller side: the decoded remote screen, for the Metal view.
    public private(set) var remoteVideoTrack: RTCVideoTrack?
    private var appliedProfile: QualityProfile?
    /// Frames handed to libwebrtc. Distinct from frames *encoded*: libwebrtc
    /// legitimately drops some under congestion, and conflating the two would
    /// hide exactly that.
    public private(set) var framesSubmitted = 0

    public init(iceServers: [ICEServerSpec],
                isOfferer: Bool,
                mediaRole: PeerMediaRole = .none,
                forceTURNRelay: Bool = false) {
        self.factory = PeerSession.sharedFactory
        self.iceServers = iceServers
        self.isOfferer = isOfferer
        self.mediaRole = mediaRole
        self.forceRelay = forceTURNRelay
    }

    // MARK: - Lifecycle

    public func start() throws {
        guard connection == nil else { return }

        let configuration = RTCConfiguration()
        configuration.iceServers = iceServers.map {
            if let username = $0.username, let credential = $0.credential {
                return RTCIceServer(urlStrings: $0.urls, username: username, credential: credential)
            }
            return RTCIceServer(urlStrings: $0.urls)
        }
        configuration.sdpSemantics = .unifiedPlan
        configuration.continualGatheringPolicy = .gatherContinually
        // Trickle ICE is expected (PROTOCOL.md §2.13) and the candidate pool
        // gives the first connection a head start without changing semantics.
        configuration.iceCandidatePoolSize = 1
        configuration.bundlePolicy = .maxBundle
        if forceRelay { configuration.iceTransportPolicy = .relay }
        configuration.rtcpMuxPolicy = .require

        let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
        let bridge = PeerSessionBridge()
        guard let connection = factory.peerConnection(with: configuration,
                                                      constraints: constraints,
                                                      delegate: bridge) else {
            throw PeerSessionError.factoryUnavailable
        }
        bridge.owner = self
        self.bridge = bridge
        self.connection = connection

        configureMedia(on: connection)

        if isOfferer {
            // The offerer creates both channels; the answerer receives them
            // through `didOpen dataChannel`. In-band negotiation keeps the SDP
            // free of hand-assigned stream ids.
            let ctrlConfig = RTCDataChannelConfiguration()
            ctrlConfig.isOrdered = true
            ctrl = connection.dataChannel(forLabel: PeerSession.ctrlLabel, configuration: ctrlConfig)
            ctrl?.delegate = bridge

            let hiConfig = RTCDataChannelConfiguration()
            hiConfig.isOrdered = false
            hiConfig.maxRetransmits = 0     // PROTOCOL.md §6: unreliable, unordered
            hi = connection.dataChannel(forLabel: PeerSession.hiLabel, configuration: hiConfig)
            hi?.delegate = bridge
        }
    }

    /// PHASE 4. The host adds its ScreenCaptureKit video track; the controller
    /// adds a receive-only transceiver. Both happen *before* the first offer or
    /// answer, so the single negotiation Phase 3 already performs carries the
    /// video m-line and no renegotiation is ever needed for media to start.
    private func configureMedia(on connection: RTCPeerConnection) {
        switch mediaRole {
        case .none:
            return

        case .sendScreen:
            // `forScreenCast: true` tells libwebrtc this is a screen, not a
            // camera: it biases the degradation preference towards keeping
            // resolution (text must stay readable) and away from the
            // camera-oriented "drop resolution first" behaviour.
            let source = factory.videoSource(forScreenCast: true)
            let capturer = RTCVideoCapturer(delegate: source)
            let track = factory.videoTrack(with: source, trackId: PeerSession.screenTrackID)
            videoSource = source
            videoCapturer = capturer
            videoTrack = track
            videoSender = connection.add(track, streamIds: [PeerSession.mediaStreamID])
            if let appliedProfile { apply(quality: appliedProfile) }

        case .receiveScreen:
            let initialiser = RTCRtpTransceiverInit()
            initialiser.direction = .recvOnly
            initialiser.streamIds = [PeerSession.mediaStreamID]
            _ = connection.addTransceiver(of: .video, init: initialiser)
        }
        preferH264(on: connection)
    }

    /// PLAN.md §5. Hoists H.264 to the front of the video transceiver's codec
    /// list so the negotiation cannot land on a software codec.
    ///
    /// The *receiver* capabilities are the right list to filter even on the
    /// sending side: `setCodecPreferences` takes the union the transceiver may
    /// use in either direction, and the receiver list is the one that carries
    /// every H.264 profile this build can handle.
    private func preferH264(on connection: RTCPeerConnection) {
        guard let transceiver = connection.transceivers.first(where: { $0.mediaType == .video })
        else { return }
        let capabilities = factory.rtpReceiverCapabilities(forKind: kRTCMediaStreamTrackKindVideo).codecs
        guard !capabilities.isEmpty else { return }
        let isH264: (RTCRtpCodecCapability) -> Bool = {
            $0.name.caseInsensitiveCompare(SDPCodecPreference.h264Name) == .orderedSame
        }
        // Packetization-mode 1 first: mode 0 caps every NAL at the MTU, which on
        // a full-screen keyframe means a great many more packets.
        let h264 = capabilities.filter(isH264).sorted { lhs, rhs in
            (lhs.parameters["packetization-mode"] ?? "0") > (rhs.parameters["packetization-mode"] ?? "0")
        }
        guard !h264.isEmpty else {
            RCLog.error("transport: this build has no H.264 — video will use a SOFTWARE codec")
            return
        }
        // VP8/VP9/AV1 are kept, but behind H.264: a peer that truly cannot do
        // H.264 still gets a picture rather than a black window. The efficiency
        // assertion lives in verify-capture.sh, which fails on a software encoder.
        let rest = capabilities.filter { !isH264($0) }
        transceiver.setCodecPreferences(h264 + rest)
        RCLog.info("transport: codec preference \(  (h264 + rest).prefix(3).map(\.mimeType).joined(separator: ","))")
    }

    public static let screenTrackID = "rc-screen"
    public static let mediaStreamID = "rc-media"

    // MARK: - Media (host side)

    /// Hands one captured frame to libwebrtc. Called for every frame
    /// ScreenCaptureKit delivers; deliberately does nothing when there is no
    /// video track, so a session that lost its capture grant degrades to "no
    /// picture" rather than crashing.
    public func submit(pixelBuffer: CVPixelBuffer, timeNs: Int64) {
        guard let source = videoSource, let capturer = videoCapturer else { return }
        let buffer = RTCCVPixelBuffer(pixelBuffer: pixelBuffer)
        let frame = RTCVideoFrame(buffer: buffer, rotation: ._0, timeStampNs: timeNs)
        framesSubmitted += 1
        source.capturer(capturer, didCapture: frame)
    }

    /// PROTOCOL.md §5 `quality`. Applies the profile to both ends of the host
    /// pipeline: the source (which drops and scales before encoding) and the
    /// sender's encoding parameters (the bitrate ceiling BWE works under).
    public func apply(quality profile: QualityProfile) {
        appliedProfile = profile
        if let source = videoSource, profile.encodeWidth > 0 {
            source.adaptOutputFormat(toWidth: Int32(profile.encodeWidth),
                                     height: Int32(profile.encodeHeight),
                                     fps: Int32(profile.maxFramerate))
        }
        guard let sender = videoSender else { return }
        let parameters = sender.parameters
        for encoding in parameters.encodings {
            encoding.isActive = true
            encoding.maxBitrateBps = NSNumber(value: profile.maxBitrateBps)
            encoding.minBitrateBps = NSNumber(value: profile.minBitrateBps)
            encoding.maxFramerate = NSNumber(value: profile.maxFramerate)
            encoding.scaleResolutionDownBy = NSNumber(value: max(1.0, profile.scaleResolutionDownBy))
        }
        sender.parameters = parameters
    }

    /// The encoding parameters libwebrtc currently holds, read back from the
    /// sender rather than from our own copy — so a test can prove the cap was
    /// actually accepted, not merely requested.
    public var activeEncodingCapBps: Int? {
        videoSender?.parameters.encodings.first?.maxBitrateBps?.intValue
    }

    public var hasVideoTrack: Bool { videoTrack != nil }

    // MARK: - Media statistics

    /// Reads libwebrtc's own statistics. This is the number the integration
    /// test asserts on: nothing in this app can fake `framesDecoded`.
    public func videoStatistics() async -> VideoStatistics {
        guard let connection else { return VideoStatistics() }
        return await withCheckedContinuation { continuation in
            connection.statistics { report in
                // `id` is a property of the stats object, not one of its values,
                // but the parser needs it to resolve `codecId` -> mimeType.
                let entries = report.statistics.values.map { statistic -> (type: String, values: [String: Any]) in
                    var values = statistic.values as [String: Any]
                    values["id"] = statistic.id
                    return (type: statistic.type, values: values)
                }
                continuation.resume(returning: VideoStatistics.parse(entries))
            }
        }
    }

    public func close() {
        ctrl?.close()
        hi?.close()
        connection?.close()
        ctrl = nil
        hi = nil
        connection = nil
        videoTrack = nil
        videoSender = nil
        videoSource = nil
        videoCapturer = nil
        remoteVideoTrack = nil
        hasRemoteDescription = false
        bufferedCandidates.removeAll()
        bridge?.owner = nil
        bridge = nil
        ctrlOpen = false
        hiOpen = false
        iceState = .closed
    }

    // MARK: - Negotiation

    /// Creates an offer. `restart: true` sets `IceRestart`, which is what makes
    /// libwebrtc mint fresh ufrag/pwd and re-gather (PLAN.md §2.1).
    public func createOffer(restart: Bool) async throws -> (type: String, sdp: String) {
        guard let connection else { throw PeerSessionError.noPeerConnection }
        var mandatory: [String: String] = [:]
        if restart { mandatory["IceRestart"] = "true" }
        let constraints = RTCMediaConstraints(
            mandatoryConstraints: mandatory.isEmpty ? nil : mandatory,
            optionalConstraints: nil)
        let offer = try await connection.offer(for: constraints)
        let pinned = PeerSession.pinH264(offer)
        try await connection.setLocalDescription(pinned)
        return ("offer", pinned.sdp)
    }

    public func createAnswer() async throws -> (type: String, sdp: String) {
        guard let connection else { throw PeerSessionError.noPeerConnection }
        let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
        let answer = try await connection.answer(for: constraints)
        let pinned = PeerSession.pinH264(answer)
        try await connection.setLocalDescription(pinned)
        return ("answer", pinned.sdp)
    }

    /// The second of the two H.264 mechanisms (see VideoCodecPreference.swift):
    /// rewrite the `m=video` payload order before the description is applied.
    /// Independent of `setCodecPreferences`, so one can fail without taking the
    /// CPU budget with it.
    private static func pinH264(_ description: RTCSessionDescription) -> RTCSessionDescription {
        let rewritten = SDPCodecPreference.raiseH264Level(
            in: SDPCodecPreference.preferH264(in: description.sdp))
        if let codec = SDPCodecPreference.firstVideoCodecName(in: rewritten) {
            RCLog.info("transport: local \(description.type == .offer ? "offer" : "answer") prefers \(codec) [\(SDPCodecPreference.videoPayloadOrder(in: rewritten).prefix(6).joined(separator: " "))] h264=\(SDPCodecPreference.h264ProfileLevelIDs(in: rewritten).joined(separator: ","))")
        }
        guard rewritten != description.sdp else { return description }
        return RTCSessionDescription(type: description.type, sdp: rewritten)
    }

    public func setRemoteDescription(type: String, sdp: String) async throws {
        guard let connection else { throw PeerSessionError.noPeerConnection }
        let sdpType: RTCSdpType
        switch type {
        case "offer": sdpType = .offer
        case "answer": sdpType = .answer
        case "pranswer": sdpType = .prAnswer
        case "rollback": sdpType = .rollback
        default: sdpType = .offer
        }
        // The REMOTE description decides what this end SENDS: an answerer must
        // send using the offerer's preferred codec. Logging it is how the VP8
        // regression was finally pinned down.
        if let codec = SDPCodecPreference.firstVideoCodecName(in: sdp) {
            RCLog.info("transport: remote \(type) prefers \(codec) [\(SDPCodecPreference.videoPayloadOrder(in: sdp).prefix(6).joined(separator: " "))]")
        }
        try await connection.setRemoteDescription(RTCSessionDescription(type: sdpType, sdp: sdp))
        hasRemoteDescription = true
        let queued = bufferedCandidates
        bufferedCandidates.removeAll()
        for candidate in queued {
            try? await addCandidate(candidate.sdp, sdpMid: candidate.mid, sdpMLineIndex: candidate.index)
        }
    }

    public func addCandidate(_ candidate: String, sdpMid: String?, sdpMLineIndex: Int?) async throws {
        guard let connection else { throw PeerSessionError.noPeerConnection }
        // An empty candidate is the end-of-candidates marker (PROTOCOL.md §2.13);
        // libwebrtc does not want it as a candidate.
        guard !candidate.isEmpty else { return }
        guard hasRemoteDescription else {
            bufferedCandidates.append((candidate, sdpMid, sdpMLineIndex))
            return
        }
        let ice = RTCIceCandidate(sdp: candidate,
                                  sdpMLineIndex: Int32(sdpMLineIndex ?? 0),
                                  sdpMid: sdpMid)
        try await connection.add(ice)
    }

    // MARK: - Data channels

    private func send<T: Encodable>(type: String, payload: T, on channel: RTCDataChannel?, label: String) throws {
        guard let channel, channel.readyState == .open else {
            throw PeerSessionError.channelNotOpen(label)
        }
        let data = try Envelope.encode(type: type, payload: payload)
        channel.sendData(RTCDataBuffer(data: data, isBinary: false))
    }

    public func sendCtrl<T: Encodable>(type: String, payload: T) throws {
        try send(type: type, payload: payload, on: ctrl, label: PeerSession.ctrlLabel)
    }

    /// PROTOCOL.md §5: sent after every resume and every detected disconnect so
    /// no modifier or button is left logically held. Idempotent by definition,
    /// and safe to call when the channel is closed — a reset that cannot be
    /// delivered is not an error, it is a no-op the peer will get on resume.
    @discardableResult
    public func sendInputReset() -> Bool {
        do {
            try sendCtrl(type: CtrlType.inputReset, payload: EmptyPayload())
            return true
        } catch {
            return false
        }
    }

    public func sendPing() throws {
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        try sendCtrl(type: CtrlType.ping, payload: PingPayload(t: now))
    }

    public func sendDisplayInfo(_ info: DisplayInfoPayload) throws {
        try sendCtrl(type: CtrlType.displayInfo, payload: info)
    }

    /// PROTOCOL.md §5 `quality`. Controller → host.
    public func sendQuality(_ mode: QualityWireMode) throws {
        try sendCtrl(type: CtrlType.quality, payload: QualityPayload(mode))
    }

    public func sendSessionClose(reason: String) throws {
        try sendCtrl(type: CtrlType.sessionClose, payload: SessionClosePayload(reason: reason))
    }

    /// PHASE 5: every input, gesture and clipboard message goes through here,
    /// which is the one place that decides `hi` vs `ctrl`. `OutboundInput.channel`
    /// makes that choice, so a drag cannot end up on the unreliable channel.
    ///
    /// Returns false instead of throwing: input during a channel blip is
    /// dropped, not escalated. The reliable channel already retransmits, and a
    /// thrown error mid-drag would have no sensible handler up the stack.
    @discardableResult
    public func send(_ outbound: OutboundInput) -> Bool {
        do {
            switch outbound {
            case .move(let x, let y):
                try sendMouseMove(x: x, y: y)
            case .down(let payload):
                try sendCtrl(type: CtrlType.mouseDown, payload: payload)
            case .up(let payload):
                try sendCtrl(type: CtrlType.mouseUp, payload: payload)
            case .drag(let payload):
                try sendCtrl(type: CtrlType.mouseDrag, payload: payload)
            case .click(let payload):
                try sendCtrl(type: CtrlType.click, payload: payload)
            case .scroll(let payload):
                try sendCtrl(type: CtrlType.scroll, payload: payload)
            case .key(let down, let payload):
                try sendCtrl(type: down ? CtrlType.keyDown : CtrlType.keyUp, payload: payload)
            case .gesture(let payload):
                try sendCtrl(type: CtrlType.gesture, payload: payload)
            case .clipboard(let payload):
                try sendCtrl(type: CtrlType.clipboardText, payload: payload)
            case .reset:
                return sendInputReset()
            }
            return true
        } catch {
            return false
        }
    }

    /// The only message allowed on `hi` (PROTOCOL.md §6).
    public func sendMouseMove(x: Double, y: Double) throws {
        outgoingMoveSeq += 1
        try send(type: CtrlType.mouseMove,
                 payload: MouseMovePayload(x: x, y: y, seq: outgoingMoveSeq),
                 on: hi, label: PeerSession.hiLabel)
    }

    // MARK: - Incoming (called on the main actor by the bridge)

    fileprivate func handleICEState(_ state: RTCIceConnectionState) {
        let mapped: ICELinkState
        switch state {
        case .new: mapped = .new
        case .checking: mapped = .checking
        case .connected: mapped = .connected
        case .completed: mapped = .completed
        case .disconnected: mapped = .disconnected
        case .failed: mapped = .failed
        case .closed: mapped = .closed
        case .count: mapped = .new
        @unknown default: mapped = .new
        }
        guard mapped != iceState else { return }
        iceState = mapped
        delegate?.peerSession(self, didChangeICEState: mapped)
    }

    fileprivate func handleGeneratedCandidate(_ candidate: RTCIceCandidate) {
        delegate?.peerSession(self, didGatherCandidate: candidate.sdp,
                              sdpMid: candidate.sdpMid,
                              sdpMLineIndex: Int(candidate.sdpMLineIndex))
    }

    fileprivate func handleRemoteTrack(_ track: RTCMediaStreamTrack) {
        guard let video = track as? RTCVideoTrack, remoteVideoTrack !== video else { return }
        remoteVideoTrack = video
        video.isEnabled = true
        delegate?.peerSessionDidReceiveRemoteVideo(self)
    }

    fileprivate func handleRemoteDataChannel(_ channel: RTCDataChannel) {
        switch channel.label {
        case PeerSession.ctrlLabel: ctrl = channel
        case PeerSession.hiLabel: hi = channel
        default: return    // Unknown channels are ignored, not an error.
        }
        channel.delegate = bridge
        handleChannelStateChange(channel)
    }

    fileprivate func handleChannelStateChange(_ channel: RTCDataChannel) {
        let open = channel.readyState == .open
        switch channel.label {
        case PeerSession.ctrlLabel:
            guard open != ctrlOpen else { return }
            ctrlOpen = open
        case PeerSession.hiLabel:
            guard open != hiOpen else { return }
            hiOpen = open
        default: return
        }
        if open { delegate?.peerSession(self, didOpenDataChannel: channel.label) }
    }

    fileprivate func handleChannelMessage(_ channel: RTCDataChannel, data: Data) {
        guard let envelope = try? Envelope.decode(data) else { return }

        if channel.label == PeerSession.hiLabel {
            // Nothing but mouse_move may travel here, and stale positions must
            // be dropped: that is the entire point of the unreliable channel.
            guard envelope.type == CtrlType.mouseMove,
                  let move = try? envelope.decodePayload(MouseMovePayload.self),
                  moveGate.accept(move.seq) else { return }
            delegate?.peerSession(self, didReceiveMouseMove: move)
            return
        }

        switch envelope.type {
        case CtrlType.ping:
            // Echo `t` verbatim; the sender computes the RTT.
            if let ping = try? envelope.decodePayload(PingPayload.self) {
                try? sendCtrl(type: CtrlType.pong, payload: PingPayload(t: ping.t))
            }
        case CtrlType.pong:
            if let pong = try? envelope.decodePayload(PingPayload.self) {
                let rtt = Date().timeIntervalSince1970 - Double(pong.t) / 1000.0
                lastRoundTrip = max(rtt, 0)
                delegate?.peerSession(self, didMeasureRoundTrip: max(rtt, 0))
            }
        case CtrlType.displayInfo:
            if let info = try? envelope.decodePayload(DisplayInfoPayload.self) {
                delegate?.peerSession(self, didReceiveDisplayInfo: info)
            }
        default:
            break
        }
        // Everything, including ping/pong, is also handed to the delegate so
        // Phase 5 can act on input messages without this file growing.
        delegate?.peerSession(self, didReceiveCtrl: envelope)
    }

    fileprivate func handleRenegotiationNeeded() {
        // The offerer drives negotiation explicitly through SessionCoordinator;
        // reacting here as well would produce duplicate offers.
    }
}

// MARK: - libwebrtc delegate bridge

/// libwebrtc calls its delegates on its own signalling thread. Rather than make
/// `PeerSession` thread-safe, every callback hops to the main actor — the single
/// concurrency domain the whole app already lives in.
private final class PeerSessionBridge: NSObject, RTCPeerConnectionDelegate, RTCDataChannelDelegate {

    weak var owner: PeerSession?

    private func onMain(_ body: @escaping @MainActor (PeerSession) -> Void) {
        Task { @MainActor [weak self] in
            guard let owner = self?.owner else { return }
            body(owner)
        }
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didChange stateChanged: RTCSignalingState) {}

    func peerConnection(_ peerConnection: RTCPeerConnection, didAdd stream: RTCMediaStream) {}

    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove stream: RTCMediaStream) {}

    func peerConnectionShouldNegotiate(_ peerConnection: RTCPeerConnection) {
        onMain { $0.handleRenegotiationNeeded() }
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceConnectionState) {
        onMain { $0.handleICEState(newState) }
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceGatheringState) {}

    func peerConnection(_ peerConnection: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) {
        onMain { $0.handleGeneratedCandidate(candidate) }
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]) {}

    func peerConnection(_ peerConnection: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) {
        onMain { $0.handleRemoteDataChannel(dataChannel) }
    }

    // Unified Plan delivers remote media here, not through `didAdd stream`.
    // Both callbacks fire in practice (one when the receiver is created, one
    // when RTP actually starts); `handleRemoteTrack` is idempotent.
    func peerConnection(_ peerConnection: RTCPeerConnection,
                        didAdd rtpReceiver: RTCRtpReceiver,
                        streams mediaStreams: [RTCMediaStream]) {
        guard let track = rtpReceiver.track else { return }
        onMain { $0.handleRemoteTrack(track) }
    }

    func peerConnection(_ peerConnection: RTCPeerConnection,
                        didStartReceivingOn transceiver: RTCRtpTransceiver) {
        guard let track = transceiver.receiver.track else { return }
        onMain { $0.handleRemoteTrack(track) }
    }

    // MARK: RTCDataChannelDelegate

    func dataChannelDidChangeState(_ dataChannel: RTCDataChannel) {
        onMain { $0.handleChannelStateChange(dataChannel) }
    }

    func dataChannel(_ dataChannel: RTCDataChannel, didReceiveMessageWith buffer: RTCDataBuffer) {
        let data = buffer.data
        onMain { $0.handleChannelMessage(dataChannel, data: data) }
    }
}
