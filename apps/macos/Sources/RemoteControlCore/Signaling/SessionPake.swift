import Foundation
import SkipperCore

/// The access-code exchange of PROTOCOL.md §2.17, driven over a live session.
///
/// The server opened the session on entitlement alone; this is what decides
/// whether the two Macs are actually allowed to talk. Nothing reaches the media
/// path until it completes: `SessionCoordinator` holds the state machine's
/// `startPeerConnection` until then, so a controller that does not know the code
/// gets a relayed handshake that fails and nothing else.
///
/// No crypto lives here. Every byte of the exchange comes from `PakeExchange`
/// and every rate-limiting decision from `GuessPolicy`, both in the shared core.
/// This file decides only *when* to call them and what to do with the answer.
extension SessionCoordinator {

    /// PROTOCOL.md §2.17: an exchange that has not completed 10 seconds after it
    /// began is abandoned.
    static let pakeTimeoutSeconds: UInt64 = 10

    // MARK: - Starting

    /// Both roles, the moment the session exists: from here until the exchange
    /// completes, the peer connection is on hold.
    func armPake(for grant: SessionGrantPayload) {
        clearPake()
        pakeRequired = true
        pakeControllerPubkey = grant.controllerPubkey
        startPakeTimeout()
    }

    /// CONTROLLER. Step 1 costs nothing and is always sent, whether or not this
    /// Mac has connected to this host before (PROTOCOL.md §4.5).
    ///
    /// `accessCode` is passed in rather than held on the coordinator so the
    /// plaintext lives exactly as long as the exchange that consumes it.
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

    /// HOST. The guess policy is consulted *before* SPAKE2 runs, so a locked-out
    /// controller costs this Mac one lookup and one `bye`.
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

    /// One relayed `pake` frame. Each side hands it to the shared core and sends
    /// back whatever comes out; a throw here is a failed confirmation, which on
    /// either side means the two Macs do not hold the same code.
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

    /// Both Macs proved the same code. The key the exchange bound into its
    /// transcript is now the only key this side will accept on an `sdp` (§2.12).
    private func pakeSucceeded(_ exchange: PakeExchange) async {
        guard let peerPubkey = exchange.peerPublicKey, !peerPubkey.isEmpty else {
            await pakeFailed(reason: "the exchange completed without a peer key", authentication: true)
            return
        }
        // A key that is not the one the server named is not a code failure: it
        // is the relay trying to stand between the two Macs.
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

        // The offer the state machine asked for while this was running.
        if let offerer = deferredPeerStart {
            deferredPeerStart = nil
            startPeerAfterPake(offerer: offerer)
        }
    }

    /// HOST: the controller is now on the trusted list and its failure count is
    /// cleared. CONTROLLER: the code is worth remembering, if the user said so.
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

    /// The exchange is over and the session with it. `authentication` chooses
    /// between `bye{auth_failed}` and `bye{failed}` (PROTOCOL.md §2.14), and on
    /// the host it is also what counts against the guess policy.
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

    /// A `bye` arrived while the exchange was still running. Whichever side
    /// detects the mismatch first ends the session, so both sides have to handle
    /// being the one that is told.
    ///
    /// A wrong code fails for the CONTROLLER at step 2 and for the HOST at step
    /// 3 (PROTOCOL.md §2.17), so in practice it is the controller that speaks
    /// first and the host that hears this. That is why the host counts it: §2.17
    /// says an exchange abandoned after step 1 is a failure, and without this a
    /// guesser could run unlimited attempts by hanging up before step 3.
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
            // Abandoned after step 1 is a failure the host counts (§2.17), but
            // it is not evidence about the code, so it is `bye{failed}`.
            await self.pakeFailed(reason: "the access-code exchange timed out", authentication: false)
        }
    }

    private func cancelPakeTimeout() {
        pakeTimeout?.cancel()
        pakeTimeout = nil
    }

    public static let wrongAccessCodeMessage = "Wrong access code."
}
