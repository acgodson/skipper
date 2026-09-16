import Foundation

public enum SignalingState: Equatable {
    case idle
    /// TCP + TLS + WebSocket upgrade in progress.
    case connecting
    /// Socket is up; `challenge` → `register`/`hello` in progress.
    case authenticating
    case authenticated(deviceID: String)
    /// Waiting out the reconnect backoff. The associated value is the delay.
    case waitingToRetry(TimeInterval)
    /// Terminal. Either `stop()` was called or the server said `displaced`.
    case stopped(String)

    public var isAuthenticated: Bool {
        if case .authenticated = self { return true }
        return false
    }
}

public enum SignalingError: Swift.Error, LocalizedError {
    case notConnected
    case timedOut(String)
    case handshakeFailed(String)
    case socketClosed(String)
    case certificatePinRejected(String)

    public var errorDescription: String? {
        switch self {
        case .notConnected: return "Not connected to the signaling server."
        case .timedOut(let what): return "Timed out waiting for \(what)."
        case .handshakeFailed(let why): return "Signaling handshake failed: \(why)"
        case .socketClosed(let why): return "The signaling connection closed: \(why)"
        case .certificatePinRejected(let why): return why
        }
    }
}

@MainActor
public protocol SignalingClientDelegate: AnyObject {
    /// `hello_ok` has arrived. `activeSessionId` being present is the server
    /// telling us to `resume`, never `connect_req` (PROTOCOL.md §4.3).
    func signaling(_ client: SignalingClient, didAuthenticate hello: HelloOKPayload)
    /// The control plane went away. **Do not tear down the peer connection here**
    /// (PROTOCOL.md §4.3 step 1) — media over an established path is unaffected.
    func signaling(_ client: SignalingClient, didDisconnect error: Error?)
    /// Unsolicited server pushes: `presence`, `session_start`, `peer_state`,
    /// `sdp`, `ice`, `bye`, and unsolicited `error`s.
    func signaling(_ client: SignalingClient, didReceive envelope: Envelope)
    func signaling(_ client: SignalingClient, didChangeState state: SignalingState)
}

public extension SignalingClientDelegate {
    func signaling(_ client: SignalingClient, didChangeState state: SignalingState) {}
}

/// The WebSocket client for `rc-signal`.
///
/// Owns: the socket, TLS pinning, the challenge/response handshake, the
/// heartbeat, request/reply correlation, and the reconnect schedule. It owns
/// **no** session policy — that is `SessionCoordinator`'s job, because the rules
/// in PROTOCOL.md §4 are about the session outliving this object's socket.
@MainActor
public final class SignalingClient {

    // MARK: State

    public private(set) var state: SignalingState = .idle {
        didSet {
            guard state != oldValue else { return }
            delegate?.signaling(self, didChangeState: state)
        }
    }
    public weak var delegate: SignalingClientDelegate?

    public private(set) var lastHelloOK: HelloOKPayload?
    /// ICE servers from the most recent `hello_ok`. TURN credentials are minted
    /// per hello and are never hardcoded (PROTOCOL.md §2.5).
    public var iceServers: [ICEServerSpec] { lastHelloOK?.iceServers ?? [] }
    public private(set) var lastPinOutcome: CertificatePinner.Outcome = .notPinned
    /// Device IDs we have asked the server to push presence for. Re-issued on
    /// every reconnect, because watches are per-connection (PROTOCOL.md §2.7).
    public private(set) var watchedDeviceIDs: Set<String> = []

    public let config: RCConfig
    private let identity: IdentityStore
    private var role: Wire.Role

    private var socket: URLSessionWebSocketTask?
    private var urlSession: URLSession?
    private var supervisor: Task<Void, Never>?
    private var backoff: ReconnectBackoff
    private var messageCounter = 0

    // MARK: Waiters

    private struct Waiter {
        let token: Int
        let re: String?
        let types: Set<String>
        let continuation: CheckedContinuation<Envelope, Swift.Error>
    }
    private var waiters: [Waiter] = []
    private var waiterCounter = 0
    private var connectionEnd: CheckedContinuation<Void, Swift.Error>?

    public init(config: RCConfig = .current, identity: IdentityStore, role: Wire.Role) {
        self.config = config
        self.identity = identity
        self.role = role
        self.backoff = ReconnectBackoff(minimum: config.backoffMinimum, maximum: config.backoffMaximum)
    }

