import CSkipperCore
import Foundation

private struct CoreResponse: Decodable {
    let ok: Bool
    let error: String?
    let actions: [CoreAction]?
    let state: CoreState?
}

private struct CoreAction: Decodable {
    let action: String
    let deviceId: String?
    let accessCode: String?
    let sessionId: String?
    let sessionToken: String?
    let afterSec: Int?
    let offerer: Bool?
    let relayOnly: Bool?
    let reason: String?
    let expiresAtMs: Int64?
    let promptId: String?
    let replacesPrevious: Bool?
    let outcome: String?
}

private struct CoreState: Decodable {
    let role: String
    let phase: String
    let closedReason: String?
    let hasSession: Bool
    let signalingUp: Bool
    let resumeInFlight: Bool
    let relayOnly: Bool
    let isOfferer: Bool
    let iceState: String
    let sessionId: String?
    let sessionToken: String?
    let peerDeviceId: String?
    let rememberedAccessCode: String?
    let serverAdvertisedSessionId: String?
    let consentRequired: Bool
    let consentExpiresAtMs: Int64?
    let consentPromptId: String?
    let peerStarted: Bool
}

public final class SessionStateMachine {

    private let handle: OpaquePointer

    // MARK: Configuration

    public let iceRestartDelay: TimeInterval
    public let iceFailureGrace: TimeInterval
    public let renewInterval: TimeInterval

    // MARK: Observable state

    public private(set) var role: SessionRole
    public private(set) var phase: SessionPhase = .idle
    public private(set) var sessionID: String?
    public private(set) var sessionToken: String?
    public private(set) var peerDeviceID: String?
    public private(set) var signalingUp = false
    public private(set) var iceState: ICELinkState = .new
    public private(set) var resumeInFlight = false
    public private(set) var relayOnly = false
    public private(set) var hasSession = false
    public private(set) var isOfferer = false
    public private(set) var serverAdvertisedSessionID: String?
    public private(set) var consentExpiresAt: Date?
    public private(set) var consentPromptID: String?
    public private(set) var peerStarted = false

    public var consentRequired: Bool {
        get { storedConsentRequired }
        set { _ = call { skipper_session_set_consent_required(handle, newValue) } }
    }
    private var storedConsentRequired = false

    public var rememberedAccessCode: String? {
        get { storedRememberedAccessCode }
        set { _ = call([newValue]) { skipper_session_set_remembered_access_code(handle, $0[0].base, $0[0].count) } }
    }
    private var storedRememberedAccessCode: String?

    /// Why the core last refused an event (for example a server-supplied value
    /// with a NUL byte); a refused event changes nothing.
    public private(set) var lastRejection: String?

    public init(
        role: SessionRole,
        iceRestartDelay: TimeInterval = 3,
        iceFailureGrace: TimeInterval = 45,
        renewInterval: TimeInterval = 300
    ) {
        self.role = role
        self.iceRestartDelay = iceRestartDelay
        self.iceFailureGrace = iceFailureGrace
        self.renewInterval = renewInterval
        guard let handle = skipper_session_new(
            role == .host ? Int32(SKIPPER_ROLE_HOST) : Int32(SKIPPER_ROLE_CONTROLLER),
            Self.milliseconds(iceRestartDelay),
            Self.milliseconds(iceFailureGrace),
            Self.milliseconds(renewInterval))
        else {
            preconditionFailure("skipper_session_new returned null")
        }
        self.handle = handle
        _ = call { skipper_session_state(handle) }
    }

    deinit { skipper_session_free(handle) }

    // MARK: - Controller-initiated connect

    public func setRelayOnly(_ relayOnly: Bool) {
        _ = call { skipper_session_set_relay_only(handle, relayOnly) }
    }

    public func connectRequested(deviceID: String, accessCode: String, remember: Bool) -> [SessionAction] {
        call([deviceID, accessCode]) {
            skipper_session_connect_requested(handle, $0[0].base, $0[0].count,
                                              $0[1].base, $0[1].count, remember)
        }
    }

