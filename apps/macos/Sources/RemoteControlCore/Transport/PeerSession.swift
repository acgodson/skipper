import Foundation
import CoreVideo
import SkipperCore
import WebRTC

@MainActor
public protocol PeerSessionDelegate: AnyObject {
    func peerSession(_ session: PeerSession, didCreateLocalDescription type: String, sdp: String, restart: Bool)
    func peerSession(_ session: PeerSession, didGatherCandidate candidate: String, sdpMid: String?, sdpMLineIndex: Int?)
    func peerSession(_ session: PeerSession, didChangeICEState state: ICELinkState)
    func peerSession(_ session: PeerSession, didOpenDataChannel label: String)
    func peerSession(_ session: PeerSession, didReceiveCtrl envelope: Envelope)
    func peerSession(_ session: PeerSession, didReceiveMouseMove move: MouseMovePayload)
    func peerSession(_ session: PeerSession, didMeasureRoundTrip seconds: TimeInterval)
    func peerSession(_ session: PeerSession, didReceiveDisplayInfo info: DisplayInfoPayload)
    func peerSessionDidReceiveRemoteVideo(_ session: PeerSession)
}

public extension PeerSessionDelegate {
    func peerSession(_ session: PeerSession, didReceiveMouseMove move: MouseMovePayload) {}
    func peerSession(_ session: PeerSession, didMeasureRoundTrip seconds: TimeInterval) {}
    func peerSession(_ session: PeerSession, didReceiveDisplayInfo info: DisplayInfoPayload) {}
    func peerSessionDidReceiveRemoteVideo(_ session: PeerSession) {}
}

public enum PeerMediaRole: Equatable {
    case sendScreen
    case receiveScreen
    case none
}

public enum PeerSessionError: Swift.Error, LocalizedError {
    case factoryUnavailable
    case noPeerConnection
    case channelNotOpen(String)
    case installedFingerprintsRejected(String)
    case invalidRemoteSignal(String)

    public var errorDescription: String? {
        switch self {
        case .factoryUnavailable: return "This Mac could not start a remote session. Try again."
        case .noPeerConnection: return "The session is not open."
        case .channelNotOpen(let label):
            return RCLog.enabled
                ? "The '\(label)' data channel is not open."
                : "The connection to the other computer is not ready yet."
        case .installedFingerprintsRejected(let why): return why
        case .invalidRemoteSignal(let why): return why
        }
    }
}

@MainActor
public final class PeerSession {

    public static let ctrlLabel = "ctrl"
    public static let hiLabel = "hi"
    public static let mLineIndexRange = 0...64
    static let maxBufferedCandidates = 64

    public weak var delegate: PeerSessionDelegate?

    public private(set) var iceState: ICELinkState = .new
    public private(set) var isOfferer: Bool
    public private(set) var lastRoundTrip: TimeInterval?
    public var isReady: Bool { ctrlOpen && hiOpen }
    public private(set) var ctrlOpen = false
    public private(set) var hiOpen = false

    private let factory: RTCPeerConnectionFactory
    private var connection: RTCPeerConnection?
    private var ctrl: RTCDataChannel?
    private var hi: RTCDataChannel?
    private var bridge: PeerSessionBridge?
    public private(set) var iceServers: [ICEServerSpec]

    private var outgoingMoveSeq: Int64 = 0
    private var moveGate = MoveSequenceGate()
    private var hasRemoteDescription = false
    private var bufferedCandidates: [(sdp: String, mid: String?, index: Int?)] = []

