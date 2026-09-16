import Foundation
import RCTestKit
import RemoteControlCore

// MARK: - Reconnect backoff

public let backoffSuite = TestSuite("Reconnect backoff", [

    TestCase("the nominal schedule doubles from 0.5s and caps at 15s") {
        let backoff = ReconnectBackoff(minimum: 0.5, maximum: 15, jitterFraction: 0.25)
        try expectEqual(backoff.nominalDelay(forAttempt: 0), 0.5)
        try expectEqual(backoff.nominalDelay(forAttempt: 1), 1.0)
        try expectEqual(backoff.nominalDelay(forAttempt: 2), 2.0)
        try expectEqual(backoff.nominalDelay(forAttempt: 3), 4.0)
        try expectEqual(backoff.nominalDelay(forAttempt: 4), 8.0)
        try expectEqual(backoff.nominalDelay(forAttempt: 5), 15.0)   // 16 clamped
        try expectEqual(backoff.nominalDelay(forAttempt: 40), 15.0)
        // An absurd attempt count must not overflow into NaN or a negative delay.
        try expectEqual(backoff.nominalDelay(forAttempt: 100_000), 15.0)
    },

    TestCase("every jittered delay stays inside the documented 0.5s...15s bounds") {
        let backoff = ReconnectBackoff(minimum: 0.5, maximum: 15, jitterFraction: 0.25)
        for attempt in 0..<40 {
            for sample in 0..<20 {
                let r = Double(sample) / 20.0
                let delay = backoff.delay(forAttempt: attempt, random: { r })
                try expectGreaterThanOrEqual(delay, 0.5, "attempt \(attempt), r=\(r)")
                try expectLessThan(delay, 15.000001, "attempt \(attempt), r=\(r)")
            }
        }
    },

    TestCase("jitter actually moves the delay, in both directions") {
        let backoff = ReconnectBackoff(minimum: 0.5, maximum: 15, jitterFraction: 0.25)
        // Attempt 3 is nominally 4s, comfortably away from both clamps.
        let low = backoff.delay(forAttempt: 3, random: { 0.0 })
        let mid = backoff.delay(forAttempt: 3, random: { 0.5 })
        let high = backoff.delay(forAttempt: 3, random: { 0.999 })
        try expectEqual(mid, 4.0)
        try expectLessThan(low, mid)
        try expectGreaterThan(high, mid)
        // ±25% exactly — a stub returning the nominal delay fails all three.
        try expect(abs(low - 3.0) < 0.001, "expected 3.0 at the bottom of the jitter band, got \(low)")
        try expect(abs(high - 5.0) < 0.01, "expected ~5.0 at the top of the jitter band, got \(high)")
    },

    TestCase("consecutive draws differ, so two clients cannot retry in lockstep") {
        var backoff = ReconnectBackoff()
        var seen = Set<String>()
        for _ in 0..<50 { seen.insert(String(format: "%.6f", backoff.next())) }
        try expectGreaterThan(seen.count, 10, "a schedule with no jitter would produce a handful of values")
    },

    TestCase("next() advances and reset() returns to the floor") {
        var backoff = ReconnectBackoff(minimum: 0.5, maximum: 15, jitterFraction: 0)
        try expectEqual(backoff.next(random: { 0.5 }), 0.5)
        try expectEqual(backoff.next(random: { 0.5 }), 1.0)
        try expectEqual(backoff.next(random: { 0.5 }), 2.0)
        backoff.reset()
        try expectEqual(backoff.next(random: { 0.5 }), 0.5)
    },
])

// MARK: - Certificate pinning