    @discardableResult
    public func sessionGranted(_ grant: SessionGrantLike, now: Date = Date()) -> [SessionAction] {
        call([grant.sessionId, grant.sessionToken, grant.hostDeviceId, grant.controllerDeviceId]) {
            skipper_session_granted(handle, $0[0].base, $0[0].count, $0[1].base, $0[1].count,
                                    $0[2].base, $0[2].count, $0[3].base, $0[3].count,
                                    CoreBoundary.milliseconds(now))
        }
    }

    public func pakeSucceeded(now: Date = Date()) -> [SessionAction] {
        call { skipper_session_pake_succeeded(handle, CoreBoundary.milliseconds(now)) }
    }

    /// `promptID` is the name the core gave the prompt being answered; an
    /// answer for any other prompt, or an Allow without a name, changes nothing.
    public func consentAnswered(allow: Bool, promptID: String?, now: Date = Date()) -> [SessionAction] {
        call([promptID]) {
            skipper_session_consent_answered(handle, allow, $0[0].base, $0[0].count,
                                             CoreBoundary.milliseconds(now))
        }
    }

    public func iceServersArrived(sessionID: String) -> [SessionAction] {
        call([sessionID]) { skipper_session_ice_servers_arrived(handle, $0[0].base, $0[0].count) }
    }

    public func connectFailed(code: String) -> [SessionAction] {
        call([code]) { skipper_session_connect_failed(handle, $0[0].base, $0[0].count) }
    }

    // MARK: - Signaling transitions (PROTOCOL.md §4.3)

    public func signalingLost() -> [SessionAction] {
        call { skipper_session_signaling_lost(handle) }
    }

    public func signalingAuthenticated(activeSessionID: String?) -> [SessionAction] {
        call([activeSessionID]) {
            skipper_session_signaling_authenticated(handle, $0[0].base, $0[0].count)
        }
    }

    public func resumeSucceeded(_ ok: SessionTokenLike, now: Date = Date()) -> [SessionAction] {
        call([ok.sessionId, ok.sessionToken]) {
            skipper_session_resume_succeeded(handle, $0[0].base, $0[0].count,
                                             $0[1].base, $0[1].count, CoreBoundary.milliseconds(now))
        }
    }

    public func resumeFailed(code: String, retryAfterSec: Int) -> [SessionAction] {
        call([code]) {
            skipper_session_resume_failed(handle, $0[0].base, $0[0].count,
                                          Int32(clamping: retryAfterSec))
        }
    }

    public func renewSucceeded(_ ok: SessionTokenLike, now: Date = Date()) {
        _ = call([ok.sessionId, ok.sessionToken]) {
            skipper_session_renew_succeeded(handle, $0[0].base, $0[0].count,
                                            $0[1].base, $0[1].count, CoreBoundary.milliseconds(now))
        }
    }

    public func renewFailed(code: String, now: Date = Date()) -> [SessionAction] {
        call([code]) { skipper_session_renew_failed(handle, $0[0].base, $0[0].count) }
    }

    // MARK: - ICE transitions (PLAN.md §2.1)

    public func iceStateChanged(to newState: ICELinkState, now: Date = Date()) -> [SessionAction] {
        call([newState.rawValue]) {
            skipper_session_ice_state_changed(handle, $0[0].base, $0[0].count, CoreBoundary.milliseconds(now))
        }
    }

    public func tick(now: Date = Date()) -> [SessionAction] {
        call { skipper_session_tick(handle, CoreBoundary.milliseconds(now)) }
    }

    // MARK: - Endings

    public func closeLocally(reason: String) -> [SessionAction] {
        call([reason]) { skipper_session_close_locally(handle, $0[0].base, $0[0].count) }
    }

    public func userEnded(reason: String = "user_ended") -> [SessionAction] {
        call([reason]) { skipper_session_user_ended(handle, $0[0].base, $0[0].count) }
    }

    // MARK: - Boundary

    private static func milliseconds(_ interval: TimeInterval) -> Int64 {
        Int64((interval * 1000).rounded())
    }

    private func call(
        _ text: [String?],
        _ body: ([CoreBytes]) -> UnsafeMutablePointer<CChar>?
    ) -> [SessionAction] {
        CoreBoundary.withText(text) { arguments in call { body(arguments) } }
    }

