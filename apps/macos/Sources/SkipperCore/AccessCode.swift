import CSkipperCore
import Foundation

/// The shared secret a controller types to reach this host.
///
/// Twelve Crockford base32 symbols = 60 bits. The generator itself lives in the
/// shared core (`core/crates/rc-identity`, `skipper_access_code_generate`) so
/// that the Mac, Windows and the PAKE all agree on what a code is; this type
/// only marshals and formats.
public enum AccessCode {

    public static let length = 12
    public static let groupSize = 4

    private struct Generated: Decodable {
        let accessCode: String
    }

    public static func generate() throws -> String {
        let generated: Generated = try CoreBoundary.call { skipper_access_code_generate() }
        guard canonicalize(generated.accessCode) != nil else {
            throw SkipperCoreError("the shared core produced \(generated.accessCode)")
        }
        return generated.accessCode
    }

    /// `K7FM3Q8PW2XY` -> `K7FM-3Q8P-W2XY`. Display only; storage keeps it ungrouped.
    public static func formatted(_ code: String) -> String {
        let compact = CrockfordBase32.normalize(code)
        var groups: [String] = []
        var index = compact.startIndex
        while index < compact.endIndex {
            let end = compact.index(index, offsetBy: groupSize, limitedBy: compact.endIndex) ?? compact.endIndex
            groups.append(String(compact[index..<end]))
            index = end
        }
        return groups.joined(separator: "-")
    }

    /// Accepts what a user actually types (dashes, lowercase, O for 0) and
    /// returns the canonical form — the exact string the PAKE uses as its
    /// password — or nil when it cannot be a valid code.
    public static func canonicalize(_ input: String) -> String? {
        let compact = CrockfordBase32.normalize(input)
        guard compact.count == length, CrockfordBase32.isValid(compact) else { return nil }
        return compact
    }
}
