// API.md §4.2's re-fetch, and the bye that says the money ran out. Both exist because
// a host used to learn neither: the account card kept showing credit that was gone and
// the session it was closed out of said nothing (docs/AUDIT.md finding 3).
import Foundation
import RCTestKit
import RemoteControlCore

private let spentEntitlement = """
{"status":"exhausted","tier":"base","balanceCents":0,"minutesRemaining":0,
"concurrency":{"maxActivePairs":1},"limits":{"maxQuality":"auto"},"refreshAfterSec":1}
"""

/// A trial answer that asks to be re-read every second, so the loop under test runs on
/// the server's own cadence rather than on a number this test invented.
private let impatientTrial = """
{"status":"trial","tier":"base","balanceCents":50,"minutesRemaining":300,
"trialEndsAt":1900000000000,"concurrency":{"maxActivePairs":1},"refreshAfterSec":1}
"""

public let entitlementRefreshSuite = TestSuite("Account/entitlement refresh", [

    TestCase("a host whose credit runs out finds out without anybody opening a window") {
        StubbedAPI.answerEntitlement(with: impatientTrial)
        try await withSignedInLinker(accountEmail: "runsout@example.com") { linker, _, _ in
            StubbedAPI.answerEntitlement(with: impatientTrial)
            await linker.refreshEntitlement(force: true)
            try expectEqual(linker.entitlement?.value.status, .trial)

            // The credit goes while the app sits there. Nothing touches the linker
            // from here on: no refresh call, no window appearing, no session event.
            StubbedAPI.answerEntitlement(with: spentEntitlement)
            linker.startRefreshing()
            defer { linker.stopRefreshing() }

            await wait(upTo: 10) { linker.entitlement?.value.status == .exhausted }
            try expectEqual(linker.entitlement?.value.status, .exhausted,
                            "the host still believes it has credit it has spent")
            try expectEqual(linker.entitlement?.value.balanceCents, 0)
        }
    },

    TestCase("the refresh cadence is the server's number, not one the client holds") {
        try expectEqual(Entitlement.defaultRefreshAfterSec, 60)
        let stated = try expectNotNil(try? JSONDecoder().decode(
            Entitlement.self, from: Data(spentEntitlement.utf8)))
        try expectEqual(stated.refreshAfterSec, 1)

        // A server that says nothing gets the documented default rather than a guess.
        let silent = try expectNotNil(try? JSONDecoder().decode(Entitlement.self, from: Data("""
        {"status":"active","tier":"base","concurrency":{"maxActivePairs":1}}
        """.utf8)))
        try expectEqual(silent.refreshAfterSec, Entitlement.defaultRefreshAfterSec)
    },

    // MARK: - PROTOCOL.md §2.14.2

    TestCase("a session ended for money says so, and says it differently to each Mac") {
        let host = try expectNotNil(SessionEndPresentation.notice(
            reason: Wire.ByeReason.noBalance, role: .host))
        let controller = try expectNotNil(SessionEndPresentation.notice(
            reason: Wire.ByeReason.noBalance, role: .controller))

        try expect(host != controller, "both Macs are told the same thing about whose money it was")
        try expect(host.title.contains("credit"), "the host is not told what ran out: \(host.title)")
        try expect(controller.title.contains("no credit left"),
                   "the controller is not told why: \(controller.title)")

        // DESIGN.md §4 rules 2 and 8: no reason code, no internals, in either sentence.
        for words in [host.title, host.detail ?? "", controller.title, controller.detail ?? ""] {
            for jargon in ["no_balance", "entitlement", "bye", "host_ended", "balance"] {
                try expectFalse(words.lowercased().contains(jargon),
                                "\(jargon) reached the person: \(words)")
            }
        }
    },

    TestCase("the reason the host used to be blamed for carries no notice of its own") {
        try expectNil(SessionEndPresentation.notice(
            reason: Wire.ByeReason.hostEnded, role: .controller))
        try expectNil(SessionEndPresentation.notice(
            reason: Wire.ByeReason.userEnded, role: .host))
    },
])
