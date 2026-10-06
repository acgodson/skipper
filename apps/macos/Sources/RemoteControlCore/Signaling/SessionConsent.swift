import Foundation
import SkipperCore

/// One prompt on screen. `promptID` is the shared core's local random name
/// for it, never the server's session id; an answer carries it back.
public struct ConsentRequest: Equatable, Sendable {
    public static let allowDelay: TimeInterval = 1.5
    public static let replacedNotice = "A different request replaced the previous one."

    public let promptID: String
    public let controllerLabel: String?
    public let controllerDeviceID: String?
    public let controllerFingerprint: String?
    public let replacesPrevious: Bool
    public let presentedAt: Date
    public let expiresAt: Date

    public init(promptID: String, controllerLabel: String?, controllerDeviceID: String?,
                controllerFingerprint: String? = nil, replacesPrevious: Bool = false,
                presentedAt: Date = Date(), expiresAt: Date) {
        self.promptID = promptID
        self.controllerLabel = controllerLabel
        self.controllerDeviceID = controllerDeviceID
        self.controllerFingerprint = controllerFingerprint
        self.replacesPrevious = replacesPrevious
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

    public var deviceIDLine: String? {
        controllerDeviceID.map { "Device ID \(DeviceID.formatted($0))" }
    }

    /// The same six groups the other Mac shows as "This Mac\u{2019}s fingerprint".
    public var fingerprintLine: String? {
        controllerFingerprint.map(DevicePublicKey.fingerprintLine)
    }

    public var notice: String? { replacesPrevious ? Self.replacedNotice : nil }

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

    /// Answers the prompt named `promptID`. An answer for a prompt that is no
    /// longer on screen, or an Allow earlier than `ConsentRequest.allowDelay`
    /// after its prompt appeared, is refused by the core and never deferred.
    public func answerConsent(allow: Bool, promptID: String) async {
        guard consentRequest?.promptID == promptID else { return }
        await perform(machine.consentAnswered(allow: allow, promptID: promptID))
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

    func presentConsent(expiresAt: Date, promptID: String, replacesPrevious: Bool) async {
        guard machine.consentPromptID == promptID else { return }
        guard machine.sessionID != nil, let pubkey = expectedPeerPublicKey,
              let fingerprint = try? DevicePublicKey.fingerprint(pubkey) else {
            await perform(machine.consentAnswered(allow: false, promptID: promptID))
            return
        }
        consentControllerKey = pubkey
        updateConsentLedger { try ConsentPolicy.prompted($0) }
        let request = ConsentRequest(
            promptID: promptID,
            controllerLabel: trustedLabel(for: pubkey),
            controllerDeviceID: machine.peerDeviceID,
            controllerFingerprint: fingerprint,
            replacesPrevious: replacesPrevious,
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
