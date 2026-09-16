import Foundation

/// Which side of the session this machine is. Lives here rather than in the
/// app's `Wire` namespace because the shared core owns it; `Wire.Role` is a
/// typealias onto this.
public enum SessionRole: String, Codable, Sendable {
    case host
    case controller

    public var opposite: SessionRole { self == .host ? .controller : .host }
}

/// ICE connection states we care about, decoupled from libwebrtc's enum so the
/// session rules can be tested without a peer connection.
public enum ICELinkState: String, Equatable, Sendable {
    case new
    case checking
    case connected
    case completed
    case disconnected
    case failed
    case closed

    public var isUp: Bool { self == .connected || self == .completed }
}

/// What the UI shows. `reconnecting` is deliberately distinct from `closed`:
/// PLAN.md §2.1 says a wobble must never look like a dead session.
public enum SessionPhase: Equatable, Sendable {
    case idle
    case connecting
    case live
    case reconnecting
    case closed(reason: String)

    public var summary: String {
        switch self {
        case .idle: return "Not connected"
        case .connecting: return "Connecting\u{2026}"
        case .live: return "Connected"
        case .reconnecting: return "Reconnecting\u{2026}"
        case .closed(let reason): return "Disconnected (\(reason))"
        }
    }
}

/// The side effects the machine asks its owner to perform. Returning them rather
/// than performing them is what makes PROTOCOL.md §4 testable without a network.
public enum SessionAction: Equatable, Sendable {
    case sendConnectReq(deviceID: String, accessCode: String)
    case sendResume(sessionID: String, sessionToken: String)
    /// Retry `resume` after a server-mandated delay (§4.3 step 6).
    case scheduleResume(afterSec: Int)
    case sendRenew(sessionID: String, sessionToken: String)
    /// PROTOCOL.md §4.4: after every resume and every detected disconnect.
    case sendInputReset
    case startPeerConnection(offerer: Bool)
    case restartICE
    case reissueWatches
    case teardownPeerConnection
    case clearStoredSession
    /// The ONLY action that may put the access-code prompt back on screen
    /// (§4.3 step 5).
    case promptForAccessCode(reason: String)
    case sendBye(sessionID: String, reason: String)
}

/// The fields of `connect_ok` / `session_start` the machine needs. The app's
/// `SessionGrantPayload` conforms, so the wire types stay in the app layer.
public protocol SessionGrantLike {
    var sessionId: String { get }
    var sessionToken: String { get }
    var hostDeviceId: String { get }
    var controllerDeviceId: String { get }
}

/// The fields of `resume_ok` / `renew_ok` the machine needs.
public protocol SessionTokenLike {
    var sessionId: String { get }
    var sessionToken: String { get }
}
