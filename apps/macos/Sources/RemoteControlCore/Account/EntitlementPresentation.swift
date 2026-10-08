import Foundation

public enum EntitlementPresentation {

    // MARK: - API.md §4.1 host status line

    public static func statusLine(for entitlement: Entitlement, now: Date = Date()) -> String {
        switch entitlement.status {
        case .trial:
            guard let minutes = entitlement.minutesRemaining else { return "Trial" }
            return "Trial \u{00B7} \(hostingTime(minutes: minutes)) left"
        case .active:
            guard let cents = entitlement.balanceCents else { return "Active" }
            guard let minutes = entitlement.minutesRemaining else {
                return "\(moneyString(cents: cents)) left"
            }
            return "\(moneyString(cents: cents)) left \u{00B7} \(hostingTime(minutes: minutes))"
        case .exhausted:
            return "No hosting time left. This Mac can still connect to other Macs."
        case .unlinked:
            return "Not signed in"
        }
    }

    /// Hosting time in whole hours, rounded down so the figure is never a promise the
    /// balance cannot keep. The server does the division (API.md §4.2); this only reads it.
    public static func hostingTime(minutes: Int) -> String {
        switch max(0, minutes) / 60 {
        case 0: return "less than an hour"
        case 1: return "about 1 hour"
        case let hours: return "about \(hours) hours"
        }
    }

    // MARK: - API.md §4.4 quality ceiling

    /// Why a quality mode is not offered, or nil when every mode is. Courtesy only: the
    /// host enforces the ceiling whatever a controller's menu shows (API.md §4.4). The
    /// sentence names what to do and never the mechanism — DESIGN §4 rules 2 and 8, so no
    /// "entitlement", no "tier", no bitrate.
    public static func qualityUnavailableNote(ceiling: QualityWireMode) -> String? {
        guard ceiling.rank < QualityWireMode.sharp.rank else { return nil }
        return "The sharpest picture is available once you add credit."
    }

    /// Where builds already in testers' hands send "Add credit…" and the `exhausted` button.
    /// No current affordance opens it — paid top-ups are not open, so the app no longer offers
    /// one — but the path stays alive on the website and lands on the account page.
    public static func topUpURL(webBaseURL: URL) -> URL {
        webBaseURL.appendingPathComponent("credits")
    }

    public static func accountURL(webBaseURL: URL) -> URL {
        webBaseURL.appendingPathComponent("account")
    }

    public static func moneyString(cents: Int64) -> String {
        let negative = cents < 0
        let magnitude = negative ? -cents : cents
        let dollars = magnitude / 100
        let remainder = magnitude % 100
        return String(format: "%@$%d.%02d", negative ? "-" : "", dollars, remainder)
    }

    // MARK: - PROTOCOL.md §7 / API.md §4.3 connect-failure sentences

    public static let busySentence = "That Mac already has a controller connected."

    public static let wrongCodeSentence = "Wrong access code. Check it on the other Mac."

    public static let declinedSentence = "The other Mac declined the connection."

    public static let noAnswerSentence = "The other Mac did not answer in time. Ask someone there to allow the connection, or turn on unattended access on that Mac."

    public static let awaitingAcceptanceSentence = "Waiting for the other Mac to accept\u{2026}"

    public static func entitlementSentence(reason: String?, fallback: String) -> String {
        switch reason {
        case "unlinked": return "That Mac isn't signed in to SkipperDesk yet."
        case "trial_expired": return "That Mac's trial has ended."
        case "no_balance": return "That Mac has no credit left."
        case "concurrency": return "That account is already in a session on another Mac."
        case "suspended": return "That Mac's account is suspended."
        default: return fallback
        }
    }

    public static func rateLimitedSentence(retryAfterSec: Int) -> String {
        guard retryAfterSec >= 60 else { return "Too many attempts. Try again in a few seconds." }
        let minutes = Int((Double(retryAfterSec) / 60).rounded(.up))
        return "Too many attempts. Try again in \(minutes) min."
    }

    public static let unavailableSentence = "SkipperDesk is temporarily unavailable. Try again in a moment."

    public static func connectFailureSentence(
        code: String,
        reason: String?,
        retryAfterSec: Int?,
        fallback: String
    ) -> String {
        switch code {
        case "busy": return busySentence
        case "auth_failed": return wrongCodeSentence
        case Wire.ByeReason.declined: return declinedSentence
        case Wire.ByeReason.timeout: return noAnswerSentence
        case "entitlement": return entitlementSentence(reason: reason, fallback: fallback)
        case "rate_limited": return retryAfterSec.map(rateLimitedSentence) ?? fallback
        case Wire.ErrorCode.unavailable: return unavailableSentence
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
        case .declined, .noAnswer:
            return connectFailureSentence(
                code: failure.code, reason: nil, retryAfterSec: nil,
                fallback: failure.errorDescription ?? "")
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