    // MARK: - Lifecycle

    /// Starts connecting and keeps the socket up for as long as the process
    /// lives, retrying with jittered exponential backoff, indefinitely.
    public func start() {
        guard supervisor == nil else { return }
        supervisor = Task { [weak self] in await self?.supervise() }
    }

    public func stop(reason: String = "stopped by the app") {
        supervisor?.cancel()
        supervisor = nil
        closeSocket()
        state = .stopped(reason)
    }

    public func setRole(_ newRole: Wire.Role) { role = newRole }

    private func supervise() async {
        while !Task.isCancelled {
            do {
                try await runOneConnection()
                // A clean return means the socket closed without an error.
                throw SignalingError.socketClosed("the server closed the connection")
            } catch is CancellationError {
                return
            } catch {
                RCLog.debug("connection ended: \(error)")
                if case .stopped = state { return }
                failAllWaiters(with: error)
                delegate?.signaling(self, didDisconnect: error)

                // `displaced` means another instance authenticated as this
                // device. PROTOCOL.md §7 is explicit: do not reconnect in a
                // loop, the other instance won.
                if (error as? WireError)?.serverCode == Wire.ErrorCode.displaced {
                    state = .stopped("another instance of RemoteControl took over this Device ID")
                    return
                }
                if (error as? SignalingError)?.isPinRejection == true {
                    // Retrying a pin failure hammers a server we have already
                    // decided we cannot trust, but the address may be a
                    // temporary misconfiguration, so we keep trying slowly.
                    lastPinOutcome = .rejectedNoCertificate
                }

                let delay = backoff.next()
                state = .waitingToRetry(delay)
                do {
                    try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                } catch {
                    return
                }
            }
        }
    }

