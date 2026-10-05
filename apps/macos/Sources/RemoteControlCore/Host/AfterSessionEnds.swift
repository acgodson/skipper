import Foundation
import SkipperCore

public enum AccessCodeExposure {

    public static let hiddenWhileSessionOpen = "Hidden while a session is active."

    public static func sessionIsOpen(phase: SessionPhase?, captureState: CaptureState?) -> Bool {
        switch phase {
        case .connecting, .awaitingConsent, .live, .reconnecting: return true
        case .idle, .closed, .none: break
        }
        switch captureState {
        case .starting, .running: return true
        case .idle, .failed, .none: return false
        }
    }
}

/// A host action that must not run while a session is live: refreshing the
/// access code, and signing out. It ends the session, cuts it off if it will not
/// close, and only then performs the action.
@MainActor
public struct AfterSessionEnds {

    public var sessionIsOpen: () -> Bool
    public var endSession: () -> Void
    public var forceStop: () -> Void
    public var then: () async throws -> Void
    public var pollInterval: TimeInterval
    public var gracePeriod: TimeInterval

    public init(sessionIsOpen: @escaping () -> Bool,
                endSession: @escaping () -> Void,
                forceStop: @escaping () -> Void,
                then: @escaping () async throws -> Void,
                pollInterval: TimeInterval = 0.05,
                gracePeriod: TimeInterval = 3) {
        self.sessionIsOpen = sessionIsOpen
        self.endSession = endSession
        self.forceStop = forceStop
        self.then = then
        self.pollInterval = pollInterval
        self.gracePeriod = gracePeriod
    }

    public func run() async throws {
        if sessionIsOpen() {
            endSession()
            if !(await waitUntilClosed()) {
                forceStop()
            }
        }
        try await then()
    }

    private func waitUntilClosed() async -> Bool {
        let deadline = Date().addingTimeInterval(gracePeriod)
        while sessionIsOpen() {
            guard Date() < deadline else { return false }
            try? await Task.sleep(nanoseconds: UInt64(pollInterval * 1_000_000_000))
        }
        return true
    }
}
