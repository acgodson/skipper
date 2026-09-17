import Foundation
import SkipperCore

public enum SessionState: Equatable {
    case idle
    case connecting
    case connected(sessionID: String)
    case reconnecting
    case failed(String)

    public init(phase: SessionPhase, sessionID: String?) {
        switch phase {
        case .idle: self = .idle
        case .connecting, .awaitingConsent: self = .connecting
        case .live: self = sessionID.map { .connected(sessionID: $0) } ?? .connecting
        case .reconnecting: self = .reconnecting
        case .closed(let reason): self = reason == Wire.ByeReason.userEnded ? .idle : .failed(reason)
        }
    }

    public var isActive: Bool {
        switch self {
        case .connected, .reconnecting: return true
        default: return false
        }
    }

    public var summary: String {
        switch self {
        case .idle: return "Not connected"
        case .connecting: return "Connecting\u{2026}"
        case .connected: return "Connected"
        case .reconnecting: return "Reconnecting\u{2026}"
        case .failed(let reason): return "Failed: \(reason)"
        }
    }
}

public enum TransportError: Error, LocalizedError {
    case invalidDeviceID
    case invalidAccessCode

    public var errorDescription: String? {
        switch self {
        case .invalidDeviceID:
            return "A Device ID is nine digits, for example 482 719 351."
        case .invalidAccessCode:
            return "An access code is twelve characters, for example K7FM-3Q8P-W2XY."
        }
    }
}

@MainActor
public protocol SessionTransport: AnyObject {
    var state: SessionState { get }
    func connect(deviceID: String, accessCode: String) async throws
    func disconnect(reason: String)
}
