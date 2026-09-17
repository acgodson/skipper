import Foundation

public struct BuildNumber: Comparable, Hashable, CustomStringConvertible, Sendable {

    public let components: [Int]

    public init?(_ raw: String) {
        let parts = raw.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...4).contains(parts.count) else { return nil }
        var values: [Int] = []
        for part in parts {
            guard (1...9).contains(part.count),
                  part.unicodeScalars.allSatisfy({ ("0"..."9").contains($0) }),
                  let value = Int(part) else { return nil }
            values.append(value)
        }
        components = values
    }

    public init(_ version: OperatingSystemVersion) {
        components = [version.majorVersion, version.minorVersion, version.patchVersion]
    }

    public var description: String { components.map(String.init).joined(separator: ".") }

    public var canonical: [Int] {
        var trimmed = components
        while trimmed.count > 1, trimmed.last == 0 { trimmed.removeLast() }
        return trimmed
    }

    public var canonicalKey: String { canonical.map(String.init).joined(separator: ".") }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(canonical)
    }

    private static func padded(_ a: BuildNumber, _ b: BuildNumber) -> ([Int], [Int]) {
        let width = max(a.components.count, b.components.count)
        return (
            a.components + Array(repeating: 0, count: width - a.components.count),
            b.components + Array(repeating: 0, count: width - b.components.count)
        )
    }

    public static func == (lhs: BuildNumber, rhs: BuildNumber) -> Bool {
        let (l, r) = padded(lhs, rhs)
        return l == r
    }

    public static func < (lhs: BuildNumber, rhs: BuildNumber) -> Bool {
        let (l, r) = padded(lhs, rhs)
        return l.lexicographicallyPrecedes(r)
    }

    public static var running: BuildNumber? {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String).flatMap(BuildNumber.init)
    }

    public static func floor(_ builds: BuildNumber?...) -> BuildNumber? {
        builds.compactMap { $0 }.max()
    }
}
