import CSkipperCore
import Foundation

public struct GuessCounter: Codable, Equatable, Sendable {

    public var failures: Int
    public var lastFailureMs: Int64
    public var lockedUntilMs: Int64

    public init(failures: Int = 0, lastFailureMs: Int64 = 0, lockedUntilMs: Int64 = 0) {
        self.failures = failures
        self.lastFailureMs = lastFailureMs
        self.lockedUntilMs = lockedUntilMs
    }
}

public struct GuessDecision: Equatable, Sendable {
    public let isAllowed: Bool
    public let retryAfterMs: Int64
    public let counter: GuessCounter

    public var retryAfter: TimeInterval { TimeInterval(retryAfterMs) / 1000 }
}

public enum GuessPolicy {

    private struct Result: Decodable {
        let allowed: Bool
        let retryAfterMs: Int64
        let counter: GuessCounter
    }

    public static func check(_ counter: GuessCounter?, now: Date = Date()) throws -> GuessDecision {
        try decide(counter) { json in
            skipper_pake_guess_policy_check(json, milliseconds(now))
        }
    }

    public static func recordFailure(_ counter: GuessCounter?, now: Date = Date()) throws -> GuessDecision {
        try decide(counter) { json in
            skipper_pake_guess_policy_record_failure(json, milliseconds(now))
        }
    }

    public static func recordSuccess(_ counter: GuessCounter?) throws -> GuessDecision {
        try decide(counter) { json in
            skipper_pake_guess_policy_record_success(json)
        }
    }

    private static func decide(
        _ counter: GuessCounter?,
        _ body: (String?) -> UnsafeMutablePointer<CChar>?
    ) throws -> GuessDecision {
        let json = try counter.map { try encoded($0) }
        let result: Result = try CoreBoundary.call { body(json) }
        return GuessDecision(isAllowed: result.allowed,
                             retryAfterMs: result.retryAfterMs,
                             counter: result.counter)
    }

    private static func encoded(_ counter: GuessCounter) throws -> String {
        let data = try JSONEncoder().encode(counter)
        guard let text = String(data: data, encoding: .utf8) else {
            throw SkipperCoreError("the guess counter could not be encoded")
        }
        return text
    }

    private static func milliseconds(_ date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 * 1000).rounded())
    }
}
