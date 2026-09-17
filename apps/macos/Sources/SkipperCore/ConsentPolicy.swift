import CSkipperCore
import Foundation

public struct ConsentLedger: Codable, Equatable, Sendable {

    public var declineTimesMs: [Int64]

    public init(declineTimesMs: [Int64] = []) {
        self.declineTimesMs = declineTimesMs
    }
}

public struct ConsentDecision: Equatable, Sendable {
    public let shouldPrompt: Bool
    public let retryAfterMs: Int64
    public let ledger: ConsentLedger
}

public enum ConsentPolicy {

    private struct Result: Decodable {
        let prompt: Bool
        let retryAfterMs: Int64
        let ledger: ConsentLedger
    }

    public static func admit(_ ledger: ConsentLedger, now: Date = Date()) throws -> ConsentDecision {
        try decide(ledger) { skipper_consent_admit($0.base, $0.count, CoreBoundary.milliseconds(now)) }
    }

    public static func declined(_ ledger: ConsentLedger, now: Date = Date()) throws -> ConsentDecision {
        try decide(ledger) { skipper_consent_declined($0.base, $0.count, CoreBoundary.milliseconds(now)) }
    }

    public static func allowed(_ ledger: ConsentLedger, now: Date = Date()) throws -> ConsentDecision {
        try decide(ledger) { skipper_consent_allowed($0.base, $0.count, CoreBoundary.milliseconds(now)) }
    }

    private static func decide(
        _ ledger: ConsentLedger,
        _ body: (CoreBytes) -> UnsafeMutablePointer<CChar>?
    ) throws -> ConsentDecision {
        let result: Result = try CoreBoundary.callWithJSON(ledger, body)
        return ConsentDecision(shouldPrompt: result.prompt,
                               retryAfterMs: result.retryAfterMs,
                               ledger: result.ledger)
    }
}
