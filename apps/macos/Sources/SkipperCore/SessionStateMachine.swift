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

    public var rememberedAccessCode: String? {
        get { storedRememberedAccessCode }
        set { _ = call { skipper_session_set_remembered_access_code(handle, newValue) } }
    }
    private var storedRememberedAccessCode: String?

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
        call { skipper_session_connect_requested(handle, deviceID, accessCode, remember) }
    }

    @discardableResult
    public func sessionGranted(_ grant: SessionGrantLike, now: Date = Date()) -> [SessionAction] {
        call {
            skipper_session_granted(handle, grant.sessionId, grant.sessionToken,
                                    grant.hostDeviceId, grant.controllerDeviceId,
                                    Self.milliseconds(now))
        }
    }

    public func connectFailed(code: String) -> [SessionAction] {
        call { skipper_session_connect_failed(handle, code) }
    }

    // MARK: - Signaling transitions (PROTOCOL.md §4.3)

    public func signalingLost() -> [SessionAction] {
        call { skipper_session_signaling_lost(handle) }
    }

    public func signalingAuthenticated(activeSessionID: String?) -> [SessionAction] {
        call { skipper_session_signaling_authenticated(handle, activeSessionID) }
    }

    public func resumeSucceeded(_ ok: SessionTokenLike, now: Date = Date()) -> [SessionAction] {
        call {
            skipper_session_resume_succeeded(handle, ok.sessionId, ok.sessionToken,
                                             Self.milliseconds(now))
        }
    }

    public func resumeFailed(code: String, retryAfterSec: Int) -> [SessionAction] {
        call { skipper_session_resume_failed(handle, code, Int32(clamping: retryAfterSec)) }
    }

    public func renewSucceeded(_ ok: SessionTokenLike, now: Date = Date()) {
        _ = call {
            skipper_session_renew_succeeded(handle, ok.sessionId, ok.sessionToken,
                                            Self.milliseconds(now))
        }
    }

    public func renewFailed(code: String, now: Date = Date()) -> [SessionAction] {
        call { skipper_session_renew_failed(handle, code) }
    }

    // MARK: - ICE transitions (PLAN.md §2.1)

    public func iceStateChanged(to newState: ICELinkState, now: Date = Date()) -> [SessionAction] {
        call { skipper_session_ice_state_changed(handle, newState.rawValue, Self.milliseconds(now)) }
    }

    public func tick(now: Date = Date()) -> [SessionAction] {
        call { skipper_session_tick(handle, Self.milliseconds(now)) }
    }

    // MARK: - Endings

    public func closeLocally(reason: String) -> [SessionAction] {
        call { skipper_session_close_locally(handle, reason) }
    }

    public func userEnded(reason: String = "user_ended") -> [SessionAction] {
        call { skipper_session_user_ended(handle, reason) }
    }

    // MARK: - Boundary

    private static func milliseconds(_ date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 * 1000).rounded())
    }

    private static func milliseconds(_ interval: TimeInterval) -> Int64 {
        Int64((interval * 1000).rounded())
    }

    private func call(_ body: () -> UnsafeMutablePointer<CChar>?) -> [SessionAction] {
        guard let raw = body() else {
            preconditionFailure("the shared core could not allocate a result")
        }
        defer { skipper_string_free(raw) }
        let data = Data(bytes: raw, count: strlen(raw))
        guard let response = try? JSONDecoder().decode(CoreResponse.self, from: data) else {
            preconditionFailure("the shared core returned an undecodable result")
        }
        guard response.ok, let state = response.state else {
            preconditionFailure("the shared core rejected a call: \(response.error ?? "unknown")")
        }
        apply(state)
        return (response.actions ?? []).map(Self.action)
    }

    private func apply(_ state: CoreState) {
        role = SessionRole(rawValue: state.role) ?? role
        switch state.phase {
        case "idle": phase = .idle
        case "connecting": phase = .connecting
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
        default:
            preconditionFailure("unknown action \(raw.action) from the shared core")
        }
    }
}
