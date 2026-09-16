import Foundation

/// The reconnect schedule for the signaling socket: exponential from 0.5 s to
/// 15 s, jittered, and never giving up (PLAN.md §2.1).
///
/// Jitter matters for more than politeness here. Both Macs watch the same server;
/// if the server bounces, an unjittered schedule has them retrying in lockstep
/// forever.
public struct ReconnectBackoff: Equatable {

    public let minimum: TimeInterval
    public let maximum: TimeInterval
    /// Fraction of the nominal delay the jitter may move it by, in either
    /// direction. 0.25 means the delay lands in [0.75n, 1.25n] before clamping.
    public let jitterFraction: Double

    private(set) public var attempt: Int = 0

    public init(minimum: TimeInterval = 0.5, maximum: TimeInterval = 15, jitterFraction: Double = 0.25) {
        precondition(minimum > 0 && maximum >= minimum)
        precondition(jitterFraction >= 0 && jitterFraction < 1)
        self.minimum = minimum
        self.maximum = maximum
        self.jitterFraction = jitterFraction
    }

    /// The un-jittered delay for a given attempt: 0.5, 1, 2, 4, 8, 15, 15, …
    public func nominalDelay(forAttempt n: Int) -> TimeInterval {
        guard n > 0 else { return minimum }
        // pow() on a large n overflows to +inf, which min() handles correctly,
        // but capping the exponent keeps the arithmetic finite and obvious.
        let exponent = Double(min(n, 60))
        return Swift.min(maximum, minimum * pow(2.0, exponent))
    }

    /// Jittered delay for an attempt, clamped into `[minimum, maximum]` so the
    /// documented bounds are true of the *actual* delay, not just the nominal one.
    /// `random` returns a value in `[0, 1)`; it is a parameter so the schedule is
    /// testable without statistics.
    public func delay(forAttempt n: Int, random: () -> Double) -> TimeInterval {
        let nominal = nominalDelay(forAttempt: n)
        let factor = 1.0 + jitterFraction * (2.0 * random() - 1.0)
        return Swift.min(maximum, Swift.max(minimum, nominal * factor))
    }

    /// Consumes the next delay and advances the schedule.
    public mutating func next(random: () -> Double = { Double.random(in: 0..<1) }) -> TimeInterval {
        let d = delay(forAttempt: attempt, random: random)
        attempt += 1
        return d
    }

    /// Called after a *successful* connection, so the next outage starts at the
    /// floor again rather than wherever the last one left off.
    public mutating func reset() { attempt = 0 }
}
