import Foundation

/// Notified whenever this Mac's access code changes, so the refresh can be
/// pushed outward.
///
/// The new code is deliberately **not** a parameter. In v2 the server stores
/// nothing about any access code (PROTOCOL.md §2.3): what propagates is
/// `refresh_code`, which bumps the device's epoch and kills every live session
/// and token. The code stays on this Mac, and every controller that remembered
/// the old one simply fails the §2.17 exchange from now on.
public protocol AccessCodeSink: AnyObject {
    /// Throwing here must leave the caller free to keep the newly stored code:
    /// local storage is authoritative, propagation is best-effort and retried.
    func accessCodeDidChange(deviceID: String) async throws
}

/// Records the calls and does nothing else, so a test can assert that a refresh
/// was propagated without a signaling server.
public final class PreviewAccessCodeSink: AccessCodeSink {

    public private(set) var refreshedDeviceIDs: [String] = []

    public init() {}

    public func accessCodeDidChange(deviceID: String) async throws {
        refreshedDeviceIDs.append(deviceID)
    }
}
