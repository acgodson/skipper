import Foundation

/// The shared secret a controller types to reach this host.
///
/// Twelve Crockford base32 symbols = 60 bits of entropy, drawn from
/// `SecureRandom`. It is persisted in the owner-only identity file and never
/// rotates on a timer; only `IdentityStore.refreshAccessCode()` replaces it.
public enum AccessCode {

    public static let length = 12
    public static let groupSize = 4

    public static func generate() throws -> String {
        // 12 symbols x 5 bits = 60 bits; 8 bytes covers it with 4 bits discarded.
        let raw = try SecureRandom.bytes(8)
        let encoded = CrockfordBase32.encode(raw)
        precondition(encoded.count >= length)
        return String(encoded.prefix(length))
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
    /// returns the canonical form, or nil when it cannot be a valid code.
    public static func canonicalize(_ input: String) -> String? {
        let compact = CrockfordBase32.normalize(input)
        guard compact.count == length, CrockfordBase32.isValid(compact) else { return nil }
        return compact
    }
}

/// The public, permanent identifier for a machine: nine digits, shown as
/// `482 719 351`.
public enum DeviceID {

    public static let digitCount = 9

    /// Phase 2 mints this locally so the app is self-contained.
    ///
    /// SEAM FOR PHASE 3: the signaling server is the authority on Device IDs and
    /// will assign one at first `hello`. `IdentityStore.adoptServerAssignedDeviceID(_:)`
    /// is the entry point that replaces this locally generated value.
    public static func generateLocal() throws -> String {
        var digits = ""
        // First digit 1-9 so the ID always renders as nine characters.
        digits.append(String(try SecureRandom.uniform(9) + 1))
        for _ in 1..<digitCount {
            digits.append(String(try SecureRandom.uniform(10)))
        }
        return digits
    }

    public static func formatted(_ id: String) -> String {
        let digits = id.filter(\.isNumber)
        guard digits.count == digitCount else { return id }
        return stride(from: 0, to: digits.count, by: 3).map { offset -> String in
            let start = digits.index(digits.startIndex, offsetBy: offset)
            let end = digits.index(start, offsetBy: 3)
            return String(digits[start..<end])
        }.joined(separator: " ")
    }

    public static func canonicalize(_ input: String) -> String? {
        let digits = input.filter(\.isNumber)
        return digits.count == digitCount ? digits : nil
    }
}
