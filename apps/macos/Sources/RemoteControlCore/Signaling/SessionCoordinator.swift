import Foundation
import SkipperCore
import WebRTC

public enum ConnectFailure: Swift.Error, LocalizedError, Equatable {
    case authFailed
    case offline
    case busy
    case entitlement(reason: String?, message: String)
    case rateLimited(retryAfterSec: Int)
    case unknownDevice
    case selfConnect
    case notConnectedToServer
    case other(code: String, message: String)

    public init(_ error: Swift.Error) {
        guard let wire = error as? WireError, let code = wire.serverCode else {
            self = .other(code: "network", message: error.localizedDescription)
            return
        }
        switch code {
        case Wire.ByeReason.authFailed: self = .authFailed
        case Wire.ErrorCode.offline: self = .offline
        case Wire.ErrorCode.busy: self = .busy
        case Wire.ErrorCode.entitlement:
            self = .entitlement(reason: wire.reason,
                                message: wire.serverMessage ?? wire.errorDescription ?? code)
        case Wire.ErrorCode.rateLimited: self = .rateLimited(retryAfterSec: wire.retryAfterSec ?? 60)
        case Wire.ErrorCode.unknownDevice: self = .unknownDevice
        case Wire.ErrorCode.selfConnect: self = .selfConnect
        default: self = .other(code: code, message: wire.errorDescription ?? code)
        }
    }

    public var code: String {
        switch self {
        case .authFailed: return Wire.ByeReason.authFailed
        case .offline: return Wire.ErrorCode.offline
        case .busy: return Wire.ErrorCode.busy
        case .entitlement: return Wire.ErrorCode.entitlement
        case .rateLimited: return Wire.ErrorCode.rateLimited
        case .unknownDevice: return Wire.ErrorCode.unknownDevice
        case .selfConnect: return Wire.ErrorCode.selfConnect
        case .notConnectedToServer: return "no_server"
        case .other(let code, _): return code
        }
    }

    public var errorDescription: String? {
        switch self {
        case .authFailed:
            return "That access code was not accepted. Check it on the other Mac — codes are case-insensitive but every character counts."
        case .entitlement(_, let message):
            return message
        case .offline:
            return "That Mac is offline. It has to be running RemoteControl and connected to the internet."
        case .busy:
            return "That Mac already has a remote session. RemoteControl allows one at a time; end the other session first."
        case .rateLimited(let seconds):
            let minutes = seconds / 60
            let wait = minutes >= 1 ? "\(minutes) minute\(minutes == 1 ? "" : "s")" : "\(seconds) seconds"
            return "Too many incorrect access codes. Wait \(wait) before trying again."
        case .unknownDevice:
            return "No Mac with that Device ID has ever registered."
        case .selfConnect:
            return "That is this Mac's own Device ID."
        case .notConnectedToServer:
            return "Not connected to the signaling server yet. Try again in a moment."
        case .other(let code, let message):
            return "\(message) (\(code))"
        }
    }
}

public enum CoordinatorEvent {
    case signalingState(SignalingState)
    case signalingDisconnected(reason: String)
    case authenticated(HelloOKPayload)
    case presence(deviceID: String, online: Bool)
    case sessionGranted(sessionID: String, role: Wire.Role)
    case resumed(sessionID: String, peerAttached: Bool)
    case silentReconnect(reason: String)
    case phase(SessionPhase)
    case ice(ICELinkState)
    case dataChannel(label: String, allOpen: Bool)
    case roundTrip(TimeInterval)
    case connectFailed(ConnectFailure)
    case bye(reason: String)
    case accessCodeRequired(reason: String)
    case iceRestartStarted(relayOnly: Bool)
    case remoteDescription(type: String, restart: Bool)
    case peerAuthFailed(reason: String)
    case pake(step: Int, outgoing: Bool)
    case pakeCompleted(peerPubkey: String)
    case pakeFailed(reason: String, authentication: Bool)
    case captureState(CaptureState)
    case remoteVideo(present: Bool)
    case accessibility(granted: Bool)
    case inputApplied(type: String, events: Int)
    case clipboard(incoming: Bool, bytes: Int)
    case gesture(name: String)
    case cursorShape(CursorShape, outgoing: Bool)
}