public let pinningSuite = TestSuite("Certificate pinning", [

    TestCase("the fingerprint of the live server's certificate is the documented pin") {
        let pin = CertificatePinner.fingerprint(ofDER: TestCertificates.live)
        try expectEqual(pin, TestCertificates.liveServerPin,
                        "infra/README.md and RCConfig must agree with the deployed certificate")
        try expectEqual(pin, RCConfig.defaultCertificatePin)
    },

    TestCase("a matching certificate is accepted") {
        let pinner = CertificatePinner(expectedPinBase64: TestCertificates.liveServerPin)
        try expectEqual(pinner.evaluate(derChain: [TestCertificates.live]), .accepted)
    },

    TestCase("a DIFFERENT certificate is rejected — this is the assertion that matters") {
        let pinner = CertificatePinner(expectedPinBase64: TestCertificates.liveServerPin)
        let outcome = pinner.evaluate(derChain: [TestCertificates.other])
        guard case .rejectedFingerprintMismatch(let presented, let expected) = outcome else {
            throw fail("expected a fingerprint mismatch, got \(outcome)")
        }
        try expectEqual(presented, TestCertificates.otherPin)
        try expectEqual(expected, TestCertificates.liveServerPin)
        try expectFalse(outcome.isAcceptable)
    },

    TestCase("a single flipped bit in the certificate is rejected") {
        var tampered = TestCertificates.live
        tampered[tampered.count - 1] ^= 0x01
        let pinner = CertificatePinner(expectedPinBase64: TestCertificates.liveServerPin)
        try expectFalse(pinner.evaluate(derChain: [tampered]).isAcceptable)
    },

    TestCase("an empty chain is rejected, never silently accepted") {
        let pinner = CertificatePinner(expectedPinBase64: TestCertificates.liveServerPin)
        try expectEqual(pinner.evaluate(derChain: []), .rejectedNoCertificate)
    },

    TestCase("only the LEAF is pinned; a matching leaf behind other certs still passes") {
        let pinner = CertificatePinner(expectedPinBase64: TestCertificates.liveServerPin)
        try expectEqual(pinner.evaluate(derChain: [TestCertificates.live, TestCertificates.other]), .accepted)
        // ...and a wrong leaf is not rescued by a right certificate further down.
        try expectFalse(pinner.evaluate(derChain: [TestCertificates.other, TestCertificates.live]).isAcceptable)
    },

    TestCase("pinning off means pinning off, and says so") {
        let pinner = CertificatePinner(expectedPinBase64: nil)
        try expectEqual(pinner.evaluate(derChain: [TestCertificates.other]), .notPinned)
        try expect(CertificatePinner.Outcome.notPinned.isAcceptable)
    },

    TestCase("pin comparison rejects a prefix and a length change") {
        try expect(CertificatePinner.pinsMatch("abc", "abc"))
        try expectFalse(CertificatePinner.pinsMatch("abc", "abcd"))
        try expectFalse(CertificatePinner.pinsMatch("abc", "abd"))
        try expectFalse(CertificatePinner.pinsMatch("", "a"))
    },
])

// MARK: - Configuration

public let configSuite = TestSuite("Config", [

    TestCase("the shipped defaults are the deployed server and its pin") {
        let config = RCConfig.fromEnvironment([:])
        try expectEqual(config.signalingURL.absoluteString, "wss://54.246.73.81:8443/ws")
        try expectEqual(config.certificatePinBase64, "E30xoxEp9t658+TJEVdaGb8Ooi7HGGMWp1kxVpeSpgk=")
        try expectEqual(config.backoffMinimum, 0.5)
        try expectEqual(config.backoffMaximum, 15)
        try expectEqual(config.heartbeatInterval, 15)
        try expectEqual(config.renewInterval, 300)
        try expectEqual(config.iceRestartDelay, 3)
        try expectEqual(config.iceFailureGrace, 45)
    },

    TestCase("every knob has an environment override") {
        let config = RCConfig.fromEnvironment([
            "RC_SERVER_URL": "wss://198.51.100.9:9443/ws",
            "RC_CERT_PIN": "AAAA",
            "RC_DEVICE_LABEL": "Bench",
            "RC_HEARTBEAT_SEC": "7",
            "RC_RENEW_SEC": "60",
            "RC_BACKOFF_MIN": "0.1",
            "RC_BACKOFF_MAX": "3",
            "RC_ICE_RESTART_DELAY": "1",
            "RC_ICE_FAILURE_GRACE": "5",
        ])
        try expectEqual(config.signalingURL.absoluteString, "wss://198.51.100.9:9443/ws")
        try expectEqual(config.certificatePinBase64, "AAAA")
        try expectEqual(config.deviceLabel, "Bench")
        try expectEqual(config.heartbeatInterval, 7)
        try expectEqual(config.renewInterval, 60)
        try expectEqual(config.backoffMinimum, 0.1)
        try expectEqual(config.backoffMaximum, 3)
        try expectEqual(config.iceRestartDelay, 1)
        try expectEqual(config.iceFailureGrace, 5)
        try expectEqual(config.healthURL?.absoluteString, "https://198.51.100.9:9443/healthz")
    },

    TestCase("RC_CERT_PIN=off disables pinning, and ws:// has nothing to pin") {
        try expectNil(RCConfig.fromEnvironment(["RC_CERT_PIN": "off"]).certificatePinBase64)
        let local = RCConfig.fromEnvironment(["RC_SERVER_URL": "ws://127.0.0.1:18443/ws"])
        try expectNil(local.certificatePinBase64, "a plain ws:// endpoint presents no certificate")
        try expectEqual(local.healthURL?.absoluteString, "http://127.0.0.1:18443/healthz")
    },

    TestCase("a malformed RC_SERVER_URL falls back rather than crashing") {
        let config = RCConfig.fromEnvironment(["RC_SERVER_URL": "   "])
        try expectEqual(config.signalingURL.absoluteString, RCConfig.defaultServerURLString)
    },
])
