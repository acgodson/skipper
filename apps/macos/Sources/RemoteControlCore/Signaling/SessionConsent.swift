import Foundation
import SkipperCore

public struct ConsentRequest: Equatable, Sendable {
    public let sessionID: String
    public let controllerLabel: String?
    public let controllerDeviceID: String?
    public let expiresAt: Date

    public init(sessionID: String, controllerLabel: String?, controllerDeviceID: String?, expiresAt: Date) {
        self.sessionID = sessionID
        self.controllerLabel = controllerLabel
        self.controllerDeviceID = controllerDeviceID
        self.expiresAt = expiresAt
    }

    public var controllerName: String {
        guard let label = controllerLabel?.trimmingCharacters(in: .whitespacesAndNewlines),
              !label.isEmpty else { return "another Mac" }
        return label
    }

    public var title: String { "Allow \(controllerName) to control this Mac?" }

    public static let message = "It entered this Mac\u{2019}s access code. If you do not answer, the connection is declined."

    public func secondsRemaining(now: Date = Date()) -> Int {
        let milliseconds = (expiresAt.timeIntervalSince(now) * 1000).rounded()
        return max(0, Int((milliseconds / 1000).rounded(.up)))
    }

    public func countdown(now: Date = Date()) -> String {
        let seconds = secondsRemaining(now: now)
        return "Declines in \(seconds) second\(seconds == 1 ? "" : "s")"
    }
}

extension SessionCoordinator {

    static let acceptanceNoticeDelayNanoseconds: UInt64 = 2_000_000_000
    static let maxHeldCandidates = 64

    // MARK: - Answering

    public func answerConsent(allow: Bool) async {
        await perform(machine.consentAnswered(allow: allow))
    }

    func admitPeer(pubkey: String) async {
        if role == .controller { watchForAcceptance() }
        guard role == .host, machine.consentRequired else {
            await perform(machine.pakeSucceeded())
            return
        }
        let decision = try? ConsentPolicy.admit(consentLedgers[pubkey] ?? ConsentLedger())
        guard decision?.shouldPrompt == true else {
            RCLog.info("declined without asking: this controller was declined twice in the last 10 minutes")
            emit(.consentEnded(.declined, automatic: true))
            await perform(machine.userEnded(reason: Wire.ByeReason.declined))
            return
        }
        await perform(machine.pakeSucceeded())
    }

    // MARK: - The prompt

    func presentConsent(expiresAt: Date) {
        guard let sessionID = machine.sessionID else { return }
        let request = ConsentRequest(
            sessionID: sessionID,
            controllerLabel: expectedPeerPublicKey.flatMap(trustedLabel(for:)),
            controllerDeviceID: machine.peerDeviceID,
            expiresAt: expiresAt)
        consentRequest = request
        emit(.consentRequested(request))
    }

    func dismissConsent(_ outcome: ConsentOutcome) {
        consentRequest = nil
        if outcome != .allowed {
            heldRemoteSDP = nil
            heldCandidates = []
        }
        recordConsent(outcome)
        emit(.consentEnded(outcome, automatic: false))
    }

    private func recordConsent(_ outcome: ConsentOutcome) {
        guard let pubkey = expectedPeerPublicKey, outcome != .cancelled else { return }
        let ledger = consentLedgers[pubkey] ?? ConsentLedger()
        let decision = outcome.countsAsDecline
            ? try? ConsentPolicy.declined(ledger)
            : try? ConsentPolicy.allowed(ledger)
        guard let updated = decision?.ledger, !updated.declineTimesMs.isEmpty else {
            consentLedgers[pubkey] = nil
            return
        }
        consentLedgers[pubkey] = updated
    }

    private func trustedLabel(for pubkey: String) -> String? {
        guard let label = (try? identity.secrets.trustedControllers())?[pubkey]?.label,
              !label.isEmpty else { return nil }
        return label
    }

    func peerStarting() {
        guard role == .host, let pubkey = expectedPeerPublicKey else { return }
        try? identity.secrets.recordTrustedController(
            pubkey: pubkey, label: machine.peerDeviceID.map(DeviceID.formatted) ?? "")
    }

    // MARK: - Signals that arrive while the owner decides

    func holdWhileAwaitingConsent(_ sdp: SDPPayload) -> Bool {
        guard machine.phase == .awaitingConsent else { return false }
        heldRemoteSDP = sdp
        return true
    }

    func holdWhileAwaitingConsent(_ ice: ICEPayload) -> Bool {
        guard machine.phase == .awaitingConsent else { return false }
        if ice.sessionId == machine.sessionID, heldCandidates.count < Self.maxHeldCandidates {
            heldCandidates.append(ice)
        }
        return true
    }

    func releaseHeldSignals() async {
        let sdp = heldRemoteSDP
        let candidates = heldCandidates
        heldRemoteSDP = nil
        heldCandidates = []
        if let sdp { await handleRemoteSDP(sdp) }
        for ice in candidates {
            try? await peer?.addCandidate(ice.candidate, sdpMid: ice.sdpMid, sdpMLineIndex: ice.sdpMLineIndex)
        }
    }

    func clearConsentState() {
        heldRemoteSDP = nil
        heldCandidates = []
        consentRequest = nil
        stopAwaitingAcceptance()
    }

    // MARK: - Controller: "Waiting for the other Mac to accept…"

    private func watchForAcceptance() {
        acceptanceWatch?.cancel()
        acceptanceWatch = Task { [weak self] in
            try? await Task.sleep(nanoseconds: SessionCoordinator.acceptanceNoticeDelayNanoseconds)
            guard !Task.isCancelled, let self, self.phase == .connecting else { return }
            self.awaitingPeerAcceptance = true
            self.emit(.awaitingPeerAcceptance)
        }
    }

    func stopAwaitingAcceptance() {
        acceptanceWatch?.cancel()
        acceptanceWatch = nil
        if awaitingPeerAcceptance { awaitingPeerAcceptance = false }
    }
}