@MainActor
public final class SessionCoordinator: ObservableObject, SessionTransport {

    // MARK: Published state

    @Published public private(set) var phase: SessionPhase = .idle
    @Published public private(set) var signalingState: SignalingState = .idle
    @Published public private(set) var peerPresence: PresenceState = .unknown
    @Published public private(set) var lastRoundTrip: TimeInterval?
    @Published public internal(set) var lastError: String?
    @Published public private(set) var iceState: ICELinkState = .new
    @Published public private(set) var dataChannelsOpen = false
    @Published public private(set) var remoteDisplay: DisplayInfoPayload?
    @Published public private(set) var captureState: CaptureState = .idle {
        didSet {
            guard captureState != oldValue else { return }
            emit(.captureState(captureState))
        }
    }
    @Published public private(set) var localDisplay: DisplayInfoPayload?
    @Published public private(set) var hasRemoteVideo = false
    @Published public private(set) var qualityMode: QualityWireMode = .auto
    @Published public private(set) var needsAccessCode = false
    @Published public private(set) var canInjectInput = true
    @Published public private(set) var injectedEventCount = 0
    @Published public private(set) var remoteCursorShape: CursorShape = .arrow

    public var state: SessionState {
        switch phase {
        case .idle: return .idle
        case .connecting: return .connecting
        case .live: return machine.sessionID.map { .connected(sessionID: $0) } ?? .connecting
        case .reconnecting: return .reconnecting
        case .closed(let reason): return reason == Wire.ByeReason.userEnded ? .idle : .failed(reason)
        }
    }

    public var sessionID: String? { machine.sessionID }
    public var isRelayOnly: Bool { peer?.isRelayOnly ?? machine.relayOnly }
    public var peerDeviceID: String? { machine.peerDeviceID }

    // MARK: Collaborators

    public let signaling: SignalingClient
    public private(set) var peer: PeerSession?

    // MARK: Phase 5 — input, gestures, clipboard

    public let injector = InputInjector()
    public var eventSink: InputEventSink
    public let input = RemoteInputSender()
    public var clipboardSyncEnabled = true {
        didSet { clipboard?.isEnabled = clipboardSyncEnabled }
    }
    private var clipboard: ClipboardMonitor?
    let machine: SessionStateMachine
    let identity: IdentityStore
    private let config: RCConfig
    private var ticker: Task<Void, Never>?
    private var watchedPeer: String?
    public let role: Wire.Role
    private var frameProducer: (any VideoFrameProducer)?
    private let captureSourceKind: CaptureSourceKind
    private var captureRetry: Task<Void, Never>?
    private var negotiating = false
    public let cursorObserver = SystemCursorObserver()
    public private(set) var expectedPeerPublicKey: String?

    // MARK: The access-code exchange (PROTOCOL.md §2.17) — see SessionPake.swift

    var pakeExchange: PakeExchange?
    var pakeComplete = false
    var pakeRequired = false
    var deferredPeerStart: Bool?
    var pakeControllerPubkey: String?
    var pakeTimeout: Task<Void, Never>?

    public let presence = SignalingPresenceSource()

    public var onAccessCodeRequired: ((String) -> Void)?
    public var onEvent: ((CoordinatorEvent) -> Void)?

    func emit(_ event: CoordinatorEvent) { onEvent?(event) }