    private static let sharedFactory: RTCPeerConnectionFactory = {
        RTCInitializeSSL()
        let encoderFactory = RTCDefaultVideoEncoderFactory()
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

    public private(set) var isRelayOnly: Bool

    // MARK: Media (Phase 4)

    public let mediaRole: PeerMediaRole
    private var videoSource: RTCVideoSource?
    private var videoCapturer: RTCVideoCapturer?
    private var videoTrack: RTCVideoTrack?
    private var videoSender: RTCRtpSender?
    public private(set) var remoteVideoTrack: RTCVideoTrack?
    private var appliedProfile: QualityProfile?
    public private(set) var framesSubmitted = 0

    public init(iceServers: [ICEServerSpec],
                isOfferer: Bool,
                mediaRole: PeerMediaRole = .none,
                forceTURNRelay: Bool = false) {
        self.factory = PeerSession.sharedFactory
        self.iceServers = iceServers
        self.isOfferer = isOfferer
        self.mediaRole = mediaRole
        self.isRelayOnly = forceTURNRelay
    }

    // MARK: - Lifecycle

    private func makeConfiguration() -> RTCConfiguration {
        let configuration = RTCConfiguration()
        configuration.iceServers = iceServers.map {
            if let username = $0.username, let credential = $0.credential {
                return RTCIceServer(urlStrings: $0.urls, username: username, credential: credential)
            }
            return RTCIceServer(urlStrings: $0.urls)
        }
        configuration.sdpSemantics = .unifiedPlan
        configuration.continualGatheringPolicy = .gatherContinually
        configuration.iceCandidatePoolSize = 1
        configuration.bundlePolicy = .maxBundle
        if isRelayOnly { configuration.iceTransportPolicy = .relay }
        configuration.rtcpMuxPolicy = .require
        return configuration
    }

    // libwebrtc applies a new ICE transport policy to the NEXT gathering phase,
    // so the relay switch is a setConfiguration plus the ICE restart that follows;
    // the RTCPeerConnection, its tracks and its data channels all survive.
    @discardableResult
    public func switchToRelayOnly() -> Bool {
        guard !isRelayOnly else { return true }
        guard let connection else { return false }
        isRelayOnly = true
        guard connection.setConfiguration(makeConfiguration()) else {
            isRelayOnly = false
            RCLog.error("transport: libwebrtc refused the relay-only configuration")
            return false
        }
        RCLog.info("transport: ICE transport policy is now relay-only")
        return true
    }

    /// libwebrtc takes a new server list through setConfiguration without
    /// renegotiating. It is used for gathering from then on: the candidate
    /// pool at once, the live transport from its next ICE restart (which the
    /// session state machine orders for a relay-only offer that found nothing).
    @discardableResult
    public func updateICEServers(_ servers: [ICEServerSpec]) -> Bool {
        guard servers != iceServers else { return true }
        let previous = iceServers
        iceServers = servers
        guard let connection else { return true }
        guard connection.setConfiguration(makeConfiguration()) else {
            iceServers = previous
            RCLog.error("transport: libwebrtc refused the new ICE server list")
            return false
        }
        RCLog.info("transport: ICE servers updated (\(servers.count))")
        return true
    }

    public func start() throws {
        guard connection == nil else { return }

        let configuration = makeConfiguration()
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
            let ctrlConfig = RTCDataChannelConfiguration()
            ctrlConfig.isOrdered = true
            ctrl = connection.dataChannel(forLabel: PeerSession.ctrlLabel, configuration: ctrlConfig)
            ctrl?.delegate = bridge

            let hiConfig = RTCDataChannelConfiguration()
            hiConfig.isOrdered = false
            hiConfig.maxRetransmits = 0
            hi = connection.dataChannel(forLabel: PeerSession.hiLabel, configuration: hiConfig)
            hi?.delegate = bridge
        }
    }

