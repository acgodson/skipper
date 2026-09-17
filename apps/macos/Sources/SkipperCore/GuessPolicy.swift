import CSkipperCore
import Foundation

public struct GuessCounter: Codable, Equatable, Sendable {

    public var failures: Int
    public var lastFailureMs: Int64
    public var lockedUntilMs: Int64
    public var failureTimesMs: [Int64]?

    public init(failures: Int = 0, lastFailureMs: Int64 = 0, lockedUntilMs: Int64 = 0,
                failureTimesMs: [Int64]? = nil) {
        self.failures = failures
        self.lastFailureMs = lastFailureMs
        self.lockedUntilMs = lockedUntilMs
        self.failureTimesMs = failureTimesMs
    }
}

/// The host's two counters for one controller: the one keyed on that
/// controller's pubkey, and the host-wide budget stored under `hostKey`.
public struct GuessLedger: Codable, Equatable, Sendable {

    public static let hostKey = "host"

    public var controller: GuessCounter
    public var host: GuessCounter

    public init(controller: GuessCounter? = nil, host: GuessCounter? = nil) {
        self.controller = controller ?? GuessCounter()
        self.host = host ?? GuessCounter()
    }
}

public struct GuessDecision: Equatable, Sendable {
    public let isAllowed: Bool
    public let retryAfterMs: Int64
    public let ledger: GuessLedger

    public var retryAfter: TimeInterval { TimeInterval(retryAfterMs) / 1000 }
}

public enum GuessPolicy {

    private struct Result: Decodable {
        let allowed: Bool
        let retryAfterMs: Int64
        let ledger: GuessLedger
    }

    public static func admit(_ ledger: GuessLedger, now: Date = Date()) throws -> GuessDecision {
        try decide(ledger) { skipper_pake_guess_admit($0.base, $0.count, CoreBoundary.milliseconds(now)) }
    }

    public static func replySent(_ ledger: GuessLedger, now: Date = Date()) throws -> GuessDecision {
        try decide(ledger) { skipper_pake_guess_reply_sent($0.base, $0.count, CoreBoundary.milliseconds(now)) }
    }

    public static func confirmed(_ ledger: GuessLedger, now: Date = Date()) throws -> GuessDecision {
        try decide(ledger) { skipper_pake_guess_confirmed($0.base, $0.count, CoreBoundary.milliseconds(now)) }
    }

    private static func decide(
        _ ledger: GuessLedger,
        _ body: (CoreBytes) -> UnsafeMutablePointer<CChar>?
    ) throws -> GuessDecision {
        let result: Result = try CoreBoundary.callWithJSON(ledger, body)
        return GuessDecision(isAllowed: result.allowed,
                             retryAfterMs: result.retryAfterMs,
                             ledger: result.ledger)
    }
}
