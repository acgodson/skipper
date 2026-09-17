import Foundation
import SkipperCore

private struct PakeRefusal: Error, LocalizedError {
    let reason: String
    var errorDescription: String? { reason }
}

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
        guard !controllerPubkey.isEmpty, controllerPubkey != GuessLedger.hostKey else {
            await pakeFailed(reason: "session_start carried no usable controller key", authentication: true)
            return
        }
        do {
            try requireAdmitted(try guessLedger(for: controllerPubkey))
            pakeExchange = try PakeExchange.host(
                accessCode: identity.accessCode,
                deviceID: grant.hostDeviceId,
                sessionID: grant.sessionId,
                ownPublicKey: identity.publicKeyBase64)
        } catch {
            await pakeFailed(reason: error.localizedDescription,
                             authentication: Self.isAuthenticationFailure(error))
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
                if role == .host { try recordHostReply(exchange) }
                try await send(outgoing, sessionID: frame.sessionId)
            }
        } catch {
            await pakeFailed(reason: error.localizedDescription,
                             authentication: Self.isAuthenticationFailure(error))
            return
        }
        if exchange.isComplete { await pakeSucceeded(exchange) }
    }

    private func send(_ message: PakeMessage, sessionID: String) async throws {
        try await signaling.sendPake(sessionID: sessionID, message: message)
        emit(.pake(step: message.step, outgoing: true))
    }

    /// Step 2 carries the host's confirmation, which lets whoever sent step 1
    /// check one guess offline; the guess is paid for before it leaves.
    private func recordHostReply(_ exchange: PakeExchange) throws {
        guard let announced = pakeControllerPubkey, exchange.peerPublicKey == announced else {
            throw PakeRefusal(reason: "the controller key in step 1 is not the one session_start named")
        }
        let ledger = try guessLedger(for: announced)
        try requireAdmitted(ledger)
        try saveGuessLedger(try GuessPolicy.replySent(ledger).ledger, for: announced)
    }

    private func requireAdmitted(_ ledger: GuessLedger) throws {
        let decision = try GuessPolicy.admit(ledger)
        guard decision.isAllowed else {
            let seconds = Int(decision.retryAfter.rounded(.up))
            throw PakeRefusal(reason: "access-code attempts are locked out for another \(seconds)s")
        }
    }

    private static func isAuthenticationFailure(_ error: Error) -> Bool {
        error is PakeRefusal || (error as? SkipperCoreError)?.isAuthenticationFailure == true
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
        if role == .host, pakeControllerPubkey != peerPubkey {
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
            if let ledger = try? guessLedger(for: peerPubkey),
               let confirmed = try? GuessPolicy.confirmed(ledger) {
                try? saveGuessLedger(confirmed.ledger, for: peerPubkey)
            }
            try? identity.secrets.recordTrustedController(
                pubkey: peerPubkey, label: machine.peerDeviceID.map(DeviceID.formatted) ?? "")
        case .controller:
            guard let code = machine.rememberedAccessCode, let host = machine.peerDeviceID else { return }
            try? identity.secrets.rememberPeerCode(code, forHost: host)
        }
    }

    /// `authentication` picks the `bye` reason (PROTOCOL.md §2.14): a wrong
    /// code, a key that is not the announced one, or a lockout is
    /// `auth_failed`; anything else is `failed`. The host's guess ledger is not
    /// touched here: a reply that left the host was already counted.
    func pakeFailed(reason: String, authentication: Bool) async {
        guard pakeRequired, !pakeComplete else { return }
        cancelPakeTimeout()
        RCLog.error("access-code exchange failed: \(reason)")
        emit(.pakeFailed(reason: reason, authentication: authentication))
        if role == .controller, authentication {
            lastError = SessionCoordinator.wrongAccessCodeMessage
            emit(.connectFailed(.authFailed))
            forgetRememberedPeerCode()
        }
        let byeReason = authentication ? Wire.ByeReason.authFailed : Wire.ByeReason.failed
        await perform(machine.userEnded(reason: byeReason))
    }

    func peerEndedExchange(byeReason: String) {
        guard pakeRequired, !pakeComplete else { return }
        cancelPakeTimeout()
        let authentication = byeReason == Wire.ByeReason.authFailed
        emit(.pakeFailed(reason: "the peer ended the exchange (\(byeReason))",
                         authentication: authentication))
        guard role == .controller, authentication else { return }
        lastError = SessionCoordinator.wrongAccessCodeMessage
        emit(.connectFailed(.authFailed))
        forgetRememberedPeerCode()
    }

    private func forgetRememberedPeerCode() {
        guard let host = machine.peerDeviceID else { return }
        try? identity.secrets.forgetPeerCode(forHost: host)
        machine.rememberedAccessCode = nil
    }

    // MARK: - The host's guess ledger (PROTOCOL.md §2.17 Guessing)

    private func guessLedger(for controllerPubkey: String) throws -> GuessLedger {
        GuessLedger(controller: try identity.secrets.guessCounter(forController: controllerPubkey),
                    host: try identity.secrets.guessCounter(forController: GuessLedger.hostKey))
    }

    private func saveGuessLedger(_ ledger: GuessLedger, for controllerPubkey: String) throws {
        try identity.secrets.saveGuessCounter(ledger.controller, forController: controllerPubkey)
        try identity.secrets.saveGuessCounter(ledger.host, forController: GuessLedger.hostKey)
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
