import Foundation
import SkipperCore

private struct PakeRefusal: Error, LocalizedError {
    let reason: String
    var errorDescription: String? { reason }
}

// Every await in this file can let another session start. After each one the
// exchange and the session id are checked again, and a result for anything
// but the current exchange of the current session is dropped.
extension SessionCoordinator {

    static let pakeTimeoutSeconds: UInt64 = 10

    // MARK: - Starting

    func armPake(for grant: SessionGrantPayload) {
        clearPake()
        clearConsentState()
        pakeRequired = true
        pakeControllerPubkey = grant.controllerPubkey
    }

    func startControllerPake(grant: SessionGrantPayload, accessCode: String) async {
        guard role == .controller, machine.sessionID == grant.sessionId, pakeRequired else { return }
        let sessionID = grant.sessionId
        startPakeTimeout(sessionID: sessionID)
        let exchange: PakeExchange
        let step1: PakeMessage
        do {
            exchange = try PakeExchange.controller(
                accessCode: accessCode,
                deviceID: grant.hostDeviceId,
                sessionID: sessionID,
                ownPublicKey: identity.publicKeyBase64)
            pakeExchange = exchange
            guard let opening = try exchange.step(nil) else {
                throw PakeRefusal(reason: "the exchange produced no opening message")
            }
            step1 = opening
        } catch {
            await pakeFailed(reason: error.localizedDescription, authentication: false, sessionID: sessionID)
            return
        }
        do {
            try await send(step1, sessionID: sessionID)
        } catch {
            guard isCurrent(exchange, sessionID: sessionID) else { return }
            await pakeFailed(reason: error.localizedDescription, authentication: false, sessionID: sessionID)
        }
    }

    func startHostPake(grant: SessionGrantPayload) async {
        guard role == .host, machine.sessionID == grant.sessionId, pakeRequired else { return }
        let sessionID = grant.sessionId
        startPakeTimeout(sessionID: sessionID)
        guard let controllerPubkey = grant.controllerPubkey, DevicePublicKey.isCanonical(controllerPubkey) else {
            await pakeFailed(reason: "session_start carried no usable controller key",
                             authentication: true, sessionID: sessionID)
            return
        }
        do {
            try requireAdmitted(try guessLedger(for: controllerPubkey))
            pakeExchange = try PakeExchange.host(
                accessCode: identity.accessCode,
                deviceID: grant.hostDeviceId,
                sessionID: sessionID,
                ownPublicKey: identity.publicKeyBase64)
        } catch {
            await pakeFailed(reason: error.localizedDescription,
                             authentication: Self.isAuthenticationFailure(error), sessionID: sessionID)
        }
    }

    // MARK: - Running

    func handlePake(_ frame: PakePayload) async {
        let sessionID = frame.sessionId
        guard sessionID == machine.sessionID, let exchange = pakeExchange,
              isCurrent(exchange, sessionID: sessionID) else { return }
        startPakeTimeout(sessionID: sessionID)
        emit(.pake(step: frame.step, outgoing: false))
        do {
            if let outgoing = try exchange.step(frame.message) {
                if role == .host { try recordHostReply(exchange) }
                try await send(outgoing, sessionID: sessionID)
            }
        } catch {
            guard isCurrent(exchange, sessionID: sessionID) else { return }
            await pakeFailed(reason: error.localizedDescription,
                             authentication: Self.isAuthenticationFailure(error), sessionID: sessionID)
            return
        }
        guard isCurrent(exchange, sessionID: sessionID), exchange.isComplete else { return }
        await pakeSucceeded(exchange, sessionID: sessionID)
    }

    func isCurrent(_ exchange: PakeExchange, sessionID: String) -> Bool {
        pakeExchange === exchange && machine.sessionID == sessionID && pakeRequired && !pakeComplete
    }

    private func send(_ message: PakeMessage, sessionID: String) async throws {
        try await signaling.sendPake(sessionID: sessionID, message: message)
        emit(.pake(step: message.step, outgoing: true))
    }

    /// Step 2 carries the host's confirmation, which lets whoever sent step 1
    /// check one guess offline; the guess is paid for before it leaves.
    private func recordHostReply(_ exchange: PakeExchange) throws {
        guard let announced = pakeControllerPubkey, DevicePublicKey.same(exchange.peerPublicKey, announced) else {
            throw PakeRefusal(reason: "the controller key in step 1 is not the one session_start named")
        }
        let ledger = try guessLedger(for: announced)
        try requireAdmitted(ledger)
        try saveGuessLedger(try GuessPolicy.replySent(ledger).ledger, for: announced)
    }

    private func requireAdmitted(_ ledger: GuessLedger) throws {
        let decision = try GuessPolicy.admit(ledger)
        guard decision.isAllowed else {
            let seconds = WireBounds.int(decision.retryAfter.rounded(.up)) ?? 0
            throw PakeRefusal(reason: "access-code attempts are locked out for another \(seconds)s")
        }
    }

