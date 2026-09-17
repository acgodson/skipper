import Foundation
import SkipperCore

public enum AccessCodeExposure {

    public static let hiddenWhileSessionOpen = "Hidden while a session is active."

    public static func sessionIsOpen(phase: SessionPhase?, captureState: CaptureState?) -> Bool {
        switch phase {
        case .connecting, .live, .reconnecting: return true
        case .idle, .closed, .none: break
        }
        switch captureState {
        case .starting, .running: return true
        case .idle, .failed, .none: return false
        }
    }
}

@MainActor
public struct AccessCodeRotation {

    public var sessionIsOpen: () -> Bool
    public var endSession: () -> Void
    public var forceStop: () -> Void
    public var rotate: () async throws -> Void
    public var pollInterval: TimeInterval
    public var gracePeriod: TimeInterval

    public init(sessionIsOpen: @escaping () -> Bool,
                endSession: @escaping () -> Void,
                forceStop: @escaping () -> Void,
                rotate: @escaping () async throws -> Void,
                pollInterval: TimeInterval = 0.05,
                gracePeriod: TimeInterval = 3) {
        self.sessionIsOpen = sessionIsOpen
        self.endSession = endSession
        self.forceStop = forceStop
        self.rotate = rotate
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
        try await rotate()
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
