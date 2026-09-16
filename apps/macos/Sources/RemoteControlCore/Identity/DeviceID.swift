import Foundation

public enum DeviceID {

    public static let digitCount = 9

    public static func generateLocal() throws -> String {
        var digits = ""
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
