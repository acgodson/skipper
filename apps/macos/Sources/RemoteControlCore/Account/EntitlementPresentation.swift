import Foundation

public enum EntitlementPresentation {

    // MARK: - API.md §4.1 host status line

    public static func statusLine(for entitlement: Entitlement, now: Date = Date()) -> String {
        switch entitlement.status {
        case .trial:
            guard let endsAt = entitlement.trialEndsAt else { return "Trial" }
            return "Trial \u{00B7} ends \(relativeDate(endsAt, from: now))"
        case .active:
            var line = "Active \u{00B7} \(entitlement.tier)"
            if let cents = entitlement.balanceCents {
                line += " \u{00B7} \(moneyString(cents: cents)) balance"
            }
            return line
        case .exhausted:
            return "No balance \u{2014} top up at skipperdesk.app"
        case .unlinked:
            return "Not linked"
        }
    }

    public static func topUpURL(webBaseURL: URL) -> URL {
        webBaseURL.appendingPathComponent("credits")
    }

    public static func moneyString(cents: Int64) -> String {
        let negative = cents < 0
        let magnitude = negative ? -cents : cents
        let dollars = magnitude / 100
        let remainder = magnitude % 100
        return String(format: "%@$%d.%02d", negative ? "-" : "", dollars, remainder)
    }

    private static func relativeDate(_ unixMs: Int64, from now: Date) -> String {
        let date = Date(timeIntervalSince1970: TimeInterval(unixMs) / 1000)
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter.localizedString(for: date, relativeTo: now)
    }

    // MARK: - PROTOCOL.md §7 / API.md §4.3 connect-failure sentences

    public static let busySentence = "That Mac already has a controller connected."

    public static let wrongCodeSentence = "Wrong access code. Check it on the other Mac."

    public static func entitlementSentence(reason: String?, fallback: String) -> String {
        switch reason {
        case "unlinked": return "That Mac isn't linked to a SkipperDesk account yet."
        case "trial_expired": return "That Mac's trial has ended."
        case "no_balance": return "That Mac's account has no balance."
        case "concurrency": return "That account is already in a session on another Mac."
        case "suspended": return "That Mac's account is suspended."
        default: return fallback
        }
    }

    public static func rateLimitedSentence(retryAfterSec: Int) -> String {
        let minutes = max(1, Int((Double(retryAfterSec) / 60).rounded(.up)))
        return "Too many attempts. Try again in \(minutes) min."
    }

    public static func connectFailureSentence(
        code: String,
        reason: String?,
        retryAfterSec: Int?,
        fallback: String
    ) -> String {
        switch code {
        case "busy": return busySentence
        case "auth_failed": return wrongCodeSentence
        case "entitlement": return entitlementSentence(reason: reason, fallback: fallback)
        case "rate_limited": return retryAfterSec.map(rateLimitedSentence) ?? fallback
        default: return fallback
        }
    }

    public static func sentence(for failure: ConnectFailure) -> String {
        switch failure {
        case .busy:
            return connectFailureSentence(
                code: Wire.ErrorCode.busy, reason: nil, retryAfterSec: nil,
                fallback: failure.errorDescription ?? busySentence)
        case .authFailed:
            return connectFailureSentence(
                code: Wire.ByeReason.authFailed, reason: nil, retryAfterSec: nil,
                fallback: wrongCodeSentence)
        case .entitlement(let reason, let message):
            return connectFailureSentence(
                code: Wire.ErrorCode.entitlement, reason: reason, retryAfterSec: nil,
                fallback: message)
        case .rateLimited(let retryAfterSec):
            return connectFailureSentence(
                code: Wire.ErrorCode.rateLimited, reason: nil, retryAfterSec: retryAfterSec,
                fallback: failure.errorDescription ?? "")
        case .other(let code, let message):
            return connectFailureSentence(
                code: code, reason: nil, retryAfterSec: nil,
                fallback: failure.errorDescription ?? message)
        default:
            return failure.errorDescription ?? "Connection failed."
        }
    }
}
