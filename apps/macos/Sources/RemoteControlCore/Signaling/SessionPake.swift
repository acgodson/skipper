import Foundation
import SkipperCore

extension SessionCoordinator {

    static let pakeTimeoutSeconds: UInt64 = 10

    // MARK: - Starting

    func armPake(for grant: SessionGrantPayload) {
        clearPake()
        pakeRequired = true
        pakeControllerPubkey = grant.controllerPubkey
        startPakeTimeout()
    }

    func startControllerPake(grant: SessionGrantPayload, accessCode: String) async {
        guard role == .controller else { return }
        do {
            let exchange = try PakeExchange.controller(
                accessCode: accessCode,
                deviceID: grant.hostDeviceId,
                sessionID: grant.sessionId,
                ownPublicKey: identity.publicKeyBase64)
            pakeExchange = exchange
            guard let step1 = try exchange.step(nil) else {
                await pakeFailed(reason: "the exchange produced no opening message", authentication: false)
                return
            }
            try await send(step1, sessionID: grant.sessionId)
        } catch {
            await pakeFailed(reason: error.localizedDescription, authentication: false)
        }
    }

    func startHostPake(grant: SessionGrantPayload) async {
        guard role == .host else { return }
        let controllerPubkey = grant.controllerPubkey ?? ""
        guard !controllerPubkey.isEmpty else {
            await pakeFailed(reason: "session_start carried no controller key", authentication: true)
            return
        }
        do {
            let counter = try identity.secrets.guessCounter(forController: controllerPubkey)
            let decision = try GuessPolicy.check(counter)
            guard decision.isAllowed else {
                let seconds = Int((decision.retryAfter).rounded(.up))
                await pakeFailed(reason: "this controller is locked out for another \(seconds)s",
                                 authentication: true)
                return
            }
            pakeExchange = try PakeExchange.host(
                accessCode: identity.accessCode,
                deviceID: grant.hostDeviceId,
                sessionID: grant.sessionId,
                ownPublicKey: identity.publicKeyBase64)
        } catch {
            await pakeFailed(reason: error.localizedDescription, authentication: true)
        }
    }

    // MARK: - Running

    func handlePake(_ frame: PakePayload) async {
        guard frame.sessionId == machine.sessionID, let exchange = pakeExchange else { return }
        guard !pakeComplete else { return }
        startPakeTimeout()
        emit(.pake(step: frame.step, outgoing: false))
        do {
            let outgoing = try exchange.step(frame.message)
            if let outgoing {
                try await send(outgoing, sessionID: frame.sessionId)
            }
        } catch {
            await pakeFailed(reason: error.localizedDescription, authentication: true)
            return
        }
        if exchange.isComplete { await pakeSucceeded(exchange) }
    }

    private func send(_ message: PakeMessage, sessionID: String) async throws {
        try await signaling.sendPake(sessionID: sessionID, message: message)
        emit(.pake(step: message.step, outgoing: true))
    }

    // MARK: - Ending

    private func pakeSucceeded(_ exchange: PakeExchange) async {
        guard let peerPubkey = exchange.peerPublicKey, !peerPubkey.isEmpty else {
            await pakeFailed(reason: "the exchange completed without a peer key", authentication: true)
            return
        }
        if role == .controller, let pinned = expectedPeerPublicKey, pinned != peerPubkey {
            await refusePeerFromPake(reason: "the host key in the exchange is not the one connect_ok named")
            return
        }
        if role == .host, let announced = pakeControllerPubkey, announced != peerPubkey {
            await pakeFailed(reason: "the controller key in step 1 is not the one session_start named",
                             authentication: true)
            return
        }

        cancelPakeTimeout()
        pakeComplete = true
        expectPeerPublicKey(peerPubkey)
        emit(.pakeCompleted(peerPubkey: peerPubkey))
        recordPakeSuccess(peerPubkey: peerPubkey)

        if let offerer = deferredPeerStart {
            deferredPeerStart = nil
            startPeerAfterPake(offerer: offerer)
        }
    }

    private func recordPakeSuccess(peerPubkey: String) {
        switch role {
        case .host:
            let cleared = try? GuessPolicy.recordSuccess(
                try identity.secrets.guessCounter(forController: peerPubkey))
            if let cleared {
                try? identity.secrets.saveGuessCounter(cleared.counter, forController: peerPubkey)
            }
            try? identity.secrets.recordTrustedController(
                pubkey: peerPubkey, label: machine.peerDeviceID.map(DeviceID.formatted) ?? "")
        case .controller:
            guard let code = machine.rememberedAccessCode, let host = machine.peerDeviceID else { return }
            try? identity.secrets.rememberPeerCode(code, forHost: host)
        }
    }

    func pakeFailed(reason: String, authentication: Bool) async {
        guard pakeRequired, !pakeComplete else { return }
        cancelPakeTimeout()
        RCLog.error("access-code exchange failed: \(reason)")
        emit(.pakeFailed(reason: reason, authentication: authentication))
        if role == .host { recordPakeFailure() }
        if role == .controller {
            lastError = SessionCoordinator.wrongAccessCodeMessage
            emit(.connectFailed(.authFailed))
            forgetRememberedPeerCode()
        }
        let byeReason = authentication ? Wire.ByeReason.authFailed : Wire.ByeReason.failed
        await perform(machine.userEnded(reason: byeReason))
    }

    private func recordPakeFailure() {
        guard let pubkey = pakeControllerPubkey, !pubkey.isEmpty else { return }
        guard let decision = try? GuessPolicy.recordFailure(
            try identity.secrets.guessCounter(forController: pubkey)) else { return }
        try? identity.secrets.saveGuessCounter(decision.counter, forController: pubkey)
    }

    func peerEndedExchange(byeReason: String) {
        guard pakeRequired, !pakeComplete else { return }
        cancelPakeTimeout()
        let authentication = byeReason == Wire.ByeReason.authFailed
        emit(.pakeFailed(reason: "the peer ended the exchange (\(byeReason))",
                         authentication: authentication))
        switch role {
        case .host:
            recordPakeFailure()
        case .controller:
            guard authentication else { return }
            lastError = SessionCoordinator.wrongAccessCodeMessage
            emit(.connectFailed(.authFailed))
            forgetRememberedPeerCode()
        }
    }

    private func forgetRememberedPeerCode() {
        guard let host = machine.peerDeviceID else { return }
        try? identity.secrets.forgetPeerCode(forHost: host)
        machine.rememberedAccessCode = nil
    }

    // MARK: - Bookkeeping

    func clearPake() {
        cancelPakeTimeout()
        pakeExchange = nil
        pakeComplete = false
        pakeRequired = false
        deferredPeerStart = nil
        pakeControllerPubkey = nil
    }

    private func startPakeTimeout() {
        cancelPakeTimeout()
        pakeTimeout = Task { [weak self] in
            try? await Task.sleep(nanoseconds: SessionCoordinator.pakeTimeoutSeconds * 1_000_000_000)
            guard !Task.isCancelled, let self else { return }
            await self.pakeFailed(reason: "the access-code exchange timed out", authentication: false)
        }
    }

    private func cancelPakeTimeout() {
        pakeTimeout?.cancel()
        pakeTimeout = nil
    }

    public static let wrongAccessCodeMessage = "Wrong access code."
}
