import CSkipperCore
import Foundation

public struct ConsentDecision: Equatable, Sendable {
    public let shouldPrompt: Bool
    public let retryAfterMs: Int64
    public let ledger: GuessLedger
}

/// The host's consent budget (PROTOCOL.md §2.17 Consent), kept in the same
/// ledger as the guess counters: two unallowed prompts per controller key and
/// three per host in any 10 minutes. A prompt is paid for when it opens.
public enum ConsentPolicy {

    private struct Result: Decodable {
        let prompt: Bool
        let retryAfterMs: Int64
        let ledger: GuessLedger
    }

    public static func admit(_ ledger: GuessLedger, now: Date = Date()) throws -> ConsentDecision {
        try decide(ledger) { skipper_consent_admit($0.base, $0.count, CoreBoundary.milliseconds(now)) }
    }

    public static func prompted(_ ledger: GuessLedger, now: Date = Date()) throws -> ConsentDecision {
        try decide(ledger) { skipper_consent_prompted($0.base, $0.count, CoreBoundary.milliseconds(now)) }
    }

    public static func allowed(_ ledger: GuessLedger, now: Date = Date()) throws -> ConsentDecision {
        try decide(ledger) { skipper_consent_allowed($0.base, $0.count, CoreBoundary.milliseconds(now)) }
    }

    private static func decide(
        _ ledger: GuessLedger,
        _ body: (CoreBytes) -> UnsafeMutablePointer<CChar>?
    ) throws -> ConsentDecision {
        let result: Result = try CoreBoundary.callWithJSON(ledger, body)
        return ConsentDecision(shouldPrompt: result.prompt,
                               retryAfterMs: result.retryAfterMs,
                               ledger: result.ledger)
    }
}