    public init(identity: IdentityStore, role: Wire.Role, config: RCConfig = .current,
                captureSource: CaptureSourceKind = .fromEnvironment()) {
        self.identity = identity
        self.config = config
        self.role = role
        self.captureSourceKind = captureSource
        self.machine = SessionStateMachine(
            role: role,
            iceRestartDelay: config.iceRestartDelay,
            iceFailureGrace: config.iceFailureGrace,
            renewInterval: config.renewInterval)
        self.machine.setRelayOnly(config.forceTURNRelay)
        let sink = CGEventSink()
        self.eventSink = sink
        self.signaling = SignalingClient(config: config, identity: identity, role: role)
        self.signaling.delegate = self
        sink.onAccessibilityChange = { [weak self] granted in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.canInjectInput = granted
                self.emit(.accessibility(granted: granted))
            }
        }
        let clipboard = ClipboardMonitor(engine: ClipboardSyncEngine(originId: identity.deviceID))
        clipboard.onOutgoing = { [weak self] payload in
            guard let self, self.clipboardSyncEnabled else { return }
            guard self.peer?.send(.clipboard(payload)) == true else { return }
            self.emit(.clipboard(incoming: false, bytes: payload.text.utf8.count))
        }
        self.clipboard = clipboard
        cursorObserver.onChange = { [weak self] shape in
            guard let self, self.role == .host else { return }
            guard (try? self.peer?.sendCursorShape(shape)) != nil else {
                self.cursorObserver.reset()
                return
            }
            self.emit(.cursorShape(shape, outgoing: true))
        }
        self.input.send = { [weak self] outbound in
            _ = self?.peer?.send(outbound)
        }
        identity.sink = self.signaling
        presence.onWatch = { [weak self] deviceID in self?.watchPeer(deviceID: deviceID) }
        presence.onStopWatching = { [weak self] in self?.stopWatchingPeer() }
    }

    deinit { ticker?.cancel() }

    public func start() {
        signaling.start()
        guard ticker == nil else { return }
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 500_000_000)
                guard let self else { return }
                await self.perform(self.machine.tick())
            }
        }
    }

    public func stop() {
        ticker?.cancel()
        ticker = nil
        signaling.stop()
        stopCapture()
        peer?.close()
        peer = nil
    }

    // MARK: - Presence (PROTOCOL.md §2.7/§2.8)

    public func watchPeer(deviceID: String) {
        guard let canonical = DeviceID.canonicalize(deviceID) else { return }
        watchedPeer = canonical
        peerPresence = .unknown
        Task { try? await signaling.watch(deviceID: canonical) }
    }

    public func stopWatchingPeer() {
        guard let watchedPeer else { return }
        self.watchedPeer = nil
        peerPresence = .unknown
        Task { [signaling] in try? await signaling.unwatch(deviceID: watchedPeer) }
    }

    // MARK: - SessionTransport

    public func connect(deviceID: String, accessCode: String) async throws {
        try await connect(deviceID: deviceID, accessCode: accessCode, remember: false)
    }

    public func expectPeerPublicKey(_ pubkey: String?) {
        expectedPeerPublicKey = (pubkey?.isEmpty == false) ? pubkey : nil
    }

    public func connect(deviceID: String, accessCode: String, remember: Bool) async throws {
        guard let canonicalID = DeviceID.canonicalize(deviceID) else { throw TransportError.invalidDeviceID }
        guard let canonicalCode = AccessCode.canonicalize(accessCode) else { throw TransportError.invalidAccessCode }
        guard signaling.state.isAuthenticated else { throw ConnectFailure.notConnectedToServer }

        needsAccessCode = false
        lastError = nil
        await perform(machine.connectRequested(deviceID: canonicalID, accessCode: canonicalCode, remember: remember))
        syncPhase()
    }

    public func sendPing() throws { try peer?.sendPing() }

    public func sendDisplayInfo(width: Int, height: Int, scale: Double) throws {
        try peer?.sendDisplayInfo(DisplayInfoPayload(w: width, h: height, scale: scale))
    }

    public func dropSignalingSocket() { signaling.simulateSocketLoss() }

    public func forceICERestart() {
        emit(.iceRestartStarted(relayOnly: machine.relayOnly))
        Task { await renegotiate(restart: true) }
    }

    public func disconnect(reason: String) {
        Task { await perform(machine.userEnded(reason: reason)) }
    }

    // MARK: - Action execution

    func perform(_ actions: [SessionAction]) async {
        for action in actions { await perform(action) }
        syncPhase()
    }

    private func perform(_ action: SessionAction) async {
        switch action {
        case .sendConnectReq(let deviceID, let accessCode):
            do {
                let grant = try await signaling.connectRequest(deviceID: deviceID)
                expectPeerPublicKey(grant.hostPubkey)
                emit(.sessionGranted(sessionID: grant.sessionId, role: .controller))
                armPake(for: grant)
                await perform(machine.sessionGranted(grant))
                await startControllerPake(grant: grant, accessCode: accessCode)
            } catch {
                let failure = ConnectFailure(error)
                lastError = failure.localizedDescription
                emit(.connectFailed(failure))
                await perform(machine.connectFailed(code: failure.code))
            }

        case .sendResume(let sessionID, let token):
            do {
                let ok = try await signaling.resume(sessionID: sessionID, sessionToken: token)
                emit(.resumed(sessionID: ok.sessionId, peerAttached: ok.peerAttached))
                await perform(machine.resumeSucceeded(ok))
            } catch let error as WireError {
                let code = error.serverCode ?? "network"
                if (code == Wire.ErrorCode.noSession || code == Wire.ErrorCode.badToken),
                   machine.rememberedAccessCode != nil {
                    emit(.silentReconnect(reason: code))
                }
                await perform(machine.resumeFailed(code: code, retryAfterSec: error.retryAfterSec ?? 0))
            } catch {
                await perform(machine.resumeFailed(code: "network", retryAfterSec: 0))
            }

        case .scheduleResume(let afterSec):
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(afterSec) * 1_000_000_000)
                guard let self else { return }
                await self.perform(self.machine.tick())
            }

        case .sendRenew(let sessionID, let token):
            do {
                let ok = try await signaling.renew(sessionID: sessionID, sessionToken: token)
                machine.renewSucceeded(ok)
            } catch let error as WireError {
                await perform(machine.renewFailed(code: error.serverCode ?? "network"))
            } catch {
            }

        case .sendInputReset:
            peer?.sendInputReset()
            applyLocalInputReset()

        case .startPeerConnection(let offerer):
            guard pakeComplete else {
                deferredPeerStart = offerer
                return
            }
            startPeer(offerer: offerer)

        case .restartICE(let relayOnly):
            if relayOnly { peer?.switchToRelayOnly() }
            emit(.iceRestartStarted(relayOnly: peer?.isRelayOnly ?? relayOnly))
            await renegotiate(restart: true)

        case .reissueWatches:
            if let watchedPeer { Task { try? await signaling.watch(deviceID: watchedPeer) } }

        case .teardownPeerConnection:
            cursorObserver.reset()
            remoteCursorShape = .arrow
            applyLocalInputReset()
            input.isEnabled = false
            clipboard?.stop()
            stopCapture()
            hasRemoteVideo = false
            peer?.close()
            peer = nil
            dataChannelsOpen = false
            iceState = .closed

        case .clearStoredSession:
            negotiating = false
            expectedPeerPublicKey = nil
            clearPake()

        case .promptForAccessCode(let reason):
            needsAccessCode = true
            emit(.accessCodeRequired(reason: reason))
            onAccessCodeRequired?(reason)

        case .sendBye(let sessionID, let reason):
            try? await signaling.sendBye(sessionID: sessionID, reason: reason)
        }
    }

    private func syncPhase() {
        guard machine.phase != phase else { return }
        phase = machine.phase
        emit(.phase(phase))
    }

    // MARK: - Peer connection

    func startPeerAfterPake(offerer: Bool) { startPeer(offerer: offerer) }

    func refusePeerFromPake(reason: String) async { await refusePeer(reason: reason) }

    private func startPeer(offerer: Bool) {
        peer?.close()
        let session = PeerSession(iceServers: signaling.iceServers, isOfferer: offerer,
                                  mediaRole: role == .host ? .sendScreen : .receiveScreen,
                                  forceTURNRelay: config.forceTURNRelay)
        session.delegate = self
        peer = session
        do {
            try session.start()
        } catch {
            RCLog.error("startPeer failed: \(error.localizedDescription)")
            lastError = error.localizedDescription
            return
        }
        RCLog.info("peer started offerer=\(offerer) media=\(session.mediaRole)")
        if role == .host { startCapture() }
        if offerer {
            Task { await renegotiate(restart: false) }
        }
    }

    private func renegotiate(restart: Bool) async {
        guard let peer, let sessionID = machine.sessionID, !negotiating else { return }
        negotiating = true
        defer { negotiating = false }
        do {
            let offer = try await peer.createOffer(restart: restart)
            try await sendSignedSDP(sessionID: sessionID, type: offer.type, sdp: offer.sdp,
                                    restart: restart)
        } catch {
            RCLog.error("offer failed: \(error.localizedDescription)")
            lastError = error.localizedDescription
        }
    }

    // MARK: - Signed SDP (PROTOCOL.md §2.12)

    private func sendSignedSDP(sessionID: String, type: String, sdp: String,
                               restart: Bool) async throws {
        guard pakeComplete, let pake = pakeExchange else {
            throw SkipperCoreError("an sdp is never sent before the access-code exchange completes")
        }
        let signature = try SdpAuth.sign(pake: pake, sessionID: sessionID, sdpType: type, sdp: sdp,
                                         with: identity, pubkey: identity.publicKeyBase64)
        try await signaling.sendSDP(sessionID: sessionID, type: type, sdp: sdp,
                                    restart: restart, signature: signature)
    }

    private func refusePeer(reason: String) async {
        RCLog.error("peer authentication failed: \(reason)")
        lastError = SessionCoordinator.peerAuthFailureMessage
        emit(.peerAuthFailed(reason: reason))
        await perform(machine.userEnded(reason: Wire.ByeReason.peerAuthFailed))
    }

    public static let peerAuthFailureMessage = "The other device could not be verified."
}

