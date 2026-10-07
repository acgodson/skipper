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
    case declined
    case noAnswer
    case other(code: String, message: String)

    public init(_ error: Swift.Error) {
        guard let wire = error as? WireError, let code = wire.serverCode else {
            self = .other(code: "network", message: error.localizedDescription)
            return
        }
        switch code {
        case Wire.ByeReason.authFailed: self = .authFailed
        case Wire.ByeReason.declined: self = .declined
        case Wire.ByeReason.timeout: self = .noAnswer
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
        case .declined: return Wire.ByeReason.declined
        case .noAnswer: return Wire.ByeReason.timeout
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
            return "That Mac is offline. It has to be awake, running SkipperDesk and connected to the internet."
        case .busy:
            return "That Mac already has a remote session. Only one at a time is allowed \u{2014} end the other session first."
        case .rateLimited(let seconds):
            let minutes = seconds / 60
            let wait = minutes >= 1 ? "\(minutes) minute\(minutes == 1 ? "" : "s")" : "\(seconds) seconds"
            return "Too many incorrect access codes. Wait \(wait) before trying again."
        case .unknownDevice:
            return "No Mac has that Device ID. Check it on the other Mac."
        case .selfConnect:
            return "That is this Mac's own Device ID."
        case .notConnectedToServer:
            return "Not connected to SkipperDesk yet. Try again in a moment."
        case .declined:
            return "The other Mac declined the connection."
        case .noAnswer:
            return "The other Mac did not answer in time."
        case .other(let code, let message):
            return RCLog.enabled ? "\(message) (\(code))" : message
        }
    }
}

public enum CoordinatorEvent {
    case signalingState(SignalingState)
    case signalingDisconnected(reason: String)
    case authenticated(HelloOKPayload)
    case presence(deviceID: String, online: Bool)
    case sessionGranted(sessionID: String, role: Wire.Role)
    case iceServers(sessionID: String, count: Int, turn: Bool)
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
    case consentRequested(ConsentRequest)
    case consentEnded(ConsentOutcome, automatic: Bool)
    case awaitingPeerAcceptance
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
    @Published public internal(set) var consentRequest: ConsentRequest?
    @Published public internal(set) var awaitingPeerAcceptance = false

    public var state: SessionState { SessionState(phase: phase, sessionID: machine.sessionID) }

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
    var pakeControllerPubkey: String?
    var pakeTimeout: Task<Void, Never>?

    // MARK: Host consent (PROTOCOL.md §2.17 Consent) — see SessionConsent.swift

    var consentControllerKey: String?
    var heldRemoteSDP: SDPPayload?
    var heldCandidates: [ICEPayload] = []
    var acceptanceWatch: Task<Void, Never>?

    public var consentRequired: Bool {
        get { machine.consentRequired }
        set { machine.consentRequired = newValue }
    }

    public let presence = SignalingPresenceSource()

    public var onAccessCodeRequired: ((String) -> Void)?
    public var onEvent: ((CoordinatorEvent) -> Void)?

    /// The ceiling the server stated for this Mac's own account, and whether the answer
    /// it came from is still fresh (`API.md` §4.4). The coordinator does not reach for an
    /// account itself: whoever owns the entitlement cache supplies this, and a host with
    /// no provider at all is treated exactly like a host whose cache went stale.
    public var hostQualityCeiling: (() -> (ceiling: QualityWireMode, fresh: Bool))?