    private func configureMedia(on connection: RTCPeerConnection) {
        switch mediaRole {
        case .none:
            return

        case .sendScreen:
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

    private func preferH264(on connection: RTCPeerConnection) {
        guard let transceiver = connection.transceivers.first(where: { $0.mediaType == .video })
        else { return }
        let capabilities = factory.rtpReceiverCapabilities(forKind: kRTCMediaStreamTrackKindVideo).codecs
        guard !capabilities.isEmpty else { return }
        let isH264: (RTCRtpCodecCapability) -> Bool = {
            $0.name.caseInsensitiveCompare(SDPCodecPreference.h264Name) == .orderedSame
        }
        let h264 = capabilities.filter(isH264).sorted { lhs, rhs in
            (lhs.parameters["packetization-mode"] ?? "0") > (rhs.parameters["packetization-mode"] ?? "0")
        }
        guard !h264.isEmpty else {
            RCLog.error("transport: this build has no H.264 — video will use a SOFTWARE codec")
            return
        }
        let rest = capabilities.filter { !isH264($0) }
        transceiver.setCodecPreferences(h264 + rest)
        RCLog.info("transport: codec preference \(  (h264 + rest).prefix(3).map(\.mimeType).joined(separator: ","))")
    }

    public static let screenTrackID = "rc-screen"
    public static let mediaStreamID = "rc-media"

    // MARK: - Media (host side)

    public func submit(pixelBuffer: CVPixelBuffer, timeNs: Int64) {
        guard let source = videoSource, let capturer = videoCapturer else { return }
        let buffer = RTCCVPixelBuffer(pixelBuffer: pixelBuffer)
        let frame = RTCVideoFrame(buffer: buffer, rotation: ._0, timeStampNs: timeNs)
        framesSubmitted += 1
        source.capturer(capturer, didCapture: frame)
    }

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

    public var activeEncodingCapBps: Int? {
        videoSender?.parameters.encodings.first?.maxBitrateBps?.intValue
    }

    public var hasVideoTrack: Bool { videoTrack != nil }

    // MARK: - Media statistics

    public func videoStatistics() async -> VideoStatistics {
        guard let entries = await statisticsEntries() else { return VideoStatistics() }
        return VideoStatistics.parse(entries)
    }

    public func icePathStatistics() async -> ICEPathStatistics? {
        guard let entries = await statisticsEntries() else { return nil }
        return ICEPathStatistics.parse(entries)
    }

    private func statisticsEntries() async -> [(type: String, values: [String: Any])]? {
        guard let connection else { return nil }
        return await withCheckedContinuation { continuation in
            connection.statistics { report in
                let entries = report.statistics.values.map { statistic -> (type: String, values: [String: Any]) in
                    var values = statistic.values as [String: Any]
                    values["id"] = statistic.id
                    return (type: statistic.type, values: values)
                }
                continuation.resume(returning: entries)
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

    private static func pinH264(_ description: RTCSessionDescription) -> RTCSessionDescription {
        let rewritten = SDPCodecPreference.raiseH264Level(
            in: SDPCodecPreference.preferH264(in: description.sdp))
        if let codec = SDPCodecPreference.firstVideoCodecName(in: rewritten) {
            RCLog.info("transport: local \(description.type == .offer ? "offer" : "answer") prefers \(codec) [\(SDPCodecPreference.videoPayloadOrder(in: rewritten).prefix(6).joined(separator: " "))] h264=\(SDPCodecPreference.h264ProfileLevelIDs(in: rewritten).joined(separator: ","))")
        }
        guard rewritten != description.sdp else { return description }
        return RTCSessionDescription(type: description.type, sdp: rewritten)
    }

    /// `verifiedFingerprints` is the `fp` that passed PROTOCOL.md §2.12. The
    /// fingerprints libwebrtc installed are compared with it before any remote
    /// candidate is applied; on a mismatch the connection is closed at once.
    public func setRemoteDescription(type: String, sdp: String, verifiedFingerprints: String) async throws {
        guard let connection else { throw PeerSessionError.noPeerConnection }
        let sdpType: RTCSdpType
        switch type {
        case "offer": sdpType = .offer
        case "answer": sdpType = .answer
        default: throw PeerSessionError.invalidRemoteSignal("sdpType \(type) is neither offer nor answer")
        }
        let applied = try SdpAuth.withoutCandidates(sdp)
        if let codec = SDPCodecPreference.firstVideoCodecName(in: applied) {
            RCLog.info("transport: remote \(type) prefers \(codec) [\(SDPCodecPreference.videoPayloadOrder(in: applied).prefix(6).joined(separator: " "))]")
        }
        try await connection.setRemoteDescription(RTCSessionDescription(type: sdpType, sdp: applied))
        do {
            try SdpAuth.requireInstalled(verified: verifiedFingerprints, installedSDP: installedRemoteSDP)
        } catch {
            close()
            throw PeerSessionError.installedFingerprintsRejected(error.localizedDescription)
        }
        hasRemoteDescription = true
        let queued = bufferedCandidates
        bufferedCandidates.removeAll()
        for candidate in queued {
            try? await addCandidate(candidate.sdp, sdpMid: candidate.mid, sdpMLineIndex: candidate.index)
        }
    }

    /// The remote description as libwebrtc parsed and re-serialised it.
    public var installedRemoteSDP: String? { connection?.remoteDescription?.sdp }

    public func addCandidate(_ candidate: String, sdpMid: String?, sdpMLineIndex: Int?) async throws {
        guard let connection else { throw PeerSessionError.noPeerConnection }
        guard !candidate.isEmpty else { return }
        let index = sdpMLineIndex ?? 0
        guard Self.mLineIndexRange.contains(index) else {
            throw PeerSessionError.invalidRemoteSignal("sdpMLineIndex \(index) is outside \(Self.mLineIndexRange)")
        }
        guard hasRemoteDescription else {
            guard bufferedCandidates.count < Self.maxBufferedCandidates else {
                throw PeerSessionError.invalidRemoteSignal("too many candidates before the remote description")
            }
            bufferedCandidates.append((candidate, sdpMid, index))
            return
        }
        let ice = RTCIceCandidate(sdp: candidate,
                                  sdpMLineIndex: Int32(index),
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

    public func sendQuality(_ mode: QualityWireMode) throws {
        try sendCtrl(type: CtrlType.quality, payload: QualityPayload(mode))
    }

    public func sendCursorShape(_ shape: CursorShape) throws {
        try sendCtrl(type: CtrlType.cursorShape, payload: CursorShapePayload(shape))
    }

    public func sendSessionClose(reason: String) throws {
        try sendCtrl(type: CtrlType.sessionClose, payload: SessionClosePayload(reason: reason))
    }

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
        default: return
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
            guard envelope.type == CtrlType.mouseMove,
                  let move = try? envelope.decodePayload(MouseMovePayload.self),
                  moveGate.accept(move.seq) else { return }
            delegate?.peerSession(self, didReceiveMouseMove: move)
            return
        }

        switch envelope.type {
        case CtrlType.ping:
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
        delegate?.peerSession(self, didReceiveCtrl: envelope)
    }

    fileprivate func handleRenegotiationNeeded() {
    }
}

// MARK: - libwebrtc delegate bridge

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
