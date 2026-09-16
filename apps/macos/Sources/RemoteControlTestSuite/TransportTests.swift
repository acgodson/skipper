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
        try expectEqual(backoff.nominalDelay(forAttempt: 5), 15.0)
        try expectEqual(backoff.nominalDelay(forAttempt: 40), 15.0)
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
        let low = backoff.delay(forAttempt: 3, random: { 0.0 })
        let mid = backoff.delay(forAttempt: 3, random: { 0.5 })
        let high = backoff.delay(forAttempt: 3, random: { 0.999 })
        try expectEqual(mid, 4.0)
        try expectLessThan(low, mid)
        try expectGreaterThan(high, mid)
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

// MARK: - Configuration

public let configSuite = TestSuite("Config", [

    TestCase("the shipped defaults are the public API domain, over TLS") {
        let config = RCConfig.fromEnvironment([:])
        try expectEqual(config.apiBaseURL.absoluteString, "https://api.skipperdesk.app")
        try expectEqual(config.signalingURL.absoluteString, "wss://api.skipperdesk.app/ws")
        try expectEqual(config.backoffMinimum, 0.5)
        try expectEqual(config.backoffMaximum, 15)
        try expectEqual(config.heartbeatInterval, 15)
        try expectEqual(config.renewInterval, 300)
        try expectEqual(config.iceRestartDelay, 3)
        try expectEqual(config.iceFailureGrace, 45)
    },

    TestCase("every knob has an environment override") {
        let config = RCConfig.fromEnvironment([
            "SKIPPER_API_BASE_URL": "https://api.example.com",
            "RC_DEVICE_LABEL": "Bench",
            "RC_HEARTBEAT_SEC": "7",
            "RC_RENEW_SEC": "60",
            "RC_BACKOFF_MIN": "0.1",
            "RC_BACKOFF_MAX": "3",
            "RC_ICE_RESTART_DELAY": "1",
            "RC_ICE_FAILURE_GRACE": "5",
        ])
        try expectEqual(config.apiBaseURL.absoluteString, "https://api.example.com")
        try expectEqual(config.signalingURL.absoluteString, "wss://api.example.com/ws")
        try expectEqual(config.deviceLabel, "Bench")
        try expectEqual(config.heartbeatInterval, 7)
        try expectEqual(config.renewInterval, 60)
        try expectEqual(config.backoffMinimum, 0.1)
        try expectEqual(config.backoffMaximum, 3)
        try expectEqual(config.iceRestartDelay, 1)
        try expectEqual(config.iceFailureGrace, 5)
        try expectEqual(config.healthURL?.absoluteString, "https://api.example.com/healthz")
    },

    TestCase("http:// and ws:// are accepted for localhost and 127.0.0.1, for local dev") {
        let localhost = RCConfig.fromEnvironment(["SKIPPER_API_BASE_URL": "http://localhost:18443"])
        try expectEqual(localhost.signalingURL.absoluteString, "ws://localhost:18443/ws")
        try expectEqual(localhost.healthURL?.absoluteString, "http://localhost:18443/healthz")

        let loopback = RCConfig.fromEnvironment(["SKIPPER_API_BASE_URL": "http://127.0.0.1:18443"])
        try expectEqual(loopback.signalingURL.absoluteString, "ws://127.0.0.1:18443/ws")
        try expectEqual(loopback.healthURL?.absoluteString, "http://127.0.0.1:18443/healthz")
    },

    TestCase("a malformed SKIPPER_API_BASE_URL falls back rather than crashing") {
        let config = RCConfig.fromEnvironment(["SKIPPER_API_BASE_URL": "   "])
        try expectEqual(config.apiBaseURL.absoluteString, RCConfig.defaultAPIBaseURLString)
    },
])
