import Foundation

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
