import Foundation

public enum SignalingState: Equatable {
    case idle
    case connecting
    case authenticating
    case authenticated(deviceID: String)
    case waitingToRetry(TimeInterval)
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

    public var errorDescription: String? {
        switch self {
        case .notConnected: return "Not connected to the signaling server."
        case .timedOut(let what): return "Timed out waiting for \(what)."
        case .handshakeFailed(let why): return "Signaling handshake failed: \(why)"
        case .socketClosed(let why): return "The signaling connection closed: \(why)"
        }
    }
}

@MainActor
public protocol SignalingClientDelegate: AnyObject {
    func signaling(_ client: SignalingClient, didAuthenticate hello: HelloOKPayload)
    func signaling(_ client: SignalingClient, didDisconnect error: Error?)
    func signaling(_ client: SignalingClient, didReceive envelope: Envelope)
    func signaling(_ client: SignalingClient, didChangeState state: SignalingState)
}

public extension SignalingClientDelegate {
    func signaling(_ client: SignalingClient, didChangeState state: SignalingState) {}
}

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
    public var iceServers: [ICEServerSpec] { lastHelloOK?.iceServers ?? [] }
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
    private var unclaimedChallenge: Envelope?
    private var connectionEnd: CheckedContinuation<Void, Swift.Error>?

    public init(config: RCConfig = .current, identity: IdentityStore, role: Wire.Role) {
        self.config = config
        self.identity = identity
        self.role = role
        self.backoff = ReconnectBackoff(minimum: config.backoffMinimum, maximum: config.backoffMaximum)
    }

    // MARK: - Lifecycle

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
                throw SignalingError.socketClosed("the server closed the connection")
            } catch is CancellationError {
                return
            } catch {
                RCLog.debug("connection ended: \(error)")
                if case .stopped = state { return }
                failAllWaiters(with: error)
                delegate?.signaling(self, didDisconnect: error)

                if (error as? WireError)?.serverCode == Wire.ErrorCode.displaced {
                    state = .stopped("another instance of RemoteControl took over this Device ID")
                    return
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

    private func runOneConnection() async throws {
        state = .connecting

        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = config.handshakeTimeout
        configuration.waitsForConnectivity = false
        let session = URLSession(configuration: configuration)
        let task = session.webSocketTask(with: config.signalingURL)
        // Frame cap must match the protocol's own limit or the two sides disagree on what fits in one message.
        task.maximumMessageSize = 256 * 1024
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

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Swift.Error>) in
            connectionEnd = continuation
        }
    }

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

    public func simulateSocketLoss() {
        socket?.cancel(with: .abnormalClosure, reason: nil)
    }

    // MARK: - Handshake (PROTOCOL.md §1.1)

    private func handshake(on task: URLSessionWebSocketTask) async throws {
        state = .authenticating
        unclaimedChallenge = nil

        var nonce = try await nextChallengeNonce(what: "challenge")
        if !identity.isServerRegistered {
            nonce = try await register(nonce: nonce, preferredDeviceID: nil)
        }

        let ok: HelloOKPayload
        do {
            ok = try await hello(nonce: nonce)
        } catch let error as WireError where error.serverCode == Wire.ErrorCode.unknownDevice {
            RCLog.info("the server has no record of this Device ID; registering again with the same key")
            let retryNonce = try await nextChallengeNonce(what: "the challenge after unknown_device")
            let registeredNonce = try await register(nonce: retryNonce, preferredDeviceID: identity.deviceID)
            ok = try await hello(nonce: registeredNonce)
        }
        lastHelloOK = ok
        state = .authenticated(deviceID: ok.deviceId)

        for deviceID in watchedDeviceIDs {
            try? await sendFireAndForget(type: Wire.MessageType.watch,
                                        payload: DeviceIDPayload(deviceId: deviceID))
        }

        delegate?.signaling(self, didAuthenticate: ok)
    }

    private func nextChallengeNonce(what: String) async throws -> String {
        try await expect(types: [Wire.MessageType.challenge], timeout: config.handshakeTimeout, what: what)
            .decodePayload(ChallengePayload.self).nonce
    }

    private func hello(nonce: String) async throws -> HelloOKPayload {
        let hello = HelloPayload(
            deviceId: identity.deviceID,
            pubkey: identity.publicKeyBase64,
            sig: try signature(.hello, overNonce: nonce),
            role: role.rawValue)
        let reply = try await request(type: Wire.MessageType.hello, payload: hello,
                                      expect: [Wire.MessageType.helloOK],
                                      timeout: config.handshakeTimeout)
        return try reply.decodePayload(HelloOKPayload.self)
    }

    private func register(nonce: String, preferredDeviceID: String?) async throws -> String {
        let payload = RegisterPayload(
            pubkey: identity.publicKeyBase64,
            sig: try signature(.register, overNonce: nonce),
            label: config.deviceLabel,
            preferredDeviceId: preferredDeviceID)
        let reply = try await request(type: Wire.MessageType.register, payload: payload,
                                      expect: [Wire.MessageType.registerOK],
                                      timeout: config.handshakeTimeout)
        let registered = try reply.decodePayload(RegisterOKPayload.self)
        if let preferredDeviceID {
            try identity.adoptReassignedDeviceID(registered.deviceId, previous: preferredDeviceID)
        } else {
            try identity.adoptServerAssignedDeviceID(registered.deviceId)
        }
        identity.markServerRegistered()
        return try await nextChallengeNonce(what: "the post-registration challenge")
    }

    private func signature(_ purpose: SigningPurpose, overNonce nonceBase64: String) throws -> String {
        guard let nonce = Data(base64Encoded: nonceBase64) else {
            throw SignalingError.handshakeFailed("the server's nonce was not base64")
        }
        do {
            return try identity.signatureBase64(purpose: purpose, nonce: nonce)
        } catch let refused as SkipperCoreError {
            throw SignalingError.handshakeFailed("the server's challenge was refused: \(refused.message)")
        }
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
            return
        }

        if let index = matchingWaiterIndex(for: envelope) {
            let waiter = waiters.remove(at: index)
            if let protocolError = envelope.asProtocolError {
                waiter.continuation.resume(throwing: protocolError)
            } else {
                waiter.continuation.resume(returning: envelope)
            }
            return
        }

        if envelope.type == Wire.MessageType.challenge {
            unclaimedChallenge = envelope
            return
        }

        if let protocolError = envelope.asProtocolError,
           protocolError.serverCode == Wire.ErrorCode.displaced {
            delegate?.signaling(self, didReceive: envelope)
            socket?.cancel(with: .normalClosure, reason: nil)
            return
        }

        delegate?.signaling(self, didReceive: envelope)
    }

    private func matchingWaiterIndex(for envelope: Envelope) -> Int? {
        if let re = envelope.re, !re.isEmpty {
            return waiters.firstIndex { $0.re == re }
        }
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
        try await socket.send(.string(String(decoding: data, as: UTF8.self)))
    }

    public func sendFireAndForget<T: Encodable>(type: String, payload: T) async throws {
        try await write(Envelope.encode(type: type, id: nextMessageID(), payload: payload))
    }

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

    private func expect(types: Set<String>, timeout: TimeInterval, what: String) async throws -> Envelope {
        if let pending = unclaimedChallenge, types.contains(pending.type) {
            unclaimedChallenge = nil
            return pending
        }
        return try await wait(re: nil, types: types, timeout: timeout, what: what)
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

    public func connectRequest(deviceID: String) async throws -> SessionGrantPayload {
        let reply = try await request(
            type: Wire.MessageType.connectReq,
            payload: ConnectReqPayload(deviceId: deviceID),
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

    public func sendSDP(sessionID: String, type: String, sdp: String, restart: Bool,
                        signature: SdpSignature?) async throws {
        try await sendFireAndForget(
            type: Wire.MessageType.sdp,
            payload: SDPPayload(sessionId: sessionID, sdpType: type, sdp: sdp,
                                restart: restart ? true : nil,
                                fp: signature?.fingerprints,
                                pubkey: signature?.pubkey,
                                sig: signature?.signature,
                                mac: signature?.mac))
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

    public func sendPake(sessionID: String, message: PakeMessage) async throws {
        try await sendFireAndForget(type: Wire.MessageType.pake,
                                    payload: PakePayload(sessionId: sessionID, message: message))
    }

    public func refreshCode() async throws {
        try await request(type: Wire.MessageType.refreshCode, payload: EmptyPayload(),
                          expect: [Wire.MessageType.refreshCodeOK])
    }
}

// MARK: - AccessCodeSink

extension IdentityStore: DeviceMessageSigner {}

extension SignalingClient: AccessCodeSink {
    public nonisolated func accessCodeDidChange(deviceID: String) async throws {
        try await refreshCode()
    }
}