// MARK: - SignalingClientDelegate

extension SessionCoordinator: SignalingClientDelegate {

    public func signaling(_ client: SignalingClient, didChangeState state: SignalingState) {
        signalingState = state
        emit(.signalingState(state))
        presence.setServerReachable(state.isAuthenticated)
        if case .authenticated = state {} else if watchedPeer != nil, !state.isAuthenticated {
            peerPresence = .unknown
        }
    }

    public func signaling(_ client: SignalingClient, didAuthenticate hello: HelloOKPayload) {
        emit(.authenticated(hello))
        Task { await perform(machine.signalingAuthenticated(activeSessionID: hello.activeSessionId)) }
    }

    public func signaling(_ client: SignalingClient, didDisconnect error: Swift.Error?) {
        emit(.signalingDisconnected(reason: error?.localizedDescription ?? "closed"))
        Task { await perform(machine.signalingLost()) }
    }

    public func signaling(_ client: SignalingClient, didReceive envelope: Envelope) {
        Task { await handlePush(envelope) }
    }

    private func handlePush(_ envelope: Envelope) async {
        switch envelope.type {
        case Wire.MessageType.presence:
            guard let presence = try? envelope.decodePayload(PresencePayload.self) else { return }
            guard presence.deviceId == watchedPeer else { return }
            peerPresence = presence.online ? .online : .offline
            self.presence.apply(online: presence.online, since: presence.since)
            emit(.presence(deviceID: presence.deviceId, online: presence.online))

        case Wire.MessageType.sessionStart:
            guard let grant = try? envelope.decodePayload(SessionGrantPayload.self) else { return }
            RCLog.info("session_start received")
            emit(.sessionGranted(sessionID: grant.sessionId, role: .host))
            armPake(for: grant)
            await perform(machine.sessionGranted(grant))
            await startHostPake(grant: grant)

        case Wire.MessageType.pake:
            guard let frame = try? envelope.decodePayload(PakePayload.self) else { return }
            await handlePake(frame)

        case Wire.MessageType.peerState:
            break

        case Wire.MessageType.sdp:
            guard let sdp = try? envelope.decodePayload(SDPPayload.self) else { return }
            RCLog.info("remote sdp \(sdp.sdpType)")
            await handleRemoteSDP(sdp)

        case Wire.MessageType.ice:
            guard let ice = try? envelope.decodePayload(ICEPayload.self) else { return }
            try? await peer?.addCandidate(ice.candidate, sdpMid: ice.sdpMid, sdpMLineIndex: ice.sdpMLineIndex)

        case Wire.MessageType.bye:
            guard let bye = try? envelope.decodePayload(ByePayload.self) else { return }
            guard bye.sessionId == machine.sessionID else { return }
            emit(.bye(reason: bye.reason))
            peerEndedExchange(byeReason: bye.reason)
            await perform(machine.closeLocally(reason: bye.reason))

        case Wire.MessageType.error:
            if let wire = envelope.asProtocolError { lastError = wire.errorDescription }

        default:
            break
        }
    }

