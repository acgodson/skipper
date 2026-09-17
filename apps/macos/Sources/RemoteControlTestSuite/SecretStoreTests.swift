import Foundation
import RCTestKit
import RemoteControlCore
import SkipperCore

private let controllerKey = "MFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAEcontroller"
private let otherKey = "MFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAEother"

public let secretStoreSuite = TestSuite("SecretStore (PROTOCOL.md §4.5)", [

    TestCase("a remembered peer code is stored canonicalised, per host") {
        let store = SecretStore(blobs: InMemorySecretStore())
        try expectNil(try store.peerCode(forHost: "482719351"))

        let code = try AccessCode.generate()
        try store.rememberPeerCode(AccessCode.formatted(code).lowercased(), forHost: "482719351")
        try expectEqual(try store.peerCode(forHost: "482719351"), code,
                        "what the user typed is normalised before it is stored")
        try expectNil(try store.peerCode(forHost: "739000587"),
                      "codes belong to one host, not to this Mac")

        let second = try AccessCode.generate()
        try store.rememberPeerCode(second, forHost: "739000587")
        try expectEqual(try store.peerCode(forHost: "482719351"), code,
                        "remembering a second host must not disturb the first")

        try store.forgetPeerCode(forHost: "482719351")
        try expectNil(try store.peerCode(forHost: "482719351"))
        try expectEqual(try store.peerCode(forHost: "739000587"), second)
    },

    TestCase("an unusable peer code is never stored") {
        let store = SecretStore(blobs: InMemorySecretStore())
        try store.rememberPeerCode("nope", forHost: "482719351")
        try expectNil(try store.peerCode(forHost: "482719351"))
    },

    TestCase("a trusted controller keeps its first-seen across later sessions") {
        let store = SecretStore(blobs: InMemorySecretStore())
        let first = Date(timeIntervalSince1970: 1_700_000_000)
        let later = first.addingTimeInterval(3600)

        try store.recordTrustedController(pubkey: controllerKey, label: "482 719 351", now: first)
        try store.recordTrustedController(pubkey: controllerKey, label: "482 719 351", now: later)

        let entry = try expectNotNil(try store.trustedControllers()[controllerKey])
        try expectEqual(entry.firstSeen, first, "first-seen is when this controller became known")
        try expectEqual(entry.lastSeen, later)
        try expectEqual(entry.label, "482 719 351")
        try expectEqual(try store.trustedControllers().count, 1)
    },

    TestCase("a guess counter survives being stored and read back") {
        let store = SecretStore(blobs: InMemorySecretStore())
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        try expectNil(try store.guessCounter(forController: controllerKey))

        var counter = GuessCounter()
        for attempt in 1...4 {
            counter = try GuessPolicy.recordFailure(counter, now: now).counter
            try store.saveGuessCounter(counter, forController: controllerKey)
            counter = try expectNotNil(try store.guessCounter(forController: controllerKey))
            try expectEqual(counter.failures, attempt)
            try expect(try GuessPolicy.check(counter, now: now).isAllowed,
                       "four failures is still under the threshold")
        }

        counter = try GuessPolicy.recordFailure(counter, now: now).counter
        try store.saveGuessCounter(counter, forController: controllerKey)
        let reloaded = try expectNotNil(try store.guessCounter(forController: controllerKey))
        try expectEqual(reloaded.failures, 5)
        let decision = try GuessPolicy.check(reloaded, now: now)
        try expectFalse(decision.isAllowed, "the fifth failure locks this controller out")
        try expectEqual(decision.retryAfterMs, 60_000, "one minute, then doubling")
        try expect(try GuessPolicy.check(reloaded, now: now.addingTimeInterval(61)).isAllowed,
                   "and the lockout ends on its own")

        try expectNil(try store.guessCounter(forController: otherKey))

        let cleared = try GuessPolicy.recordSuccess(reloaded).counter
        try store.saveGuessCounter(cleared, forController: controllerKey)
        try expectEqual(try store.guessCounter(forController: controllerKey)?.failures, 0,
                        "a completed exchange clears the count")
    },

    TestCase("revoking clears the trusted list and the counters, not the codes") {
        let store = SecretStore(blobs: InMemorySecretStore())
        let code = try AccessCode.generate()
        try store.saveAccessCode(code)
        try store.rememberPeerCode(try AccessCode.generate(), forHost: "482719351")
        try store.recordTrustedController(pubkey: controllerKey, label: "a Mac")
        try store.saveGuessCounter(GuessCounter(failures: 3), forController: otherKey)

        try store.revokeControllers()

        try expect(try store.trustedControllers().isEmpty, "every trusted controller is gone")
        try expectNil(try store.guessCounter(forController: otherKey), "and every counter with it")
        try expectEqual(try store.accessCode(), code,
                        "revoking controllers does not by itself change this Mac's code")
        try expectNotNil(try store.peerCode(forHost: "482719351"),
                         "nor the codes this Mac remembers for OTHER hosts")
    },

    TestCase("removing a trusted controller forgets only that one, and persists") {
        let store = SecretStore(blobs: InMemorySecretStore())
        try store.recordTrustedController(pubkey: controllerKey, label: "a Mac")
        try store.recordTrustedController(pubkey: otherKey, label: "another Mac")

        try store.remove(pubkey: controllerKey)

        try expectNil(try store.trustedControllers()[controllerKey],
                      "the removed controller is gone")
        try expectNotNil(try store.trustedControllers()[otherKey],
                         "the other controller is untouched")
        try expectEqual(try store.trustedControllers().count, 1)
    },

    TestCase("a Keychain that refuses is reported, not silently ignored") {
        let blobs = InMemorySecretStore()
        let store = SecretStore(blobs: blobs)
        blobs.isSealed = true
        try await expectThrows("a sealed Keychain") {
            try store.saveAccessCode("K7FM3Q8PW2XY")
        }
        try await expectThrows("a sealed Keychain") {
            _ = try store.accessCode()
        }
    },
])
