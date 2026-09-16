import Foundation
import SkipperCore

public enum SessionState: Equatable {
    case idle
    case connecting
    case connected(sessionID: String)
    case reconnecting
    case failed(String)

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
    case notImplemented
    case invalidDeviceID
    case invalidAccessCode

    public var errorDescription: String? {
        switch self {
        case .notImplemented:
            return "Connecting is not available in this build. The WebRTC transport and signaling client land in Phase 3."
        case .invalidDeviceID:
            return "A Device ID is nine digits, for example 482 719 351."
        case .invalidAccessCode:
            return "An access code is twelve characters, for example K7FM-3Q8P-W2XY."
        }
    }
}

/// The seam the Phase 3 WebRTC + signaling stack plugs into.
@MainActor
public protocol SessionTransport: AnyObject {
    var state: SessionState { get }
    /// Connect as controller to a host.
    func connect(deviceID: String, accessCode: String) async throws
    /// End the current session from either side. Must always be safe to call.
    func disconnect(reason: String)
}

/// STUB. Validates its inputs so the UI's own validation is exercised, then
/// fails loudly with `notImplemented`. It never reports `connected`, so nothing
/// in the UI can mistake this for a working session.
@MainActor
public final class PreviewTransport: SessionTransport, ObservableObject {

    @Published public private(set) var state: SessionState = .idle

    public init() {}

    public func connect(deviceID: String, accessCode: String) async throws {
        guard DeviceID.canonicalize(deviceID) != nil else { throw TransportError.invalidDeviceID }
        guard AccessCode.canonicalize(accessCode) != nil else { throw TransportError.invalidAccessCode }
        state = .connecting
        state = .failed("not implemented")
        throw TransportError.notImplemented
    }

    public func disconnect(reason: String) {
        state = .idle
    }
}