    private func handleRemoteSDP(_ sdp: SDPPayload) async {
        guard sdp.sessionId == machine.sessionID else { return }
        guard pakeComplete, let pake = pakeExchange else {
            RCLog.error("dropped an sdp that arrived before the access code was proved")
            return
        }
        guard let signature = sdp.signature else {
            await refusePeer(reason: "the sdp carried no signature or no mac")
            return
        }
        do {
            try SdpAuth.verify(pake: pake, sessionID: sdp.sessionId, sdpType: sdp.sdpType,
                               sdp: sdp.sdp, signature: signature,
                               expectedPubkey: expectedPeerPublicKey)
        } catch {
            await refusePeer(reason: error.localizedDescription)
            return
        }
        if peer == nil { startPeer(offerer: machine.isOfferer) }
        guard let peer else { return }
        do {
            try await peer.setRemoteDescription(type: sdp.sdpType, sdp: sdp.sdp,
                                                verifiedFingerprints: signature.fingerprints)
        } catch PeerSessionError.installedFingerprintsRejected(let why) {
            await refusePeer(reason: why)
            return
        } catch {
            RCLog.error("remote \(sdp.sdpType) failed: \(error.localizedDescription)")
            lastError = error.localizedDescription
            return
        }
        do {
            emit(.remoteDescription(type: sdp.sdpType, restart: sdp.restart ?? false))
            if sdp.sdpType == "offer" {
                let answer = try await peer.createAnswer()
                try await sendSignedSDP(sessionID: sdp.sessionId, type: answer.type,
                                        sdp: answer.sdp, restart: sdp.restart ?? false)
            }
        } catch {
            RCLog.error("remote \(sdp.sdpType) failed: \(error.localizedDescription)")
            lastError = error.localizedDescription
        }
    }
}

