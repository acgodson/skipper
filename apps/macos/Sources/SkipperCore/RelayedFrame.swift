import CSkipperCore
import Foundation

/// A relayed `sdp`, `ice` or `pake` frame that matched its exact protocol v5
/// schema in the shared core: exact-case keys, no unknown or duplicate keys,
/// every field bounded. The check runs on the bytes as received, before any
/// decoding.
public enum RelayedFrame {

    public static let types: Set<String> = ["sdp", "ice", "pake"]

    private struct Result: Decodable {
        let type: String
    }

    @discardableResult
    public static func check(_ frame: Data) throws -> String {
        let result: Result = try CoreBoundary.withBytes([frame]) { bytes in
            Swift.Result { try CoreBoundary.call { skipper_relayed_check(bytes[0].base, bytes[0].count) } }
        }.get()
        return result.type
    }
}
