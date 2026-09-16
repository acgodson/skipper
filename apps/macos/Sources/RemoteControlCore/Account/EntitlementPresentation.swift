import Foundation

/// Turns server-owned state into the exact sentences the UI shows: the host's
/// `GET /v1/entitlement` answer (API.md §4.1) and a failed `connect_req`
/// (PROTOCOL.md §2.9/§7, API.md §4.3). No policy lives here — every branch
/// renders a value the server already sent; nothing is computed from a
/// threshold, a rate or a clock (API.md §4.2).
///
/// Shared by `HostView` (the Account section's status line) and `AppModel`
/// (the Connect flow's failure text), so the two views never duplicate the
/// same reason-to-sentence mapping.
public enum EntitlementPresentation {

    // MARK: - API.md §4.1 host status line

    /// The one status line the Account section shows once a host is linked.
    /// `unlinked` is not rendered here: that status is already the account's
    /// `.unlinked` state, with its own "Link this Mac" screen.
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

    /// Where the `exhausted` status line's button goes: `<web base>/credits`.
    public static func topUpURL(webBaseURL: URL) -> URL {
        webBaseURL.appendingPathComponent("credits")
    }

    /// Integer cents (API.md §0 "Money": always cents, never a float in logic)
    /// rendered as `$X.XX`. This is the one place that float ever appears, and
    /// only as display text.
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

    /// `reason` is one of API.md §4.3's closed set. An unknown reason renders
    /// `fallback` — the server's own `message` — rather than guessing at one
    /// of the five (API.md §4.2: render what the server said).
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

    /// `retryAfterSec` (PROTOCOL.md §7 `rate_limited`) rendered in whole
    /// minutes, rounded up so the wait is never understated.
    public static func rateLimitedSentence(retryAfterSec: Int) -> String {
        let minutes = max(1, Int((Double(retryAfterSec) / 60).rounded(.up)))
        return "Too many attempts. Try again in \(minutes) min."
    }

    /// The single mapping entry point: a PROTOCOL.md §7 `code` (plus `reason`
    /// and `retryAfterSec` when the code carries them) in, one sentence out.
    /// `fallback` is the existing wording for every code this mapping does not
    /// change (`offline`, `bad_code`, `unknown_device`, `self_connect`, …).
    public static func connectFailureSentence(
        code: String,
        reason: String?,
        retryAfterSec: Int?,
        fallback: String
    ) -> String {
        switch code {
        case "busy": return busySentence
        case "entitlement": return entitlementSentence(reason: reason, fallback: fallback)
        case "rate_limited": return retryAfterSec.map(rateLimitedSentence) ?? fallback
        default: return fallback
        }
    }

    /// Adapts `ConnectFailure` (Signaling/SessionCoordinator.swift) to the
    /// mapping above. The one call `AppModel` needs to make.
    public static func sentence(for failure: ConnectFailure) -> String {
        switch failure {
        case .busy:
            return connectFailureSentence(
                code: Wire.ErrorCode.busy, reason: nil, retryAfterSec: nil,
                fallback: failure.errorDescription ?? busySentence)
        case .rateLimited(let retryAfterSec):
            return connectFailureSentence(
                code: Wire.ErrorCode.rateLimited, reason: nil, retryAfterSec: retryAfterSec,
                fallback: failure.errorDescription ?? "")
        case .other(let code, let message):
            // API.md §4.2: an entitlement fallback renders the server's own
            // `message` verbatim. Any other unrecognised code keeps its
            // existing "message (code)" wording.
            let fallback = code == "entitlement" ? message : (failure.errorDescription ?? message)
            return connectFailureSentence(code: code, reason: nil, retryAfterSec: nil, fallback: fallback)
        default:
            return failure.errorDescription ?? "Connection failed."
        }
    }
}