// MARK: - PeerSessionDelegate

extension SessionCoordinator: PeerSessionDelegate {

    public func peerSession(_ session: PeerSession, didCreateLocalDescription type: String, sdp: String, restart: Bool) {
        guard let sessionID = machine.sessionID else { return }
        Task { [weak self] in
            try? await self?.sendSignedSDP(sessionID: sessionID, type: type, sdp: sdp,
                                           restart: restart)
        }
    }

    public func peerSession(_ session: PeerSession, didGatherCandidate candidate: String, sdpMid: String?, sdpMLineIndex: Int?) {
        guard let sessionID = machine.sessionID else { return }
        Task {
            try? await signaling.sendICE(sessionID: sessionID, candidate: candidate,
                                         sdpMid: sdpMid, sdpMLineIndex: sdpMLineIndex)
        }
    }

    public func peerSession(_ session: PeerSession, didChangeICEState state: ICELinkState) {
        iceState = state
        emit(.ice(state))
        Task { await perform(machine.iceStateChanged(to: state)) }
    }

    public func peerSession(_ session: PeerSession, didOpenDataChannel label: String) {
        dataChannelsOpen = session.isReady
        emit(.dataChannel(label: label, allOpen: session.isReady))
        guard label == PeerSession.ctrlLabel else { return }
        clipboard?.isEnabled = clipboardSyncEnabled
        clipboard?.start()
        input.isEnabled = (role == .controller)
        switch role {
        case .host:
            if let localDisplay { try? session.sendDisplayInfo(localDisplay) }
            cursorObserver.reset()
            cursorObserver.poll(force: true)
        case .controller:
            try? session.sendQuality(qualityMode)
        }
    }

