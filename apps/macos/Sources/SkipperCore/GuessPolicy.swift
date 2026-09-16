import CSkipperCore
import Foundation

/// What the host remembers about one controller's failed access-code attempts
/// (PROTOCOL.md §2.17).
///
/// The shape is the shared core's, so the value round-trips through the FFI
/// unchanged and can be persisted verbatim by the platform.
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

/// The counter after an operation, and whether this controller may try again.
public struct GuessDecision: Equatable, Sendable {
    public let isAllowed: Bool
    public let retryAfterMs: Int64
    public let counter: GuessCounter

    public var retryAfter: TimeInterval { TimeInterval(retryAfterMs) / 1000 }
}

/// The host's rate limit on access-code guesses, over the shared core.
///
/// Pure, exactly as `skipper_pake_guess_policy_*` is: it owns no clock and no
/// storage. The caller passes the counter it persisted for this controller's
/// public key and stores whichever one comes back.
public enum GuessPolicy {

    private struct Result: Decodable {
        let allowed: Bool
        let retryAfterMs: Int64
        let counter: GuessCounter
    }

    /// May this controller start another exchange?
    public static func check(_ counter: GuessCounter?, now: Date = Date()) throws -> GuessDecision {
        try decide(counter) { json in
            skipper_pake_guess_policy_check(json, milliseconds(now))
        }
    }

    /// The host refused a confirmation, or an exchange was abandoned after step 1.
    public static func recordFailure(_ counter: GuessCounter?, now: Date = Date()) throws -> GuessDecision {
        try decide(counter) { json in
            skipper_pake_guess_policy_record_failure(json, milliseconds(now))
        }
    }

    /// The exchange completed. Clears the counter.
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
