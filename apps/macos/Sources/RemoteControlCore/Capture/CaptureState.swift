import Foundation

public enum CaptureState: Equatable {
    case idle
    case starting
    case running(width: Int, height: Int, fps: Int)
    case failed(CaptureFailure)

    public var isRunning: Bool {
        if case .running = self { return true }
        return false
    }

    public var needsScreenRecordingPermission: Bool {
        if case .failed(let failure) = self { return failure.isPermissionProblem }
        return false
    }

    public var message: String? {
        switch self {
        case .idle: return nil
        case .starting: return "Starting screen capture\u{2026}"
        case .running(let width, let height, let fps):
            return "Sharing this Mac's screen at \(width)\u{00D7}\(height), up to \(fps) fps."
        case .failed(let failure): return failure.localizedDescription
        }
    }
}

public enum CaptureSourceKind: String, Equatable {
    case screen
    case synthetic

    public static func fromEnvironment(_ env: [String: String] = ProcessInfo.processInfo.environment) -> CaptureSourceKind {
        CaptureSourceKind(rawValue: env["RC_CAPTURE_SOURCE"]?.lowercased() ?? "") ?? .screen
    }
}