    public func peerSessionDidReceiveRemoteVideo(_ session: PeerSession) {
        let present = session.remoteVideoTrack != nil
        guard present != hasRemoteVideo else { return }
        hasRemoteVideo = present
        emit(.remoteVideo(present: present))
    }

    public func peerSession(_ session: PeerSession, didReceiveCtrl envelope: Envelope) {
        applyInput(envelope)
        applyClipboard(envelope)
        if envelope.type == CtrlType.quality, role == .host,
           let payload = try? envelope.decodePayload(QualityPayload.self) {
            applyQuality(payload.wireMode)
        }
        if envelope.type == CtrlType.cursorShape, role == .controller,
           let payload = try? envelope.decodePayload(CursorShapePayload.self) {
            remoteCursorShape = payload.cursorShape
            emit(.cursorShape(payload.cursorShape, outgoing: false))
        }
        if envelope.type == CtrlType.sessionClose,
           let close = try? envelope.decodePayload(SessionClosePayload.self) {
            Task { await perform(machine.closeLocally(reason: close.reason)) }
        }
    }

    public func peerSession(_ session: PeerSession, didReceiveMouseMove move: MouseMovePayload) {
        guard role == .host else { return }
        let events = injector.mouseMove(move)
        deliver(events, type: CtrlType.mouseMove)
    }

    public func peerSession(_ session: PeerSession, didMeasureRoundTrip seconds: TimeInterval) {
        lastRoundTrip = seconds
        emit(.roundTrip(seconds))
    }

    public func peerSession(_ session: PeerSession, didReceiveDisplayInfo info: DisplayInfoPayload) {
        remoteDisplay = info
    }
}

// MARK: - Input, gestures and clipboard (Phase 5)

public extension SessionCoordinator {

    internal func applyInput(_ envelope: Envelope) {
        guard role == .host else { return }
        guard let events = injector.handle(ctrl: envelope) else { return }
        if envelope.type == CtrlType.gesture,
           let payload = try? envelope.decodePayload(GesturePayload.self) {
            emit(.gesture(name: payload.name))
        }
        deliver(events, type: envelope.type)
    }

    internal func deliver(_ events: [InjectedEvent], type: String) {
        guard !events.isEmpty else {
            emit(.inputApplied(type: type, events: 0))
            return
        }
        injector.target = .mainDisplay
        eventSink.post(events)
        injectedEventCount += events.count
        cursorObserver.pollAfterInput()
        emit(.inputApplied(type: type, events: events.count))
    }

    internal func applyLocalInputReset() {
        let events = injector.reset()
        input.forgetHeldState()
        guard !events.isEmpty else { return }
        eventSink.post(events)
        injectedEventCount += events.count
        emit(.inputApplied(type: CtrlType.inputReset, events: events.count))
    }

    internal func applyClipboard(_ envelope: Envelope) {
        guard envelope.type == CtrlType.clipboardText, clipboardSyncEnabled else { return }
        guard let payload = try? envelope.decodePayload(ClipboardTextPayload.self) else { return }
        guard clipboard?.apply(payload) == true else { return }
        emit(.clipboard(incoming: true, bytes: payload.text.utf8.count))
    }

    func sendGesture(_ name: GestureName) {
        guard role == .controller else { return }
        input.gesture(name)
        emit(.gesture(name: name.rawValue))
    }

