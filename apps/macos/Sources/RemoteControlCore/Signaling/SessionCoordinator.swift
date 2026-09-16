import Foundation
import SkipperCore
import WebRTC

/// Errors the Connect flow shows the user, mapped from PROTOCOL.md §7 codes so
/// the UI can be specific rather than saying "connection failed".
public enum ConnectFailure: Swift.Error, LocalizedError, Equatable {
    case badCode
    case offline
    case busy
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
        case Wire.ErrorCode.badCode: self = .badCode
        case Wire.ErrorCode.offline: self = .offline
        case Wire.ErrorCode.busy: self = .busy
        case Wire.ErrorCode.rateLimited: self = .rateLimited(retryAfterSec: wire.retryAfterSec ?? 60)
        case Wire.ErrorCode.unknownDevice: self = .unknownDevice
        case Wire.ErrorCode.selfConnect: self = .selfConnect
        default: self = .other(code: code, message: wire.errorDescription ?? code)
        }
    }

    public var code: String {
        switch self {
        case .badCode: return Wire.ErrorCode.badCode
        case .offline: return Wire.ErrorCode.offline
        case .busy: return Wire.ErrorCode.busy
        case .rateLimited: return Wire.ErrorCode.rateLimited
        case .unknownDevice: return Wire.ErrorCode.unknownDevice
        case .selfConnect: return Wire.ErrorCode.selfConnect
        case .notConnectedToServer: return "no_server"
        case .other(let code, _): return code
        }
    }

    public var errorDescription: String? {
        switch self {
        case .badCode:
            return "That access code was not accepted. Check it on the other Mac — codes are case-insensitive but every character counts."
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

/// Everything worth observing from outside, in one stream. The SwiftUI views
/// bind to the `@Published` properties; `rc-node` (the headless driver used by
/// scripts/test-transport.sh) subscribes to this so an integration test can
/// assert on real events rather than on scraped log text.
public enum CoordinatorEvent {
    case signalingState(SignalingState)
    /// The control plane dropped. Carries the reason so an operator (and the
    /// integration test) can tell a pin rejection from a network blip.
    case signalingDisconnected(reason: String)
    case authenticated(HelloOKPayload)
    case presence(deviceID: String, online: Bool)
    case sessionGranted(sessionID: String, role: Wire.Role)
    /// A session was re-attached WITHOUT the access code (PROTOCOL.md §4.3).
    case resumed(sessionID: String, peerAttached: Bool)
    /// The server had lost the session and we silently reconnected with a
    /// remembered code instead of prompting.
    case silentReconnect(reason: String)
    case phase(SessionPhase)
    case ice(ICELinkState)
    case dataChannel(label: String, allOpen: Bool)
    case roundTrip(TimeInterval)
    case connectFailed(ConnectFailure)
    case bye(reason: String)
    case accessCodeRequired(reason: String)
    case iceRestartStarted
    /// A remote offer/answer was applied. `restart` mirrors PROTOCOL.md §2.12's
    /// advisory flag, which is how the far side proves an ICE restart completed.
    case remoteDescription(type: String, restart: Bool)
    /// A remote offer/answer was REFUSED because its signed fingerprints did
    /// not verify. The session is over; this is never retried.
    case peerAuthFailed(reason: String)
    /// HOST: the capture pipeline changed state, including "the Screen
    /// Recording grant is missing", which must never be a silent black screen.
    case captureState(CaptureState)
    /// CONTROLLER: a remote video track was attached. Frames are a separate
    /// question — see `videoStatistics()`.
    case remoteVideo(present: Bool)
    /// HOST: the Accessibility grant changed. Without it every injected event
    /// is discarded by the window server, so this must never be silent.
    case accessibility(granted: Bool)
    /// HOST: an input message was applied, and how many OS events it became.
    /// Zero is meaningful — it is what a dropped stale packet looks like.
    case inputApplied(type: String, events: Int)
    /// Clipboard text crossed in one direction. Byte count only, never text.
    case clipboard(incoming: Bool, bytes: Int)
    /// A gesture was executed on the host.
    case gesture(name: String)
}

/// Binds `SignalingClient`, `PeerSession` and `SessionStateMachine` together.
///
/// This is the object the UI talks to. It performs the actions the state machine
/// returns and nothing else — every *decision* about resume, ICE restart, input
/// reset and when a session is finally dead lives in the machine, where it can
/// be tested without a network.
@MainActor
public final class SessionCoordinator: ObservableObject, SessionTransport {

    // MARK: Published state

    @Published public private(set) var phase: SessionPhase = .idle
    @Published public private(set) var signalingState: SignalingState = .idle
    @Published public private(set) var peerPresence: PresenceState = .unknown
    @Published public private(set) var lastRoundTrip: TimeInterval?
    @Published public private(set) var lastError: String?
    @Published public private(set) var iceState: ICELinkState = .new
    @Published public private(set) var dataChannelsOpen = false
    @Published public private(set) var remoteDisplay: DisplayInfoPayload?
    /// HOST: what the capture pipeline is doing, including the "Screen Recording
    /// is not granted" case that must never be a silent black screen.
    @Published public private(set) var captureState: CaptureState = .idle {
        didSet {
            guard captureState != oldValue else { return }
            emit(.captureState(captureState))
        }
    }
    /// HOST: the size of what we are actually capturing, i.e. what goes out as
    /// `display_info`.
    @Published public private(set) var localDisplay: DisplayInfoPayload?
    /// CONTROLLER: a decoded remote video track exists. The view still shows a
    /// waiting state until the first frame changes its size.
    @Published public private(set) var hasRemoteVideo = false
    /// CONTROLLER: the quality strategy in force, mirrored to the host.
    @Published public private(set) var qualityMode: QualityWireMode = .auto
    /// Set when the session died for a reason that requires the access code
    /// again. The UI shows the Connect form; nothing else may do so.
    @Published public private(set) var needsAccessCode = false
    /// HOST: false when this Mac cannot inject input because the Accessibility
    /// grant is missing. Surfaced by name in the UI (PermissionKind.accessibility).
    @Published public private(set) var canInjectInput = true
    /// HOST: how many OS events have actually been posted this session. A stub
    /// cannot make this climb.
    @Published public private(set) var injectedEventCount = 0

    /// The transport seam the Phase 2 UI already talks to.
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
    public var peerDeviceID: String? { machine.peerDeviceID }

    // MARK: Collaborators

    public let signaling: SignalingClient
    public private(set) var peer: PeerSession?

    // MARK: Phase 5 — input, gestures, clipboard

    /// HOST: translates `ctrl`/`hi` messages into OS events. Present on both
    /// roles but only fed on the host, so the controller can never inject into
    /// itself.
    public let injector = InputInjector()
    /// Where injected events go. Replaceable so a test can record instead of
    /// posting; the app always uses the real `CGEventSink`.
    public var eventSink: InputEventSink
    /// CONTROLLER: the UI's one route onto the wire.
    public let input = RemoteInputSender()
    /// Respects the "Clipboard Sync" setting; assignment takes effect at once.
    public var clipboardSyncEnabled = true {
        didSet { clipboard?.isEnabled = clipboardSyncEnabled }
    }
    private var clipboard: ClipboardMonitor?
    private let machine: SessionStateMachine
    private let identity: IdentityStore
    private let config: RCConfig
    private var ticker: Task<Void, Never>?
    private var watchedPeer: String?
    public let role: Wire.Role
    /// HOST only. Owned here because its lifetime is exactly the session's.
    private var frameProducer: (any VideoFrameProducer)?
    private let captureSourceKind: CaptureSourceKind
    private var captureRetry: Task<Void, Never>?
    /// Serialises negotiation so two offers can never be in flight.
    private var negotiating = false
    /// The peer's device key, as this side learned it: the controller learns the
    /// host's from `connect_ok`, the host learns the controller's from the
    /// §2.17 exchange. Every incoming `sdp` must be signed by it.
    public private(set) var expectedPeerPublicKey: String?

    /// The live replacement for `PreviewPresenceSource`. Bind the UI to this.
    public let presence = SignalingPresenceSource()

    /// Called when a session ends in a way that needs the user. The UI binds it.
    public var onAccessCodeRequired: ((String) -> Void)?
    /// Observation stream; see `CoordinatorEvent`.
    public var onEvent: ((CoordinatorEvent) -> Void)?

    private func emit(_ event: CoordinatorEvent) { onEvent?(event) }

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
        // Both roles sync the clipboard; only the controller sends input.
        let clipboard = ClipboardMonitor(engine: ClipboardSyncEngine(originId: identity.deviceID))
        clipboard.onOutgoing = { [weak self] payload in
            guard let self, self.clipboardSyncEnabled else { return }
            guard self.peer?.send(.clipboard(payload)) == true else { return }
            self.emit(.clipboard(incoming: false, bytes: payload.text.utf8.count))
        }
        self.clipboard = clipboard
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

    /// Controller: the user pressed Connect.
    public func connect(deviceID: String, accessCode: String) async throws {
        try await connect(deviceID: deviceID, accessCode: accessCode, remember: false)
    }

    /// Pins the key every incoming `sdp` must be signed by. The host calls this
    /// with the controller key the §2.17 exchange bound into its transcript.
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

    /// Measures the real round-trip over the `ctrl` channel (PROTOCOL.md §5).
    public func sendPing() throws { try peer?.sendPing() }

    /// Sends `display_info`. The host calls this on session start and on any
    /// display change; Phase 4 supplies the real numbers.
    public func sendDisplayInfo(width: Int, height: Int, scale: Double) throws {
        try peer?.sendDisplayInfo(DisplayInfoPayload(w: width, h: height, scale: scale))
    }

    /// Drops the signaling socket without ending the session, so the client
    /// reconnects and resumes. This is a *control-plane* outage by construction:
    /// it exists to prove the peer connection survives one.
    public func dropSignalingSocket() { signaling.simulateSocketLoss() }

    /// Forces an ICE restart. Used by the integration test; in normal operation
    /// the state machine decides when this happens.
    public func forceICERestart() {
        emit(.iceRestartStarted)
        Task { await renegotiate(restart: true) }
    }

    public func disconnect(reason: String) {
        Task { await perform(machine.userEnded(reason: reason)) }
    }

    // MARK: - Action execution

    private func perform(_ actions: [SessionAction]) async {
        for action in actions { await perform(action) }
        syncPhase()
    }

    private func perform(_ action: SessionAction) async {
        switch action {
        case .sendConnectReq(let deviceID, let accessCode):
            do {
                let grant = try await signaling.connectRequest(deviceID: deviceID, accessCode: accessCode)
                expectPeerPublicKey(grant.hostPubkey)
                emit(.sessionGranted(sessionID: grant.sessionId, role: .controller))
                await perform(machine.sessionGranted(grant))
            } catch {
                let failure = ConnectFailure(error)
                lastError = failure.localizedDescription
                emit(.connectFailed(failure))
                await perform(machine.connectFailed(code: failure.code))
                // `busy` against what might be our own orphaned session is
                // recovered with `resume`, never by retrying connect_req
                // (PROTOCOL.md §4.4). We have no session here, so it is genuinely
                // someone else's — surfaced, not retried.
            }

        case .sendResume(let sessionID, let token):
            do {
                let ok = try await signaling.resume(sessionID: sessionID, sessionToken: token)
                emit(.resumed(sessionID: ok.sessionId, peerAttached: ok.peerAttached))
                await perform(machine.resumeSucceeded(ok))
            } catch let error as WireError {
                let code = error.serverCode ?? "network"
                // The server restarted: every session died and `no_session` is
                // the honest answer. A controller that remembers the code
                // reconnects silently; only a controller with no code prompts.
                if (code == Wire.ErrorCode.noSession || code == Wire.ErrorCode.badToken),
                   machine.rememberedAccessCode != nil {
                    emit(.silentReconnect(reason: code))
                }
                await perform(machine.resumeFailed(code: code, retryAfterSec: error.retryAfterSec ?? 0))
            } catch {
                // Socket died mid-resume: not terminal, try again on reconnect.
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
                // Transient; the next tick renews again.
            }

        case .sendInputReset:
            peer?.sendInputReset()
            // And apply one locally. PROTOCOL.md §4.4 says a reset goes out on
            // every resume and every disconnect; if the LINK is what broke, the
            // peer's reset may never arrive, and a Command key held when the
            // network died would stay held on this Mac forever. Idempotent, so
            // doing both sides costs nothing.
            applyLocalInputReset()

        case .startPeerConnection(let offerer):
            startPeer(offerer: offerer)

        case .restartICE:
            emit(.iceRestartStarted)
            await renegotiate(restart: true)

        case .reissueWatches:
            if let watchedPeer { Task { try? await signaling.watch(deviceID: watchedPeer) } }

        case .teardownPeerConnection:
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

    private func startPeer(offerer: Bool) {
        peer?.close()
        // The media direction follows the ROLE, not who offers: the controller
        // offers and receives, which is the pair that is easy to invert.
        let session = PeerSession(iceServers: signaling.iceServers, isOfferer: offerer,
                                  mediaRole: role == .host ? .sendScreen : .receiveScreen,
                                  forceTURNRelay: config.forceTURNRelay)
        session.delegate = self
        peer = session
        do {
            try session.start()
        } catch {
            // Failing here means there is no peer connection at all, and the
            // session simply never progresses. Silence was costing an afternoon.
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

    /// Creates and relays an offer. Guarded so an ICE restart triggered by both
    /// the 3-second timer and a `resume_ok` cannot produce two offers.
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

    /// Every `sdp` this Mac sends goes through here, including an ICE-restart
    /// re-offer, so nothing can leave unsigned: the fingerprints are extracted
    /// by the shared core and signed with the device key, which may be in the
    /// Secure Enclave.
    private func sendSignedSDP(sessionID: String, type: String, sdp: String,
                               restart: Bool) async throws {
        let signable = try SdpAuth.signable(sessionID: sessionID, sdpType: type, sdp: sdp)
        let signature = SdpSignature(
            fingerprints: signable.fingerprints,
            pubkey: identity.publicKeyBase64,
            signature: try identity.signatureBase64(for: signable.message))
        try await signaling.sendSDP(sessionID: sessionID, type: type, sdp: sdp,
                                    restart: restart, signature: signature)
    }

    /// The other Mac could not be proven to be the other Mac. That is not a
    /// network problem and is never retried: `bye`, tear down, say so.
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
            // With no control plane we genuinely do not know; saying "Offline"
            // would be a lie about the peer rather than about ourselves.
            peerPresence = .unknown
        }
    }

    public func signaling(_ client: SignalingClient, didAuthenticate hello: HelloOKPayload) {
        emit(.authenticated(hello))
        Task { await perform(machine.signalingAuthenticated(activeSessionID: hello.activeSessionId)) }
    }

    public func signaling(_ client: SignalingClient, didDisconnect error: Swift.Error?) {
        emit(.signalingDisconnected(reason: error?.localizedDescription ?? "closed"))
        // PROTOCOL.md §4.3 step 1: the peer connection is NOT touched here.
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
            await perform(machine.sessionGranted(grant))

        case Wire.MessageType.peerState:
            // Informational: the other side attached or detached. The ICE state
            // is what decides whether media is up.
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
            await perform(machine.closeLocally(reason: bye.reason))

        case Wire.MessageType.error:
            if let wire = envelope.asProtocolError { lastError = wire.errorDescription }

        default:
            break
        }
    }

    private func handleRemoteSDP(_ sdp: SDPPayload) async {
        guard sdp.sessionId == machine.sessionID else { return }
        guard let signature = sdp.signature else {
            await refusePeer(reason: "the sdp carried no signature")
            return
        }
        do {
            try SdpAuth.verify(sessionID: sdp.sessionId, sdpType: sdp.sdpType, sdp: sdp.sdp,
                               signature: signature, expectedPubkey: expectedPeerPublicKey)
        } catch {
            await refusePeer(reason: error.localizedDescription)
            return
        }
        // The host has no peer connection until the first offer arrives if the
        // session_start push and the offer race; start it lazily.
        if peer == nil { startPeer(offerer: machine.isOfferer) }
        guard let peer else { return }
        do {
            try await peer.setRemoteDescription(type: sdp.sdpType, sdp: sdp.sdp)
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
            // A candidate that cannot be relayed because the peer is detached is
            // dropped by the server on purpose; it is re-gathered after resume.
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
        // The control channel being open is what makes input and clipboard
        // meaningful; before that there is nowhere to send them.
        clipboard?.isEnabled = clipboardSyncEnabled
        clipboard?.start()
        input.isEnabled = (role == .controller)
        switch role {
        case .host:
            // PROTOCOL.md §5: display_info on session start. If capture has not
            // reported a size yet, `captureDidResize` sends it the moment it does.
            if let localDisplay { try? session.sendDisplayInfo(localDisplay) }
        case .controller:
            // The host defaults to `auto`; state the controller's actual choice
            // rather than relying on both sides having the same default.
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
        if envelope.type == CtrlType.sessionClose,
           let close = try? envelope.decodePayload(SessionClosePayload.self) {
            Task { await perform(machine.closeLocally(reason: close.reason)) }
        }
    }

    /// A `mouse_move` off the unreliable channel. `PeerSession` has already
    /// dropped anything stale by `seq`; the injector's own gate is a second
    /// line of defence that also survives a reconnect (PROTOCOL.md §6).
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

    /// HOST: applies one input message as real OS events.
    ///
    /// Guarded by role: a controller that received a `mouse_down` would inject
    /// into ITSELF. The channel is 1:1 and the host never sends input, but the
    /// guard is what makes that a property of the code rather than of the peer's
    /// good behaviour.
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
        // The display can be reconfigured mid-session; re-reading the bounds is
        // cheap and stops the pointer landing on the old geometry.
        injector.target = .mainDisplay
        eventSink.post(events)
        injectedEventCount += events.count
        emit(.inputApplied(type: type, events: events.count))
    }

    /// Releases everything held on THIS Mac. Idempotent (see `InputInjector.reset`).
    internal func applyLocalInputReset() {
        let events = injector.reset()
        // Local only: the wire-level input_reset is the state machine's
        // `.sendInputReset` action, which has just fired. Sending a second one
        // from here would be redundant traffic on every reconnect.
        input.forgetHeldState()
        guard !events.isEmpty else { return }
        eventSink.post(events)
        injectedEventCount += events.count
        emit(.inputApplied(type: CtrlType.inputReset, events: events.count))
    }

    /// Both roles. The echo guard lives in `ClipboardSyncEngine`; this only
    /// routes and reports byte counts.
    internal func applyClipboard(_ envelope: Envelope) {
        guard envelope.type == CtrlType.clipboardText, clipboardSyncEnabled else { return }
        guard let payload = try? envelope.decodePayload(ClipboardTextPayload.self) else { return }
        guard clipboard?.apply(payload) == true else { return }
        emit(.clipboard(incoming: true, bytes: payload.text.utf8.count))
    }

    /// CONTROLLER: the floating palette's one call.
    func sendGesture(_ name: GestureName) {
        guard role == .controller else { return }
        input.gesture(name)
        emit(.gesture(name: name.rawValue))
    }

    /// CONTROLLER: from the capture-keyboard tap, or a test.
    func sendKey(down: Bool, keycode: CGKeyCode, modifiers: KeyModifiers) {
        guard role == .controller else { return }
        input.key(down: down, keycode: keycode, modifiers: modifiers)
    }

    /// CONTROLLER: pointer activity from the remote screen view.
    func sendPointer(_ event: RemotePointerEvent) {
        guard role == .controller else { return }
        input.handle(event)
    }
}

// MARK: - Media (Phase 4)

public extension SessionCoordinator {

    /// The one call the controller UI makes when the quality picker changes.
    /// Also remembered so a later reconnect re-states it.
    func setQuality(_ mode: QualityWireMode) {
        qualityMode = mode
        guard role == .controller else { return }
        try? peer?.sendQuality(mode)
    }

    /// libwebrtc's own counters. `framesDecoded` climbing is the only proof of
    /// live video that a still frame or a stub cannot produce.
    func videoStatistics() async -> VideoStatistics {
        guard let peer else { return VideoStatistics() }
        return await peer.videoStatistics()
    }

    /// The controller's Metal view attaches to this. Kept internal to the media
    /// layer: no libwebrtc type reaches the SwiftUI code.
    internal var remoteTrack: RTCVideoTrack? { peer?.remoteVideoTrack }
}

// MARK: Host capture pipeline

extension SessionCoordinator {

    /// Starts (or restarts) capture for the live session. Idempotent.
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
            self?.peer?.submit(pixelBuffer: pixelBuffer, timeNs: timeNs)
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

    /// PROTOCOL.md §5: `display_info` on session start AND on any display change.
    /// This is the single funnel for both, so a resolution change mid-session
    /// cannot leave the controller letterboxing to a stale size.
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

        // TCC binds the Screen Recording grant to the code signature, and this
        // app is ad-hoc signed, so a rebuild can revoke it and the user has to
        // re-grant mid-session. Poll quietly rather than making them reconnect:
        // the moment the grant comes back, video starts.
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

    /// Applies a quality strategy to the encoder and to the capture stream.
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
