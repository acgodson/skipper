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
    let reason: String?
}

private struct CoreState: Decodable {
    let role: String
    let phase: String
    let closedReason: String?
    let hasSession: Bool
    let signalingUp: Bool
    let resumeInFlight: Bool
    let isOfferer: Bool
    let iceState: String
    let sessionId: String?
    let sessionToken: String?
    let peerDeviceId: String?
    let rememberedAccessCode: String?
    let serverAdvertisedSessionId: String?
}

/// PROTOCOL.md §4 as executable code — a thin Swift skin over the shared Rust
/// core (`core/crates/rc-session`) reached through `skipper_core.h`.
///
/// There is exactly one implementation of these rules in the product, and it is
/// not this file: everything here marshals arguments in and decodes the actions
/// and the state snapshot back out. The shared vectors in
/// `protocol/vectors/session-scenarios.json` are executed through this class, so
/// they prove the FFI path and not only the Rust one.
///
/// Like the machine it wraps it performs no I/O and holds no timers: the owner
/// calls `tick(now:)` and the core decides when the ICE-restart delay and the
/// failure grace have elapsed.
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
    /// The newest token. Rotated on every `resume_ok` / `renew_ok`; PROTOCOL.md
    /// §4.4 says losing it means losing the resume path.
    public private(set) var sessionToken: String?
    public private(set) var peerDeviceID: String?
    public private(set) var signalingUp = false
    public private(set) var iceState: ICELinkState = .new
    /// PROTOCOL.md §4.4: "Clients must not have two `resume`s in flight."
    public private(set) var resumeInFlight = false
    public private(set) var hasSession = false
    /// The controller offers by default, both for the first negotiation
    /// (PROTOCOL.md §2.9) and for ICE restarts (§4.3 step 4).
    public private(set) var isOfferer = false
    public private(set) var serverAdvertisedSessionID: String?

    /// The access code the controller may silently reuse. Present only when the
    /// user chose Remember; without it a dead session must prompt.
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

    /// The user pressed Connect. Only legal from `idle`/`closed`; a client must
    /// never `connect_req` for a session it believes is alive (§4.4).
    public func connectRequested(deviceID: String, accessCode: String, remember: Bool) -> [SessionAction] {
        call { skipper_session_connect_requested(handle, deviceID, accessCode, remember) }
    }

    /// `connect_ok` (controller) or `session_start` (host).
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

    /// Step 1: the control plane died. **Nothing is torn down.** Media over an
    /// established WebRTC path keeps flowing; the UI only says "Reconnecting…"
    /// if the media path is also down.
    public func signalingLost() -> [SessionAction] {
        call { skipper_session_signaling_lost(handle) }
    }

    /// Step 3: the socket is back and authenticated.
    public func signalingAuthenticated(activeSessionID: String?) -> [SessionAction] {
        call { skipper_session_signaling_authenticated(handle, activeSessionID) }
    }

    /// Step 4. Token rotation, watch re-issue, `input_reset`, and an ICE restart
    /// if the media path is not already up.
    public func resumeSucceeded(_ ok: SessionTokenLike, now: Date = Date()) -> [SessionAction] {
        call {
            skipper_session_resume_succeeded(handle, ok.sessionId, ok.sessionToken,
                                             Self.milliseconds(now))
        }
    }

    /// Steps 5 and 6, plus the rule this project adds on top of PROTOCOL.md: a
    /// controller holding a remembered code re-`connect_req`s silently;
    /// prompting is only correct when there is no such code.
    public func resumeFailed(code: String, retryAfterSec: Int) -> [SessionAction] {
        call { skipper_session_resume_failed(handle, code, Int32(clamping: retryAfterSec)) }
    }

    /// `renew_ok` — token rotated, same rules as resume.
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

    /// Drives the time-based rules. Call at least once a second.
    public func tick(now: Date = Date()) -> [SessionAction] {
        call { skipper_session_tick(handle, Self.milliseconds(now)) }
    }

    // MARK: - Endings

    /// The peer or the server said `bye`, or the local user ended it.
    public func closeLocally(reason: String) -> [SessionAction] {
        call { skipper_session_close_locally(handle, reason) }
    }

    /// The local user pressed End Session / Disconnect.
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
            return .restartICE
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