    func sendKey(down: Bool, keycode: CGKeyCode, modifiers: KeyModifiers) {
        guard role == .controller else { return }
        input.key(down: down, keycode: keycode, modifiers: modifiers)
    }

    func sendPointer(_ event: RemotePointerEvent) {
        guard role == .controller else { return }
        input.handle(event)
    }
}

// MARK: - Media (Phase 4)

public extension SessionCoordinator {

    func setQuality(_ mode: QualityWireMode) {
        qualityMode = mode
        guard role == .controller else { return }
        try? peer?.sendQuality(mode)
    }

    func videoStatistics() async -> VideoStatistics {
        guard let peer else { return VideoStatistics() }
        return await peer.videoStatistics()
    }

    internal var remoteTrack: RTCVideoTrack? { peer?.remoteVideoTrack }
}

// MARK: Host capture pipeline

extension SessionCoordinator {

    func startCapture() {
        guard role == .host, frameProducer == nil else { return }
        RCLog.info("starting capture, source=\(captureSourceKind.rawValue), screenRecordingGranted=\(ScreenCaptureSource.hasScreenRecordingPermission)")
        captureState = .starting

        let producer: any VideoFrameProducer
        switch captureSourceKind {
        case .screen: producer = ScreenCaptureSource()
        case .synthetic: producer = SyntheticFrameSource()
        }
        producer.onFrame = { [weak self] pixelBuffer, timeNs in
            guard let self, let peer = self.peer else { return }
            peer.submit(pixelBuffer: pixelBuffer, timeNs: timeNs)
            if peer.ctrlOpen { self.cursorObserver.poll() }
        }
        producer.onSizeChange = { [weak self] width, height, scale in
            self?.captureDidResize(width: width, height: height, scale: scale)
        }
        producer.onFailure = { [weak self] failure in
            self?.captureDidFail(failure)
        }
        frameProducer = producer

        Task { [weak self] in
            do {
                try await producer.start()
                guard let self else { return }
                self.captureState = .running(width: self.localDisplay?.w ?? 0,
                                             height: self.localDisplay?.h ?? 0,
                                             fps: QualityProfile.activeFramerate)
                self.applyQuality(self.qualityMode)
            } catch {
                self?.captureDidFail((error as? CaptureFailure) ?? .other(error.localizedDescription))
            }
        }
    }

    func stopCapture() {
        captureRetry?.cancel()
        captureRetry = nil
        guard let producer = frameProducer else { return }
        frameProducer = nil
        captureState = .idle
        Task { await producer.stop() }
    }

    func captureDidResize(width: Int, height: Int, scale: Double) {
        let info = DisplayInfoPayload(w: width, h: height, scale: scale)
        guard info != localDisplay else { return }
        localDisplay = info
        if case .running = captureState {
            captureState = .running(width: width, height: height, fps: QualityProfile.activeFramerate)
        }
        try? peer?.sendDisplayInfo(info)
        applyQuality(qualityMode)
    }

    func captureDidFail(_ failure: CaptureFailure) {
        RCLog.error("capture failed: \(failure.localizedDescription)")
        captureState = .failed(failure)
        lastError = failure.localizedDescription
        let producer = frameProducer
        frameProducer = nil
        Task { await producer?.stop() }

        guard failure.isPermissionProblem, captureSourceKind == .screen else { return }
        captureRetry?.cancel()
        captureRetry = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                guard let self, self.frameProducer == nil else { return }
                guard case .live = self.phase else { continue }
                guard ScreenCaptureSource.hasScreenRecordingPermission else { continue }
                self.startCapture()
                return
            }
        }
    }

    func applyQuality(_ mode: QualityWireMode) {
        qualityMode = mode
        guard role == .host else { return }
        let profile = QualityProfile.profile(for: mode,
                                             displayWidth: localDisplay?.w ?? 0,
                                             displayHeight: localDisplay?.h ?? 0)
        peer?.apply(quality: profile)
        if let screen = frameProducer as? ScreenCaptureSource {
            Task { await screen.apply(profile: profile) }
        }
    }
}
