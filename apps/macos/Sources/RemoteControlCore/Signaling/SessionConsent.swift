import Foundation
import SkipperCore

public struct ConsentRequest: Equatable, Sendable {
    public static let allowDelay: TimeInterval = 1.5

    public let sessionID: String
    public let controllerLabel: String?
    public let controllerDeviceID: String?
    public let presentedAt: Date
    public let expiresAt: Date

    public init(sessionID: String, controllerLabel: String?, controllerDeviceID: String?,
                presentedAt: Date = Date(), expiresAt: Date) {
        self.sessionID = sessionID
        self.controllerLabel = controllerLabel
        self.controllerDeviceID = controllerDeviceID
        self.presentedAt = presentedAt
        self.expiresAt = expiresAt
    }

    public var controllerName: String {
        guard let label = controllerLabel?.trimmingCharacters(in: .whitespacesAndNewlines),
              !label.isEmpty else { return "another Mac" }
        return label
    }

    public var title: String { "Allow \(controllerName) to control this Mac?" }

    public static let message = "It entered this Mac\u{2019}s access code. If you do not answer, the connection is declined."

    /// Says nothing about which Mac is asking, so it is safe on a locked screen.
    public static let notificationBody = "A Mac entered this Mac\u{2019}s code and is asking to connect."

    public var allowsAnswerAt: Date { presentedAt.addingTimeInterval(Self.allowDelay) }

    public func allowEnabled(now: Date = Date()) -> Bool { now >= allowsAnswerAt }

    public func secondsRemaining(now: Date = Date()) -> Int {
        let milliseconds = (expiresAt.timeIntervalSince(now) * 1000).rounded()
        return max(0, Int((milliseconds / 1000).rounded(.up)))
    }

    public func countdown(now: Date = Date()) -> String {
        let seconds = secondsRemaining(now: now)
        return "Declines in \(seconds) second\(seconds == 1 ? "" : "s")"
    }
}

/// What the coordinator does with a remote `sdp` or `ice` (PROTOCOL.md §2.17
/// Consent, §4.2): a signal for another session is dropped; one for this
/// session waits until the state machine itself has started the peer, and
/// never touches a peer while the owner is being asked.
public enum RemoteSignalDisposition: Equatable, Sendable {
    case drop
    case hold
    case apply

    public static func of(signalSessionID: String, machine: SessionStateMachine,
                          hasPeer: Bool) -> RemoteSignalDisposition {
        guard let current = machine.sessionID, current == signalSessionID else { return .drop }
        guard machine.phase != .awaitingConsent, machine.peerStarted, hasPeer else { return .hold }
        return .apply
    }
}

extension SessionCoordinator {

    static let acceptanceNoticeDelayNanoseconds: UInt64 = 2_000_000_000
    static let maxHeldCandidates = 64

    // MARK: - Answering

    /// Answers the prompt on screen. Allow takes effect no earlier than
    /// `ConsentRequest.allowDelay` after the prompt appeared.
    public func answerConsent(allow: Bool) async {
        guard let request = consentRequest else { return }
        await answerConsent(allow: allow, sessionID: request.sessionID)
    }

    public func answerConsent(allow: Bool, sessionID: String) async {
        guard let request = consentRequest, request.sessionID == sessionID else { return }
        let wait = request.allowsAnswerAt.timeIntervalSinceNow
        if allow, wait > 0 {
            try? await Task.sleep(nanoseconds: UInt64((min(wait, ConsentRequest.allowDelay) * 1e9).rounded()))
            guard consentRequest?.sessionID == sessionID else { return }
        }
        await perform(machine.consentAnswered(allow: allow, sessionID: sessionID))
    }

    func admitPeer(pubkey: String) async {
        if role == .controller { watchForAcceptance() }
        guard role == .host, machine.consentRequired else {
            await perform(machine.pakeSucceeded())
            return
        }
        let decision = (try? guessLedger(for: pubkey)).flatMap { try? ConsentPolicy.admit($0) }
        guard let decision, decision.shouldPrompt else {
            RCLog.info("declined without asking: the consent budget for this controller or this Mac is spent")
            emit(.consentEnded(.declined, automatic: true))
            await perform(machine.userEnded(reason: Wire.ByeReason.declined))
            return
        }
        await perform(machine.pakeSucceeded())
    }

    // MARK: - The prompt

    func presentConsent(expiresAt: Date) async {
        guard let sessionID = machine.sessionID, let pubkey = expectedPeerPublicKey else {
            await perform(machine.consentAnswered(allow: false))
            return
        }
        consentControllerKey = pubkey
        updateConsentLedger { try ConsentPolicy.prompted($0) }
        let request = ConsentRequest(
            sessionID: sessionID,
            controllerLabel: trustedLabel(for: pubkey),
            controllerDeviceID: machine.peerDeviceID,
            expiresAt: expiresAt)
        consentRequest = request
        emit(.consentRequested(request))
    }

    func dismissConsent(_ outcome: ConsentOutcome) {
        consentRequest = nil
        if outcome == .allowed {
            updateConsentLedger { try ConsentPolicy.allowed($0) }
        } else {
            heldRemoteSDP = nil
            heldCandidates = []
        }
        consentControllerKey = nil
        emit(.consentEnded(outcome, automatic: false))
    }

    private func updateConsentLedger(_ change: (GuessLedger) throws -> ConsentDecision) {
        guard let pubkey = consentControllerKey else { return }
        do {
            try saveGuessLedger(try change(try guessLedger(for: pubkey)).ledger, for: pubkey)
        } catch {
            RCLog.error("consent ledger not updated: \(error.localizedDescription)")
        }
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

    // MARK: - Signals that arrive before the peer may take them

    func disposition(of signalSessionID: String) -> RemoteSignalDisposition {
        RemoteSignalDisposition.of(signalSessionID: signalSessionID, machine: machine, hasPeer: peer != nil)
    }

    func hold(_ sdp: SDPPayload) {
        heldRemoteSDP = sdp
    }

    func hold(_ ice: ICEPayload) {
        guard heldCandidates.count < Self.maxHeldCandidates else { return }
        heldCandidates.append(ice)
    }

    func releaseHeldSignals() async {
        let sdp = heldRemoteSDP
        let candidates = heldCandidates
        heldRemoteSDP = nil
        heldCandidates = []
        if let sdp { await handleRemoteSDP(sdp) }
        for ice in candidates { await handleRemoteICE(ice) }
    }

    func clearConsentState() {
        heldRemoteSDP = nil
        heldCandidates = []
        consentRequest = nil
        consentControllerKey = nil
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