    private func call(_ body: () -> UnsafeMutablePointer<CChar>?) -> [SessionAction] {
        lastRejection = nil
        guard let raw = body() else {
            preconditionFailure("the shared core could not allocate a result")
        }
        defer { skipper_string_free(raw) }
        let data = Data(bytes: raw, count: strlen(raw))
        guard let response = try? JSONDecoder().decode(CoreResponse.self, from: data) else {
            preconditionFailure("the shared core returned an undecodable result")
        }
        if let state = response.state { apply(state) }
        guard response.ok, response.state != nil else {
            lastRejection = response.error ?? "the shared core rejected the event"
            return []
        }
        return (response.actions ?? []).map(Self.action)
    }

    private func apply(_ state: CoreState) {
        role = SessionRole(rawValue: state.role) ?? role
        switch state.phase {
        case "idle": phase = .idle
        case "connecting": phase = .connecting
        case "awaitingConsent": phase = .awaitingConsent
        case "live": phase = .live
        case "reconnecting": phase = .reconnecting
        case "closed": phase = .closed(reason: state.closedReason ?? "")
        default: preconditionFailure("the shared core reported phase \(state.phase)")
        }
        guard let ice = ICELinkState(rawValue: state.iceState) else {
            preconditionFailure("the shared core reported ice state \(state.iceState)")
        }
        iceState = ice
        hasSession = state.hasSession
        signalingUp = state.signalingUp
        resumeInFlight = state.resumeInFlight
        relayOnly = state.relayOnly
        isOfferer = state.isOfferer
        sessionID = state.sessionId
        sessionToken = state.sessionToken
        peerDeviceID = state.peerDeviceId
        storedRememberedAccessCode = state.rememberedAccessCode
        serverAdvertisedSessionID = state.serverAdvertisedSessionId
        storedConsentRequired = state.consentRequired
        consentExpiresAt = state.consentExpiresAtMs.map(Self.date)
        consentPromptID = state.consentPromptId
        peerStarted = state.peerStarted
    }

    private static func date(_ milliseconds: Int64) -> Date {
        Date(timeIntervalSince1970: TimeInterval(milliseconds) / 1000)
    }

    private static func action(_ raw: CoreAction) -> SessionAction {
        func need<T>(_ value: T?, _ field: String) -> T {
            guard let value else {
                preconditionFailure("action \(raw.action) from the shared core has no \(field)")
            }
            return value
        }
        switch raw.action {
        case "sendConnectReq":
            return .sendConnectReq(deviceID: need(raw.deviceId, "deviceId"),
                                   accessCode: need(raw.accessCode, "accessCode"))
        case "sendResume":
            return .sendResume(sessionID: need(raw.sessionId, "sessionId"),
                               sessionToken: need(raw.sessionToken, "sessionToken"))
        case "scheduleResume":
            return .scheduleResume(afterSec: need(raw.afterSec, "afterSec"))
        case "sendRenew":
            return .sendRenew(sessionID: need(raw.sessionId, "sessionId"),
                              sessionToken: need(raw.sessionToken, "sessionToken"))
        case "sendInputReset":
            return .sendInputReset
        case "startPeerConnection":
            return .startPeerConnection(offerer: need(raw.offerer, "offerer"))
        case "restartICE":
            return .restartICE(relayOnly: need(raw.relayOnly, "relayOnly"))
        case "reissueWatches":
            return .reissueWatches
        case "teardownPeerConnection":
            return .teardownPeerConnection
        case "clearStoredSession":
            return .clearStoredSession
        case "promptForAccessCode":
            return .promptForAccessCode(reason: need(raw.reason, "reason"))
        case "sendBye":
            return .sendBye(sessionID: need(raw.sessionId, "sessionId"),
                            reason: need(raw.reason, "reason"))
        case "promptForConsent":
            return .promptForConsent(expiresAt: date(need(raw.expiresAtMs, "expiresAtMs")),
                                     promptID: need(raw.promptId, "promptId"),
                                     replacesPrevious: need(raw.replacesPrevious, "replacesPrevious"))
        case "dismissConsentPrompt":
            let name = need(raw.outcome, "outcome")
            guard let outcome = ConsentOutcome(rawValue: name) else {
                preconditionFailure("unknown consent outcome \(name) from the shared core")
            }
            return .dismissConsentPrompt(outcome: outcome)
        default:
            preconditionFailure("unknown action \(raw.action) from the shared core")
        }
    }
}
