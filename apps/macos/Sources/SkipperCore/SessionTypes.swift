import Foundation

public enum SessionRole: String, Codable, Sendable {
    case host
    case controller

    public var opposite: SessionRole { self == .host ? .controller : .host }
}

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

public enum SessionPhase: Equatable, Sendable {
    case idle
    case connecting
    case awaitingConsent
    case live
    case reconnecting
    case closed(reason: String)

    public var summary: String {
        switch self {
        case .idle: return "Not connected"
        case .connecting: return "Connecting\u{2026}"
        case .awaitingConsent: return "Waiting for you to allow\u{2026}"
        case .live: return "Connected"
        case .reconnecting: return "Reconnecting\u{2026}"
        case .closed(let reason): return "Disconnected (\(reason))"
        }
    }
}

public enum SessionAction: Equatable, Sendable {
    case sendConnectReq(deviceID: String, accessCode: String)
    case sendResume(sessionID: String, sessionToken: String)
    case scheduleResume(afterSec: Int)
    case sendRenew(sessionID: String, sessionToken: String)
    case sendInputReset
    case startPeerConnection(offerer: Bool)
    case restartICE(relayOnly: Bool)
    case reissueWatches
    case teardownPeerConnection
    case clearStoredSession
    case promptForAccessCode(reason: String)
    case sendBye(sessionID: String, reason: String)
    case promptForConsent(expiresAt: Date, promptID: String, replacesPrevious: Bool)
    case dismissConsentPrompt(outcome: ConsentOutcome)
}

public enum ConsentOutcome: String, Equatable, Sendable {
    case allowed
    case declined
    case timedOut
    case cancelled

    public var countsAsDecline: Bool { self != .allowed }
}

public protocol SessionGrantLike {
    var sessionId: String { get }
    var sessionToken: String { get }
    var hostDeviceId: String { get }
    var controllerDeviceId: String { get }
}

public protocol SessionTokenLike {
    var sessionId: String { get }
    var sessionToken: String { get }
}