    /// The last route the host's own WebRTC stack reported, sampled while the session
    /// runs so that a `bye` has something to report when the peer connection is already
    /// coming down. Measurement only — nothing prices it (`API.md` §5.4).
    private var lastICEPath: ICEPathStatistics?
    private var icePathSampler: Task<Void, Never>?

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
                guard await beginSession(grant, as: .controller) else {
                    throw WireError.badPayload("connect_ok named a session this Mac cannot use")
                }
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
                try? await Task.sleep(nanoseconds: WireBounds.nanoseconds(TimeInterval(afterSec)))
                guard let self else { return }
                await self.perform(self.machine.tick())
            }

        case .sendRenew(let sessionID, let token):
            do {
                let ok = try await signaling.renew(sessionID: sessionID, sessionToken: token)
                machine.renewSucceeded(ok)
                if let servers = ok.iceServers, ok.sessionId == machine.sessionID {
                    await applySessionICEServers(servers, sessionID: ok.sessionId)
                }
            } catch let error as WireError {
                await perform(machine.renewFailed(code: error.serverCode ?? "network"))
            } catch {
            }

        case .sendInputReset:
            peer?.sendInputReset()
            applyLocalInputReset()

        case .startPeerConnection(let offerer):
            guard pakeComplete else {
                RCLog.error("refused to start a peer before the access-code exchange completed")
                return
            }
            peerStarting()
            startPeer(offerer: offerer)
            await releaseHeldSignals()

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
            signaling.dropSessionICEServers()
            negotiating = false
            clearConsentState()
            expectedPeerPublicKey = nil
            clearPake()

        case .promptForAccessCode(let reason):
            needsAccessCode = true
            emit(.accessCodeRequired(reason: reason))
            onAccessCodeRequired?(reason)

        case .sendBye(let sessionID, let reason):
            let relay = hostRelayReport()
            try? await signaling.sendBye(sessionID: sessionID, reason: reason,
                                         relayUsed: relay.used, bytesRelayed: relay.bytes)
            if role == .controller, reason == Wire.ByeReason.timeout { reportEnded(.noAnswer) }

        case .promptForConsent(let expiresAt, let promptID, let replacesPrevious):
            await presentConsent(expiresAt: expiresAt, promptID: promptID, replacesPrevious: replacesPrevious)

        case .dismissConsentPrompt(let outcome):
            dismissConsent(outcome)
        }
    }

    private func syncPhase() {
        guard machine.phase != phase else { return }
        phase = machine.phase
        if phase != .connecting { stopAwaitingAcceptance() }
        emit(.phase(phase))
    }

    func reportEnded(_ failure: ConnectFailure) {
        lastError = failure.localizedDescription
        emit(.connectFailed(failure))
    }

    // MARK: - Peer connection

    func refusePeerFromPake(reason: String) async { await refusePeer(reason: reason) }

    /// A grant the state machine refuses (a malformed id, say) changes
    /// nothing: the current session keeps its exchange and its prompt.
    private func beginSession(_ grant: SessionGrantPayload, as grantedRole: Wire.Role) async -> Bool {
        let actions = machine.sessionGranted(grant)
        guard machine.lastRejection == nil else {
            RCLog.error("ignored a session grant: \(machine.lastRejection ?? "")")
            return false
        }
        signaling.dropSessionICEServers()
        if grantedRole == .controller { expectPeerPublicKey(grant.hostPubkey) }
        emit(.sessionGranted(sessionID: grant.sessionId, role: grantedRole))
        armPake(for: grant)
        await perform(actions)
        return true
    }

    /// Protocol v5 `ice_servers` (and `renew_ok.iceServers`): this session's
    /// relay credentials. They go to the live peer connection at once and are
    /// dropped with the session.
    func applySessionICEServers(_ servers: [ICEServerSpec], sessionID: String) async {
        let actions = machine.iceServersArrived(sessionID: sessionID)
        guard machine.lastRejection == nil else { return }
        signaling.adoptSessionICEServers(servers, sessionID: sessionID)
        peer?.updateICEServers(servers)
        emit(.iceServers(sessionID: sessionID, count: servers.count,
                         turn: servers.contains { $0.carriesCredentials }))
        await perform(actions)
    }

    private func startPeer(offerer: Bool) {
        peer?.close()
        let session = PeerSession(iceServers: signaling.iceServers(forSession: machine.sessionID), isOfferer: offerer,
                                  mediaRole: role == .host ? .sendScreen : .receiveScreen,
                                  forceTURNRelay: machine.relayOnly)
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

    public static let peerAuthFailureMessage = "This is not the Mac you connected to, so the session was stopped."
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
            guard role == .host, let grant = try? envelope.decodePayload(SessionGrantPayload.self) else { return }
            RCLog.info("session_start received")
            guard await beginSession(grant, as: .host) else { return }
            await startHostPake(grant: grant)

        case Wire.MessageType.iceServers:
            guard let push = try? envelope.decodePayload(ICEServersPayload.self) else { return }
            await applySessionICEServers(push.iceServers, sessionID: push.sessionId)

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
            await handleRemoteICE(ice)

        case Wire.MessageType.bye:
            guard let bye = try? envelope.decodePayload(ByePayload.self) else { return }
            guard bye.sessionId == machine.sessionID else { return }
            emit(.bye(reason: bye.reason))
            peerEndedExchange(byeReason: bye.reason)
            if role == .controller, bye.reason == Wire.ByeReason.declined { reportEnded(.declined) }
            await perform(machine.closeLocally(reason: bye.reason))

        case Wire.MessageType.error:
            if let wire = envelope.asProtocolError { lastError = wire.errorDescription }

        default:
            break
        }
    }

    func handleRemoteICE(_ ice: ICEPayload) async {
        switch disposition(of: ice.sessionId) {
        case .drop:
            return
        case .hold:
            hold(ice)
        case .apply:
            do {
                try await peer?.addCandidate(ice.candidate, sdpMid: ice.sdpMid, sdpMLineIndex: ice.sdpMLineIndex)
            } catch {
                RCLog.error("dropped a remote candidate: \(error.localizedDescription)")
            }
        }
    }

    /// A remote description is applied only to the peer connection the state
    /// machine started for this session; nothing here ever creates one.
    func handleRemoteSDP(_ sdp: SDPPayload) async {
        guard disposition(of: sdp.sessionId) != .drop else { return }
        guard pakeComplete, let pake = pakeExchange, let expectedPubkey = expectedPeerPublicKey else {
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
                               expectedPubkey: expectedPubkey)
        } catch {
            await refusePeer(reason: error.localizedDescription)
            return
        }
        guard disposition(of: sdp.sessionId) == .apply, let peer else {
            hold(sdp)
            return
        }
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
        guard session === peer else { return }
        guard let sessionID = machine.sessionID else { return }
        Task { [weak self] in
            try? await self?.sendSignedSDP(sessionID: sessionID, type: type, sdp: sdp,
                                           restart: restart)
        }
    }

    public func peerSession(_ session: PeerSession, didGatherCandidate candidate: String, sdpMid: String?, sdpMLineIndex: Int?) {
        guard session === peer else { return }
        guard let sessionID = machine.sessionID else { return }
        Task {
            try? await signaling.sendICE(sessionID: sessionID, candidate: candidate,
                                         sdpMid: sdpMid, sdpMLineIndex: sdpMLineIndex)
        }
    }

    public func peerSession(_ session: PeerSession, didChangeICEState state: ICELinkState) {
        guard session === peer else { return }
        iceState = state
        emit(.ice(state))
        Task { await perform(machine.iceStateChanged(to: state)) }
    }

    public func peerSession(_ session: PeerSession, didOpenDataChannel label: String) {
        guard session === peer else { return }
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
        guard session === peer else { return }
        let present = session.remoteVideoTrack != nil
        guard present != hasRemoteVideo else { return }
        hasRemoteVideo = present
        emit(.remoteVideo(present: present))
    }

    public func peerSession(_ session: PeerSession, didReceiveCtrl envelope: Envelope) {
        guard session === peer else { return }
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
        guard session === peer else { return }
        guard role == .host else { return }
        let events = injector.mouseMove(move)
        deliver(events, type: CtrlType.mouseMove)
    }

    public func peerSession(_ session: PeerSession, didMeasureRoundTrip seconds: TimeInterval) {
        guard session === peer else { return }
        lastRoundTrip = seconds
        emit(.roundTrip(seconds))
    }

    public func peerSession(_ session: PeerSession, didReceiveDisplayInfo info: DisplayInfoPayload) {
        guard session === peer else { return }
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

    func icePathStatistics() async -> ICEPathStatistics? {
        guard let peer else { return nil }
        return await peer.icePathStatistics()
    }

    /// What this Mac will say about the route its own media took. Only a host reports:
    /// the host is the party whose account would pay, and a controller's claim about a
    /// host's relay use is discarded by the server anyway (`PROTOCOL.md` §2.14.1).
    /// Measurement only — no charge reads it (`API.md` §5.4).
    func hostRelayReport() -> (used: Bool?, bytes: Int64?) {
        guard role == .host, let path = lastICEPath, path.usesRelay else { return (nil, nil) }
        let carried = Int64(path.bytesSent) + Int64(path.bytesReceived)
        return (true, carried > 0 ? carried : nil)
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
                self.startICEPathSampling()
            } catch {
                self?.captureDidFail((error as? CaptureFailure) ?? .other(error.localizedDescription))
            }
        }
    }

    /// Byte counters on a candidate pair are cumulative, so the last sample before
    /// teardown is the figure to report; sampling only bounds how stale it is. The
    /// interval is loose on purpose — at the `auto` ceiling it risks under-reporting a
    /// few megabytes, which is immaterial to a relay *fraction* and is the right trade
    /// against polling `getStats` on a live session.
    static let icePathSampleInterval: UInt64 = 5_000_000_000

    func startICEPathSampling() {
        guard role == .host, icePathSampler == nil else { return }
        icePathSampler = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                if let path = await self.icePathStatistics(), path.selected {
                    self.lastICEPath = path
                }
                try? await Task.sleep(nanoseconds: Self.icePathSampleInterval)
            }
        }
    }

    func stopICEPathSampling() {
        icePathSampler?.cancel()
        icePathSampler = nil
    }

    func stopCapture() {
        captureRetry?.cancel()
        captureRetry = nil
        stopICEPathSampling()
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

    /// The gate. The host owns the encoder, so this is where a mode the account may not
    /// have stops being available: the requested mode is clamped to the server's stated
    /// ceiling before any profile is built, and a controller that asks for more simply
    /// never gets it configured (`API.md` §4.4). A ceiling that is missing or stale
    /// clamps to `auto` — the answer must fail closed, because the alternative is that
    /// an unreachable account server hands out the top tier.
    func permittedQuality(_ requested: QualityWireMode) -> QualityWireMode {
        guard role == .host else { return requested }
        let stated = hostQualityCeiling?()
        return QualityWireMode.permitted(requested: requested,
                                         stated: stated?.ceiling,
                                         fresh: stated?.fresh ?? false)
    }

    func applyQuality(_ mode: QualityWireMode) {
        qualityMode = mode
        guard role == .host else { return }
        let applied = permittedQuality(mode)
        let profile = QualityProfile.profile(for: applied,
                                             displayWidth: localDisplay?.w ?? 0,
                                             displayHeight: localDisplay?.h ?? 0)
        peer?.apply(quality: profile)
        if let screen = frameProducer as? ScreenCaptureSource {
            Task { await screen.apply(profile: profile) }
        }
    }
}
