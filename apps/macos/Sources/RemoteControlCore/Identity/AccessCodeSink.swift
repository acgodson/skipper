import Foundation

/// Notified whenever the access code changes, so that a refresh can be pushed
/// outward and the previous code revoked everywhere it is known.
///
/// PHASE 3 will supply a signaling-server-backed implementation: it uploads the
/// Argon2id hash of the new code and the server invalidates the old one, which
/// is what makes `AGENT.md`'s "old access code invalid immediately after refresh"
/// true off-machine as well as on it.
public protocol AccessCodeSink: AnyObject {
    /// Throwing here must leave the caller free to keep the newly stored code:
    /// local storage is authoritative, propagation is best-effort and retried.
    func accessCodeDidChange(deviceID: String, newCode: String) async throws
}

/// STUB. Records calls and does nothing else — there is no server in Phase 2, so
/// a refresh is local-only until the signaling client lands.
public final class PreviewAccessCodeSink: AccessCodeSink {

    public struct Call: Equatable {
        public let deviceID: String
        public let newCode: String
    }

    public private(set) var calls: [Call] = []

    public init() {}

    public func accessCodeDidChange(deviceID: String, newCode: String) async throws {
        // Deliberately does not log `newCode` — no plaintext access-code logging.
        calls.append(Call(deviceID: deviceID, newCode: newCode))
    }
}
