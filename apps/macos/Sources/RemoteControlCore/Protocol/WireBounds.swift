import Foundation

public enum WireBounds {

    public static let normalizedCoordinate: ClosedRange<Double> = -4...4
    public static let scrollDelta: ClosedRange<Double> = -100_000...100_000
    public static let displayScale: ClosedRange<Double> = 0.25...16
    public static let displayDimension: ClosedRange<Int> = 1...32_768
    public static let heartbeat: ClosedRange<Int> = 1...300
    public static let defaultHeartbeatSeconds = 15
    public static let retryAfter: ClosedRange<Int> = 0...86_400
    public static let mediaLineIndex: ClosedRange<Int> = 0...65_535

    public static func heartbeatSeconds(_ value: Int?) -> Int {
        guard let value, heartbeat.contains(value) else { return defaultHeartbeatSeconds }
        return value
    }

    public static func retryAfterSeconds(_ value: Int) -> Int {
        min(max(value, retryAfter.lowerBound), retryAfter.upperBound)
    }

    public static func nanoseconds(_ seconds: TimeInterval) -> UInt64 {
        guard seconds.isFinite, seconds > 0 else { return 0 }
        return UInt64(min(seconds, TimeInterval(retryAfter.upperBound)) * 1_000_000_000)
    }

    public struct OutOfRange: Error, CustomStringConvertible {
        public let field: String
        public var description: String { "\(field) is not finite or is out of range" }
    }

    public static func accepts(_ values: Double..., in range: ClosedRange<Double>) -> Bool {
        values.allSatisfy { $0.isFinite && range.contains($0) }
    }

    public static func check(_ value: Double, in range: ClosedRange<Double>, field: String) throws {
        guard accepts(value, in: range) else { throw OutOfRange(field: field) }
    }

    public static func check(_ value: Int, in range: ClosedRange<Int>, field: String) throws {
        guard range.contains(value) else { throw OutOfRange(field: field) }
    }

    public static func int32(_ value: Double) -> Int32? {
        guard value.isFinite else { return nil }
        let rounded = value.rounded()
        guard rounded >= Double(Int32.min), rounded <= Double(Int32.max) else { return nil }
        return Int32(rounded)
    }

    public static func int(_ value: Double) -> Int? {
        guard value.isFinite else { return nil }
        return Int(exactly: value.rounded())
    }
}

extension KeyedDecodingContainer {
    func decodeBounded(_ key: Key, in range: ClosedRange<Double>) throws -> Double {
        let value = try decode(Double.self, forKey: key)
        try WireBounds.check(value, in: range, field: key.stringValue)
        return value
    }

    func decodeBounded(_ key: Key, in range: ClosedRange<Int>) throws -> Int {
        let value = try decode(Int.self, forKey: key)
        try WireBounds.check(value, in: range, field: key.stringValue)
        return value
    }
}
