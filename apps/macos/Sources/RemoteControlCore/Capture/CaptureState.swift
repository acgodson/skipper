import Foundation

/// What the host's capture pipeline is doing, in terms the UI can show without
/// interpreting an error object.
public enum CaptureState: Equatable {
    case idle
    case starting
    case running(width: Int, height: Int, fps: Int)
    case failed(CaptureFailure)

    public var isRunning: Bool {
        if case .running = self { return true }
        return false
    }

    /// True when the *only* thing wrong is the Screen Recording grant. The UI
    /// shows the deep link for this and nothing else.
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

/// Which frame producer the host uses.
///
/// `synthetic` exists for `scripts/test-media.sh` only: a headless CLI process
/// cannot hold a Screen Recording grant (TCC attributes it to the terminal), so
/// the media integration test drives a generated pattern through the identical
/// encode/transport/decode path. It is opt-in through `RC_CAPTURE_SOURCE` and is
/// never selected automatically — a host that cannot capture must say so, not
/// quietly show the controller a test card.
public enum CaptureSourceKind: String, Equatable {
    case screen
    case synthetic

    public static func fromEnvironment(_ env: [String: String] = ProcessInfo.processInfo.environment) -> CaptureSourceKind {
        CaptureSourceKind(rawValue: env["RC_CAPTURE_SOURCE"]?.lowercased() ?? "") ?? .screen
    }
}
