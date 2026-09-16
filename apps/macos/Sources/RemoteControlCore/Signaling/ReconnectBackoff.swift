import Foundation

// Defaults (0.5s-15s, jittered) are a protocol-agreed schedule; changing them desyncs both Macs' retry timing.
public struct ReconnectBackoff: Equatable {

    public let minimum: TimeInterval
    public let maximum: TimeInterval
    public let jitterFraction: Double

    private(set) public var attempt: Int = 0

    public init(minimum: TimeInterval = 0.5, maximum: TimeInterval = 15, jitterFraction: Double = 0.25) {
        precondition(minimum > 0 && maximum >= minimum)
        precondition(jitterFraction >= 0 && jitterFraction < 1)
        self.minimum = minimum
        self.maximum = maximum
        self.jitterFraction = jitterFraction
    }

    public func nominalDelay(forAttempt n: Int) -> TimeInterval {
        guard n > 0 else { return minimum }
        let exponent = Double(min(n, 60))
        return Swift.min(maximum, minimum * pow(2.0, exponent))
    }

    public func delay(forAttempt n: Int, random: () -> Double) -> TimeInterval {
        let nominal = nominalDelay(forAttempt: n)
        let factor = 1.0 + jitterFraction * (2.0 * random() - 1.0)
        return Swift.min(maximum, Swift.max(minimum, nominal * factor))
    }

    public mutating func next(random: () -> Double = { Double.random(in: 0..<1) }) -> TimeInterval {
        let d = delay(forAttempt: attempt, random: random)
        attempt += 1
        return d
    }

    public mutating func reset() { attempt = 0 }
}