    private static func isAuthenticationFailure(_ error: Error) -> Bool {
        error is PakeRefusal || (error as? SkipperCoreError)?.isAuthenticationFailure == true
    }

    // MARK: - Ending

    private func pakeSucceeded(_ exchange: PakeExchange, sessionID: String) async {
        guard let peerPubkey = exchange.peerPublicKey, DevicePublicKey.isCanonical(peerPubkey) else {
            await pakeFailed(reason: "the exchange completed without a well-formed peer key",
                             authentication: true, sessionID: sessionID)
            return
        }
        if role == .controller, let pinned = expectedPeerPublicKey, !DevicePublicKey.same(pinned, peerPubkey) {
            await refusePeerFromPake(reason: "the host key in the exchange is not the one connect_ok named")
            return
        }
        if role == .host, !DevicePublicKey.same(pakeControllerPubkey, peerPubkey) {
            await pakeFailed(reason: "the controller key in step 1 is not the one session_start named",
                             authentication: true, sessionID: sessionID)
            return
        }

        cancelPakeTimeout()
        pakeComplete = true
        expectPeerPublicKey(peerPubkey)
        emit(.pakeCompleted(peerPubkey: peerPubkey))
        recordPakeSuccess(peerPubkey: peerPubkey)
        if role == .controller {
            identity.hostKeyPins.confirm(sessionID: sessionID, hostPubkey: peerPubkey)
        }
        await admitPeer(pubkey: peerPubkey)
    }

    private func recordPakeSuccess(peerPubkey: String) {
        switch role {
        case .host:
            if let ledger = try? guessLedger(for: peerPubkey),
               let confirmed = try? GuessPolicy.confirmed(ledger) {
                try? saveGuessLedger(confirmed.ledger, for: peerPubkey)
            }
        case .controller:
            guard let code = machine.rememberedAccessCode, let host = machine.peerDeviceID else { return }
            try? identity.secrets.rememberPeerCode(code, forHost: host)
        }
    }

    /// `authentication` picks the `bye` reason (PROTOCOL.md §2.14): a wrong
    /// code, a key that is not the announced one, or a lockout is
    /// `auth_failed`; anything else is `failed`. The host's guess ledger is not
    /// touched here: a reply that left the host was already counted. A
    /// controller keeps a pinned host's remembered code: a server that knows
    /// only the host's public key can fake a failed exchange.
    func pakeFailed(reason: String, authentication: Bool, sessionID: String) async {
        guard pakeRequired, !pakeComplete, machine.sessionID == sessionID else { return }
        cancelPakeTimeout()
        RCLog.error("access-code exchange failed: \(reason)")
        emit(.pakeFailed(reason: reason, authentication: authentication))
        if role == .controller, authentication {
            reportWrongAccessCode()
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
        reportWrongAccessCode()
    }

    private func reportWrongAccessCode() {
        lastError = SessionCoordinator.wrongAccessCodeMessage
        emit(.connectFailed(.authFailed))
        guard identity.hostKeyPins.mayForgetCode(forHost: machine.peerDeviceID),
              let host = machine.peerDeviceID else { return }
        try? identity.secrets.forgetPeerCode(forHost: host)
        machine.rememberedAccessCode = nil
    }

    // MARK: - The host's guess ledger (PROTOCOL.md §2.17 Guessing)

    func guessLedger(for controllerPubkey: String) throws -> GuessLedger {
        let key = try DevicePublicKey.canonical(controllerPubkey)
        return GuessLedger(controller: try identity.secrets.guessCounter(forController: key),
                           host: try identity.secrets.guessCounter(forController: GuessLedger.hostKey))
    }

    func saveGuessLedger(_ ledger: GuessLedger, for controllerPubkey: String) throws {
        let key = try DevicePublicKey.canonical(controllerPubkey)
        try identity.secrets.saveGuessCounter(ledger.controller, forController: key)
        try identity.secrets.saveGuessCounter(ledger.host, forController: GuessLedger.hostKey)
    }

    // MARK: - Bookkeeping

    func clearPake() {
        cancelPakeTimeout()
        pakeExchange = nil
        pakeComplete = false
        pakeRequired = false
        pakeControllerPubkey = nil
    }

    private func startPakeTimeout(sessionID: String) {
        cancelPakeTimeout()
        pakeTimeout = Task { [weak self] in
            try? await Task.sleep(nanoseconds: SessionCoordinator.pakeTimeoutSeconds * 1_000_000_000)
            guard !Task.isCancelled, let self else { return }
            await self.pakeFailed(reason: "the access-code exchange timed out",
                                  authentication: false, sessionID: sessionID)
        }
    }

    private func cancelPakeTimeout() {
        pakeTimeout?.cancel()
        pakeTimeout = nil
    }

    public static let wrongAccessCodeMessage = "Wrong access code."
}
