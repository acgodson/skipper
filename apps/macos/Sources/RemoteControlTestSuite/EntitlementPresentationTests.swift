import Foundation
import RCTestKit
import RemoteControlCore

private func entitlement(
    status: String, tier: String, balanceCents: Int64? = nil, trialEndsAt: Int64? = nil
) throws -> Entitlement {
    var fields = ["\"status\":\"\(status)\"", "\"tier\":\"\(tier)\""]
    if let balanceCents { fields.append("\"balanceCents\":\(balanceCents)") }
    if let trialEndsAt { fields.append("\"trialEndsAt\":\(trialEndsAt)") }
    let json = "{\(fields.joined(separator: ","))}"
    return try JSONDecoder().decode(Entitlement.self, from: Data(json.utf8))
}

public let entitlementPresentationSuite = TestSuite("Entitlement presentation (API.md §4, PROTOCOL.md §7)", [

    // MARK: - API.md §4.3 reason -> sentence

    TestCase("each closed-set reason renders its own sentence, never the fallback") {
        try expectEqual(
            EntitlementPresentation.entitlementSentence(reason: "unlinked", fallback: "fallback"),
            "That Mac isn't signed in to SkipperDesk yet.")
        try expectEqual(
            EntitlementPresentation.entitlementSentence(reason: "trial_expired", fallback: "fallback"),
            "That Mac's trial has ended.")
        try expectEqual(
            EntitlementPresentation.entitlementSentence(reason: "no_balance", fallback: "fallback"),
            "That Mac's account has no balance.")
        try expectEqual(
            EntitlementPresentation.entitlementSentence(reason: "concurrency", fallback: "fallback"),
            "That account is already in a session on another Mac.")
        try expectEqual(
            EntitlementPresentation.entitlementSentence(reason: "suspended", fallback: "fallback"),
            "That Mac's account is suspended.")
    },

    TestCase("an unknown or missing reason falls back to the server's own message") {
        try expectEqual(
            EntitlementPresentation.entitlementSentence(reason: "some_future_reason", fallback: "server said this"),
            "server said this")
        try expectEqual(
            EntitlementPresentation.entitlementSentence(reason: nil, fallback: "server said this"),
            "server said this")
    },

    // MARK: - Cents -> string (API.md §0 "Money": integer cents, never a float in logic)

    TestCase("cents render as $X.XX, including zero, negative and no leading-zero drops") {
        try expectEqual(EntitlementPresentation.moneyString(cents: 0), "$0.00")
        try expectEqual(EntitlementPresentation.moneyString(cents: 5), "$0.05")
        try expectEqual(EntitlementPresentation.moneyString(cents: 1234), "$12.34")
        try expectEqual(EntitlementPresentation.moneyString(cents: 100), "$1.00")
        try expectEqual(EntitlementPresentation.moneyString(cents: -250), "-$2.50")
    },

    // MARK: - PROTOCOL.md §7 connect-failure code -> sentence

    TestCase("busy renders the one-controller-at-a-time sentence") {
        try expectEqual(
            EntitlementPresentation.connectFailureSentence(
                code: "busy", reason: nil, retryAfterSec: nil, fallback: "old wording"),
            EntitlementPresentation.busySentence)
    },

    TestCase("rate_limited renders whole minutes, rounded up, never understating the wait") {
        try expectEqual(
            EntitlementPresentation.connectFailureSentence(
                code: "rate_limited", reason: nil, retryAfterSec: 90, fallback: "old wording"),
            "Too many attempts. Try again in 2 min.")
        try expectEqual(
            EntitlementPresentation.connectFailureSentence(
                code: "rate_limited", reason: nil, retryAfterSec: 30, fallback: "old wording"),
            "Too many attempts. Try again in a few seconds.")
        try expectEqual(
            EntitlementPresentation.connectFailureSentence(
                code: "rate_limited", reason: nil, retryAfterSec: nil, fallback: "old wording"),
            "old wording")
    },

    TestCase("unavailable never blames the user or leaks the server's wording") {
        try expectEqual(
            EntitlementPresentation.connectFailureSentence(
                code: "unavailable", reason: nil, retryAfterSec: 5, fallback: "registry timeout"),
            EntitlementPresentation.unavailableSentence)
    },

    TestCase("entitlement delegates to the reason mapping") {
        try expectEqual(
            EntitlementPresentation.connectFailureSentence(
                code: "entitlement", reason: "no_balance", retryAfterSec: nil, fallback: "old wording"),
            "That Mac's account has no balance.")
        try expectEqual(
            EntitlementPresentation.connectFailureSentence(
                code: "entitlement", reason: nil, retryAfterSec: nil, fallback: "old wording"),
            "old wording")
    },

    TestCase("offline and any other code keep the existing generic wording") {
        try expectEqual(
            EntitlementPresentation.connectFailureSentence(
                code: "offline", reason: nil, retryAfterSec: nil, fallback: "That Mac is offline."),
            "That Mac is offline.")
        try expectEqual(
            EntitlementPresentation.connectFailureSentence(
                code: "auth_failed", reason: nil, retryAfterSec: nil, fallback: "ignored"),
            EntitlementPresentation.wrongCodeSentence,
            "the one failure the user can fix by typing says so plainly")
    },

    // MARK: - ConnectFailure adapter

    TestCase("the ConnectFailure adapter reaches the same sentences as the raw mapping") {
        try expectEqual(EntitlementPresentation.sentence(for: .busy), EntitlementPresentation.busySentence)
        try expectEqual(
            EntitlementPresentation.sentence(for: .rateLimited(retryAfterSec: 120)),
            "Too many attempts. Try again in 2 min.")
        try expectEqual(
            EntitlementPresentation.sentence(for: .offline),
            ConnectFailure.offline.errorDescription ?? "")
        try expectEqual(
            EntitlementPresentation.sentence(for: .entitlement(reason: "trial_expired", message: "m")),
            "That Mac's trial has ended.")
        try expectEqual(
            EntitlementPresentation.sentence(for: .entitlement(reason: "brand_new", message: "trial has ended")),
            "trial has ended")
        try expectEqual(
            EntitlementPresentation.sentence(for: .authFailed),
            EntitlementPresentation.wrongCodeSentence)
    },

    // MARK: - Host consent (PROTOCOL.md §2.17 Consent)

    TestCase("a declined or unanswered connection says so, never the raw reason") {
        try expectEqual(
            EntitlementPresentation.connectFailureSentence(
                code: Wire.ByeReason.declined, reason: nil, retryAfterSec: nil, fallback: "declined"),
            "The other Mac declined the connection.")
        try expectEqual(EntitlementPresentation.sentence(for: .declined),
                        "The other Mac declined the connection.")
        try expectEqual(EntitlementPresentation.sentence(for: .noAnswer),
                        EntitlementPresentation.noAnswerSentence)
        try expectFalse(EntitlementPresentation.noAnswerSentence.contains("timeout"))
    },

    TestCase("a bye{declined} read off the wire becomes the declined failure") {
        let wire = WireError.protocolError(code: Wire.ByeReason.declined, message: "the session ended",
                                           retryAfterSec: 0)
        try expectEqual(ConnectFailure(wire), .declined)
        try expectEqual(ConnectFailure.declined.code, "declined")
        try expectEqual(EntitlementPresentation.sentence(for: ConnectFailure(wire)),
                        EntitlementPresentation.declinedSentence)
        let timeout = WireError.protocolError(code: Wire.ByeReason.timeout, message: "m", retryAfterSec: 0)
        try expectEqual(ConnectFailure(timeout), .noAnswer)
    },

    TestCase("the consent prompt names a known controller and falls back to another Mac") {
        let expires = Date(timeIntervalSince1970: 1_756_000_030)
        let known = ConsentRequest(promptID: "p", controllerLabel: "481 930 275",
                                   controllerDeviceID: "481930275",
                                   controllerFingerprint: "1A2B 3C4D 5E6F 7081", expiresAt: expires)
        try expectEqual(known.title, "Allow 481 930 275 to control this Mac?")
        try expectEqual(known.deviceIDLine, "Device ID 481 930 275")
        try expectEqual(known.fingerprintLine, "Fingerprint 1A2B 3C4D 5E6F 7081")
        try expectNil(known.notice)
        for label in [nil, "", "   "] as [String?] {
            let unknown = ConsentRequest(promptID: "p", controllerLabel: label,
                                         controllerDeviceID: nil, expiresAt: expires)
            try expectEqual(unknown.title, "Allow another Mac to control this Mac?")
            try expectNil(unknown.deviceIDLine)
        }
        let replacing = ConsentRequest(promptID: "p", controllerLabel: nil, controllerDeviceID: nil,
                                       replacesPrevious: true, expiresAt: expires)
        try expectEqual(replacing.notice, "A different request replaced the previous one.")
    },

    TestCase("the consent countdown rounds up, pluralises, and never goes negative") {
        let expires = Date(timeIntervalSince1970: 1_756_000_030)
        let request = ConsentRequest(promptID: "p", controllerLabel: nil,
                                     controllerDeviceID: nil, expiresAt: expires)
        try expectEqual(request.countdown(now: expires.addingTimeInterval(-30)), "Declines in 30 seconds")
        try expectEqual(request.countdown(now: expires.addingTimeInterval(-0.2)), "Declines in 1 second")
        try expectEqual(request.secondsRemaining(now: expires.addingTimeInterval(-29.5)), 30)
        try expectEqual(request.secondsRemaining(now: expires.addingTimeInterval(-30.0004)), 30,
                        "sub-millisecond clock jitter never shows 31 on a 30-second prompt")
        try expectEqual(request.secondsRemaining(now: expires.addingTimeInterval(5)), 0)
    },

    // MARK: - API.md §4.1 host status line

    TestCase("trial shows a relative end date, active shows the balance and never a tier slug") {
        let now = Date(timeIntervalSince1970: 1_756_000_000)
        let trial = try entitlement(
            status: "trial", tier: "base",
            trialEndsAt: Int64((now.addingTimeInterval(3 * 86_400).timeIntervalSince1970) * 1000))
        try expect(EntitlementPresentation.statusLine(for: trial, now: now).hasPrefix("Trial \u{00B7} ends"))

        let activeNoBalance = try entitlement(status: "active", tier: "base")
        try expectEqual(EntitlementPresentation.statusLine(for: activeNoBalance), "Active")

        let activeWithBalance = try entitlement(status: "active", tier: "skipper", balanceCents: 1234)
        try expectEqual(
            EntitlementPresentation.statusLine(for: activeWithBalance),
            "Active \u{00B7} $12.34 balance",
            "the tier slug is an internal name and never reaches the screen")

        let exhausted = try entitlement(status: "exhausted", tier: "base")
        try expectEqual(
            EntitlementPresentation.statusLine(for: exhausted),
            "No balance \u{2014} top up at skipperdesk.app")
    },

    TestCase("the top-up URL is the web base plus /credits") {
        let url = EntitlementPresentation.topUpURL(webBaseURL: URL(string: "https://skipperdesk.app")!)
        try expectEqual(url.absoluteString, "https://skipperdesk.app/credits")
    },
])