    /// One socket, from dial to death. Returns only when the socket is gone.
    ///
    /// NOTE ON STRUCTURE: the receive loop is deliberately NOT a child of a task
    /// group. `URLSessionWebSocketTask.receive()` does not observe Swift
    /// concurrency cancellation, so a task group would block forever draining it
    /// after any other child failed — which is exactly what happened the first
    /// time this was written, and it turned a rejected certificate pin into a
    /// permanent hang instead of a reconnect. The two workers therefore report
    /// through a single continuation that resolves on the first failure, and the
    /// socket is cancelled from `defer` so `receive()` unblocks on its own.
    private func runOneConnection() async throws {
        state = .connecting

        let pinner = CertificatePinner(expectedPinBase64: config.certificatePinBase64)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = config.handshakeTimeout
        configuration.waitsForConnectivity = false
        let session = URLSession(configuration: configuration, delegate: pinner, delegateQueue: nil)
        let task = session.webSocketTask(with: config.signalingURL)
        task.maximumMessageSize = 256 * 1024   // PROTOCOL.md §0: max frame 256 KiB
        // Fail a bad pin in milliseconds rather than waiting out the handshake
        // timeout. This runs on the URLSession delegate queue, so it captures the
        // task and never touches main-actor state.
        pinner.onDecision = { [weak self, weak task] outcome in
            RCLog.debug("tls pin decision: \(outcome)")
            guard !outcome.isAcceptable else { return }
            task?.cancel(with: .tlsHandshakeFailure, reason: nil)
            // Cancelling the task does NOT unblock a pending
            // URLSessionWebSocketTask.receive(), so the connection is ended
            // explicitly. Without this a bad pin costs a full handshake timeout
            // before the first retry.
            let outcomeText = outcome.explanation
            let client = self          // immutable, so the inner Task can capture it
            Task { @MainActor in
                client?.endConnection(SignalingError.certificatePinRejected(outcomeText))
            }
        }
        self.urlSession = session
        self.socket = task
        task.resume()

        let receiver = Task { @MainActor [weak self] in
            guard let self else { return }
            do { try await self.receiveLoop(task) }
            catch { self.endConnection(error) }
        }
        let worker = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await self.handshake(on: task)
                self.backoff.reset()
                try await self.heartbeatLoop(on: task)
            } catch {
                self.endConnection(error)
            }
        }

        defer {
            lastPinOutcome = pinner.lastOutcome
            worker.cancel()
            receiver.cancel()
            if self.socket === task {
                self.socket = nil
                self.urlSession = nil
            }
            task.cancel(with: .goingAway, reason: nil)
            session.invalidateAndCancel()
            connectionEnd = nil
            failAllWaiters(with: SignalingError.socketClosed("socket torn down"))
        }

        do {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Swift.Error>) in
                connectionEnd = continuation
            }
        } catch {
            // A pin rejection surfaces from URLSession as a generic cancellation
            // or timeout; the pinner knows the real reason, so say that instead.
            if !pinner.lastOutcome.isAcceptable {
                throw SignalingError.certificatePinRejected(pinner.lastOutcome.explanation)
            }
            throw error
        }
    }

    /// Resolves `runOneConnection`'s wait exactly once.
    private func endConnection(_ error: Swift.Error) {
        guard let continuation = connectionEnd else { return }
        connectionEnd = nil
        continuation.resume(throwing: error)
    }

    private func closeSocket() {
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil
        urlSession?.invalidateAndCancel()
        urlSession = nil
        failAllWaiters(with: SignalingError.socketClosed("closed locally"))
    }

    /// Drops the socket without stopping the supervisor, so the client
    /// reconnects and (per §4.3) resumes. Used by the flutter tests to simulate
    /// a control-plane outage, and by nothing in the shipping UI.
    public func simulateSocketLoss() {
        socket?.cancel(with: .abnormalClosure, reason: nil)
    }

    // MARK: - Handshake (PROTOCOL.md §1.1)

    private func handshake(on task: URLSessionWebSocketTask) async throws {
        state = .authenticating

        var challenge = try await expect(types: [Wire.MessageType.challenge],
                                         timeout: config.handshakeTimeout,
                                         what: "challenge")
            .decodePayload(ChallengePayload.self)

        if !identity.isServerRegistered {
            let registered = try await register(nonce: challenge.nonce, on: task)
            try identity.adoptServerAssignedDeviceID(registered.deviceId)
            identity.markServerRegistered()
            // After register_ok the connection is still CHALLENGED and the server
            // issues a fresh nonce. Each nonce is single-use.
            challenge = try await expect(types: [Wire.MessageType.challenge],
                                         timeout: config.handshakeTimeout,
                                         what: "the post-registration challenge")
                .decodePayload(ChallengePayload.self)
        }

        let hello = HelloPayload(
            deviceId: identity.deviceID,
            pubkey: identity.publicKeyBase64,
            sig: try signature(overNonce: challenge.nonce),
            role: role.rawValue)
        let reply = try await request(type: Wire.MessageType.hello, payload: hello,
                                      expect: [Wire.MessageType.helloOK],
                                      timeout: config.handshakeTimeout)
        let ok = try reply.decodePayload(HelloOKPayload.self)
        lastHelloOK = ok
        state = .authenticated(deviceID: ok.deviceId)

        // Watches are per-connection and are not restored by the server.
        for deviceID in watchedDeviceIDs {
            try? await sendFireAndForget(type: Wire.MessageType.watch,
                                        payload: DeviceIDPayload(deviceId: deviceID))
        }

        delegate?.signaling(self, didAuthenticate: ok)
    }

    private func register(nonce: String, on task: URLSessionWebSocketTask) async throws -> RegisterOKPayload {
        let verifier = try CodeVerifier.make(for: identity.accessCode)
        let payload = RegisterPayload(
            pubkey: identity.publicKeyBase64,
            sig: try signature(overNonce: nonce),
            label: config.deviceLabel,
            code: verifier)
        let reply = try await request(type: Wire.MessageType.register, payload: payload,
                                      expect: [Wire.MessageType.registerOK],
                                      timeout: config.handshakeTimeout)
        return try reply.decodePayload(RegisterOKPayload.self)
    }

    /// ECDSA-P256/SHA-256 over the **raw nonce bytes**, DER, base64
    /// (PROTOCOL.md §3.1). Signing the base64 text instead is the classic way to
    /// get an unexplainable `bad_signature`.
    private func signature(overNonce nonceBase64: String) throws -> String {
        guard let nonce = Data(base64Encoded: nonceBase64) else {
            throw SignalingError.handshakeFailed("the server's nonce was not base64")
        }
        return try identity.signatureBase64(for: nonce)
    }

    private func heartbeatLoop(on task: URLSessionWebSocketTask) async throws {
        let interval = TimeInterval(lastHelloOK?.heartbeatSec ?? Int(config.heartbeatInterval))
        while !Task.isCancelled {
            try await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
            try await sendFireAndForget(type: Wire.MessageType.heartbeat, payload: EmptyPayload())
        }
    }

    // MARK: - Receiving

    private func receiveLoop(_ task: URLSessionWebSocketTask) async throws {
        while !Task.isCancelled {
            let message: URLSessionWebSocketTask.Message
            do {
                message = try await task.receive()
            } catch {
                RCLog.debug("receive failed: \(error)")
                throw error
            }
            switch message {
            case .string(let text):
                route(Data(text.utf8))
            case .data(let data):
                // PROTOCOL.md §0: binary frames are a protocol error. Decode it
                // anyway rather than dropping the connection over pedantry, but
                // never treat it as normal.
                route(data)
            @unknown default:
                break
            }
        }
        throw CancellationError()
    }

    private func route(_ data: Data) {
        let envelope: Envelope
        do {
            envelope = try Envelope.decode(data)
        } catch {
            // An undecodable frame is the server's bug, not a reason to drop a
            // live session. Log-free by design: the frame may contain secrets.
            return
        }

        // 1. A reply to something we asked for.
        if let index = matchingWaiterIndex(for: envelope) {
            let waiter = waiters.remove(at: index)
            if let protocolError = envelope.asProtocolError {
                waiter.continuation.resume(throwing: protocolError)
            } else {
                waiter.continuation.resume(returning: envelope)
            }
            return
        }

        // 2. `displaced` is fatal for this socket and must not look like a push.
        if let protocolError = envelope.asProtocolError,
           protocolError.serverCode == Wire.ErrorCode.displaced {
            delegate?.signaling(self, didReceive: envelope)
            socket?.cancel(with: .normalClosure, reason: nil)
            return
        }

        // 3. Everything else is an unsolicited push for the coordinator.
        delegate?.signaling(self, didReceive: envelope)
    }

    private func matchingWaiterIndex(for envelope: Envelope) -> Int? {
        if let re = envelope.re, !re.isEmpty {
            return waiters.firstIndex { $0.re == re }
        }
        // No correlation id: match on type. `challenge` is the only reply the
        // server sends unsolicited, so this is unambiguous in practice.
        return waiters.firstIndex { $0.re == nil && $0.types.contains(envelope.type) }
    }

    private func failAllWaiters(with error: Swift.Error) {
        let pending = waiters
        waiters.removeAll()
        for waiter in pending { waiter.continuation.resume(throwing: error) }
    }

    // MARK: - Sending

    private func nextMessageID() -> String {
        messageCounter += 1
        return "c-\(messageCounter)"
    }

    private func write(_ data: Data) async throws {
        guard let socket else { throw SignalingError.notConnected }
        // One message per WebSocket TEXT frame (PROTOCOL.md §0).
        try await socket.send(.string(String(decoding: data, as: UTF8.self)))
    }

    public func sendFireAndForget<T: Encodable>(type: String, payload: T) async throws {
        try await write(Envelope.encode(type: type, id: nextMessageID(), payload: payload))
    }

    /// Sends a request and waits for one of `expect`, or the matching `error`.
    @discardableResult
    public func request<T: Encodable>(
        type: String, payload: T, expect: [String], timeout: TimeInterval? = nil
    ) async throws -> Envelope {
        guard socket != nil else { throw SignalingError.notConnected }
        let id = nextMessageID()
        let data = try Envelope.encode(type: type, id: id, payload: payload)
        async let reply = wait(re: id, types: Set(expect + [Wire.MessageType.error]),
                               timeout: timeout ?? config.requestTimeout, what: type)
        try await write(data)
        return try await reply
    }

    /// Waits for an unsolicited frame of one of the given types.
    private func expect(types: Set<String>, timeout: TimeInterval, what: String) async throws -> Envelope {
        try await wait(re: nil, types: types, timeout: timeout, what: what)
    }

    private func wait(re: String?, types: Set<String>, timeout: TimeInterval, what: String) async throws -> Envelope {
        waiterCounter += 1
        let token = waiterCounter

        let timeoutTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await self?.timeOutWaiter(token: token, what: what)
        }
        defer { timeoutTask.cancel() }

        return try await withCheckedThrowingContinuation { continuation in
            waiters.append(Waiter(token: token, re: re, types: types, continuation: continuation))
        }
    }

    private func timeOutWaiter(token: Int, what: String) {
        RCLog.debug("waiter timeout fired for \(what)")
        guard let index = waiters.firstIndex(where: { $0.token == token }) else { return }
        let waiter = waiters.remove(at: index)
        waiter.continuation.resume(throwing: SignalingError.timedOut(what))
    }

    // MARK: - Protocol operations (PROTOCOL.md §2)

    public func watch(deviceID: String) async throws {
        guard let canonical = DeviceID.canonicalize(deviceID) else { return }
        watchedDeviceIDs.insert(canonical)
        guard state.isAuthenticated else { return }
        try await request(type: Wire.MessageType.watch,
                          payload: DeviceIDPayload(deviceId: canonical),
                          expect: [Wire.MessageType.watchOK])
    }

    public func unwatch(deviceID: String) async throws {
        guard let canonical = DeviceID.canonicalize(deviceID) else { return }
        watchedDeviceIDs.remove(canonical)
        guard state.isAuthenticated else { return }
        try await request(type: Wire.MessageType.unwatch,
                          payload: DeviceIDPayload(deviceId: canonical),
                          expect: [Wire.MessageType.unwatchOK])
    }

    public func connectRequest(deviceID: String, accessCode: String) async throws -> SessionGrantPayload {
        let reply = try await request(
            type: Wire.MessageType.connectReq,
            payload: ConnectReqPayload(deviceId: deviceID, accessCode: accessCode),
            expect: [Wire.MessageType.connectOK])
        return try reply.decodePayload(SessionGrantPayload.self)
    }

    public func resume(sessionID: String, sessionToken: String) async throws -> ResumeOKPayload {
        let reply = try await request(
            type: Wire.MessageType.resume,
            payload: ResumePayload(sessionId: sessionID, sessionToken: sessionToken),
            expect: [Wire.MessageType.resumeOK])
        return try reply.decodePayload(ResumeOKPayload.self)
    }

    public func renew(sessionID: String, sessionToken: String) async throws -> RenewOKPayload {
        let reply = try await request(
            type: Wire.MessageType.renew,
            payload: ResumePayload(sessionId: sessionID, sessionToken: sessionToken),
            expect: [Wire.MessageType.renewOK])
        return try reply.decodePayload(RenewOKPayload.self)
    }

    public func sendSDP(sessionID: String, type: String, sdp: String, restart: Bool) async throws {
        try await sendFireAndForget(
            type: Wire.MessageType.sdp,
            payload: SDPPayload(sessionId: sessionID, sdpType: type, sdp: sdp, restart: restart ? true : nil))
    }

    public func sendICE(sessionID: String, candidate: String, sdpMid: String?, sdpMLineIndex: Int?) async throws {
        try await sendFireAndForget(
            type: Wire.MessageType.ice,
            payload: ICEPayload(sessionId: sessionID, candidate: candidate,
                                sdpMid: sdpMid, sdpMLineIndex: sdpMLineIndex))
    }

    public func sendBye(sessionID: String, reason: String) async throws {
        try await sendFireAndForget(type: Wire.MessageType.bye,
                                    payload: ByePayload(sessionId: sessionID, reason: reason))
    }

    /// PROTOCOL.md §2.15. Replaces the verifier for THIS device and kills its
    /// sessions and tokens server-side.
    public func refreshCode(to newPlaintextCode: String) async throws {
        let verifier = try CodeVerifier.make(for: newPlaintextCode)
        try await request(type: Wire.MessageType.refreshCode, payload: verifier,
                          expect: [Wire.MessageType.refreshCodeOK])
    }
}

// MARK: - AccessCodeSink

/// Wiring the real server into the Phase 2 seam: refreshing the access code
/// locally now propagates, and the old code stops working off-machine too.
extension SignalingClient: AccessCodeSink {
    public nonisolated func accessCodeDidChange(deviceID: String, newCode: String) async throws {
        try await refreshCode(to: newCode)
    }
}

private extension SignalingError {
    var isPinRejection: Bool {
        if case .certificatePinRejected = self { return true }
        return false
    }
}
