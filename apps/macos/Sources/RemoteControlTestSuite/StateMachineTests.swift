import CryptoKit
import Foundation
import RCTestKit
import RemoteControlCore

private let sessionOne = "5e550000000000000000000000000001"

private func freshDeviceKey() -> String {
    P256.Signing.PrivateKey().publicKey.derRepresentation.base64EncodedString()
}

private func grant(_ id: String = sessionOne, token: String = "tok-1",
                   host: String = "481930275", controller: String = "111222333") -> SessionGrantPayload {
    SessionGrantPayload(sessionId: id, sessionToken: token, expiresAt: 0, ttlSec: 600,
                        hostDeviceId: host, controllerDeviceId: controller)
}

private func liveController(iceRestartDelay: TimeInterval = 3,
                            iceFailureGrace: TimeInterval = 45,
                            renewInterval: TimeInterval = 300) -> SessionStateMachine {
    let machine = SessionStateMachine(role: .controller, iceRestartDelay: iceRestartDelay,
                                      iceFailureGrace: iceFailureGrace, renewInterval: renewInterval)
    _ = machine.signalingAuthenticated(activeSessionID: nil)
    _ = machine.connectRequested(deviceID: "481930275", accessCode: "K7FM3Q8PW2XY", remember: true)
    _ = machine.sessionGranted(grant())
    _ = machine.pakeSucceeded()
    _ = machine.iceStateChanged(to: .connected)
    return machine
}

public let stateMachineSuite = TestSuite("Session state machine (the coordinator's surface)", [

    TestCase("the identity the coordinator reads comes back across the FFI") {
        let machine = SessionStateMachine(role: .controller)
        try expectEqual(machine.sessionID, nil)
        try expect(machine.isOfferer, "the controller offers")

        _ = machine.signalingAuthenticated(activeSessionID: nil)
        _ = machine.connectRequested(deviceID: "481930275", accessCode: "K7FM3Q8PW2XY", remember: false)
        _ = machine.sessionGranted(grant())

        try expectEqual(machine.sessionID, sessionOne)
        try expectEqual(machine.sessionToken, "tok-1")
        try expectEqual(machine.peerDeviceID, "481930275", "the controller's peer is the host")
        try expect(machine.hasSession)
        try expect(machine.signalingUp)
        try expectEqual(machine.iceState, .new)

        _ = machine.iceStateChanged(to: .connected)
        try expectEqual(machine.iceState, .new, "no link state counts before the machine starts the peer")
        _ = machine.pakeSucceeded()
        _ = machine.iceStateChanged(to: .connected)
        try expectEqual(machine.iceState, .connected)
        try expectEqual(machine.phase, .live)
    },

    TestCase("a host reads back the opposite peer and never offers") {
        let machine = SessionStateMachine(role: .host)
        _ = machine.signalingAuthenticated(activeSessionID: nil)
        _ = machine.sessionGranted(grant())
        try expectFalse(machine.isOfferer, "startPeerConnection carries this")
        try expectEqual(machine.peerDeviceID, "111222333", "the host's peer is the controller")
    },

    TestCase("the remembered access code survives the boundary in both directions") {
        let machine = SessionStateMachine(role: .controller)
        try expectEqual(machine.rememberedAccessCode, nil)

        _ = machine.connectRequested(deviceID: "481930275", accessCode: "K7FM3Q8PW2XY", remember: true)
        try expectEqual(machine.rememberedAccessCode, "K7FM3Q8PW2XY",
                        "the coordinator consults this before deciding to prompt")

        machine.rememberedAccessCode = "AAAA-BBBB-CCCC"
        try expectEqual(machine.rememberedAccessCode, "AAAA-BBBB-CCCC")
        machine.rememberedAccessCode = nil
        try expectEqual(machine.rememberedAccessCode, nil, "forgetting must reach the core, not just Swift")
    },

    TestCase("the timings the coordinator passes in are the ones the core uses") {
        let t0 = Date()
        let machine = liveController(iceRestartDelay: 10, iceFailureGrace: 5, renewInterval: 60)
        _ = machine.iceStateChanged(to: .disconnected, now: t0)

        try expect(machine.tick(now: t0.addingTimeInterval(4)).isEmpty,
                   "the default 3s would have restarted by now; this machine was told 10s")
        try expect(machine.tick(now: t0.addingTimeInterval(11)).contains(.restartICE(relayOnly: false)))

        let closing = machine.tick(now: t0.addingTimeInterval(11))
        try expect(closing.isEmpty, "disconnected is not failed; nothing closes")

        _ = machine.iceStateChanged(to: .failed, now: t0.addingTimeInterval(12))
        try expect(machine.tick(now: t0.addingTimeInterval(16)).isEmpty,
                   "4s into a 5s grace window the session is still alive")
        try expect(machine.tick(now: t0.addingTimeInterval(17.5))
            .contains { if case .sendBye = $0 { return true }; return false },
            "a 5s grace window must close at 5s, not at the default 45s")
    },

    TestCase("a renew interval shorter than the default is honoured too") {
        let t0 = Date()
        let machine = SessionStateMachine(role: .controller, iceRestartDelay: 3,
                                          iceFailureGrace: 45, renewInterval: 60)
        _ = machine.signalingAuthenticated(activeSessionID: nil)
        _ = machine.connectRequested(deviceID: "481930275", accessCode: "K7FM3Q8PW2XY", remember: false)
        _ = machine.sessionGranted(grant(), now: t0)
        _ = machine.pakeSucceeded(now: t0)
        _ = machine.iceStateChanged(to: .connected, now: t0)

        func renews(_ actions: [SessionAction]) -> Bool {
            actions.contains { if case .sendRenew = $0 { return true }; return false }
        }
        try expectFalse(renews(machine.tick(now: t0.addingTimeInterval(59))))
        try expect(renews(machine.tick(now: t0.addingTimeInterval(61))))
    },

    TestCase("the consent deadline and flag cross the FFI as the coordinator reads them") {
        let t0 = Date(timeIntervalSince1970: 1_756_000_000)
        let machine = SessionStateMachine(role: .host)
        try expectFalse(machine.consentRequired, "the core's own default is the code-only path")
        machine.consentRequired = true
        try expect(machine.consentRequired)
        _ = machine.signalingAuthenticated(activeSessionID: nil)
        _ = machine.sessionGranted(grant(), now: t0)

        let prompt = machine.pakeSucceeded(now: t0)
        let promptID = try expectNotNil(machine.consentPromptID)
        try expectEqual(prompt, [.promptForConsent(expiresAt: t0.addingTimeInterval(30),
                                                   promptID: promptID, replacesPrevious: false)])
        try expectNotEqual(promptID, sessionOne)
        try expectEqual(machine.phase, .awaitingConsent)
        try expectEqual(machine.consentExpiresAt, t0.addingTimeInterval(30))
        try expectEqual(SessionState(phase: machine.phase, sessionID: machine.sessionID), .connecting,
                        "waiting for the owner is not a session anyone is in yet")

        try expectEqual(machine.consentAnswered(allow: true, promptID: nil, now: t0.addingTimeInterval(3)), [],
                        "an Allow must name its prompt")
        try expectEqual(machine.consentAnswered(allow: true, promptID: promptID, now: t0.addingTimeInterval(1)), [],
                        "an Allow inside the delay is refused")
        let allowed = machine.consentAnswered(allow: true, promptID: promptID, now: t0.addingTimeInterval(3))
        try expectEqual(allowed, [.dismissConsentPrompt(outcome: .allowed), .startPeerConnection(offerer: false)])
        try expectEqual(machine.consentExpiresAt, nil)
        try expectNil(machine.consentPromptID)
    },

    TestCase("every prompt that was not allowed counts against the controller") {
        try expect(ConsentOutcome.declined.countsAsDecline)
        try expect(ConsentOutcome.timedOut.countsAsDecline)
        try expect(ConsentOutcome.cancelled.countsAsDecline, "hanging up during the prompt is a decline")
        try expectFalse(ConsentOutcome.allowed.countsAsDecline)
    },

    TestCase("a prompt is paid for when it opens and only Allow gives it back") {
        let t0 = Date(timeIntervalSince1970: 1_756_000_000)
        let fresh = GuessLedger()
        try expect(try ConsentPolicy.admit(fresh, now: t0).shouldPrompt)
        let once = try ConsentPolicy.prompted(fresh, now: t0)
        try expect(once.shouldPrompt, "one unanswered prompt still asks")
        let twice = try ConsentPolicy.prompted(once.ledger, now: t0.addingTimeInterval(60))
        try expectFalse(twice.shouldPrompt, "a controller that hung up twice is not asked about again")
        try expectEqual(twice.retryAfterMs, 9 * 60 * 1000)
        try expect(try ConsentPolicy.admit(twice.ledger, now: t0.addingTimeInterval(600)).shouldPrompt)
        let allowed = try ConsentPolicy.allowed(twice.ledger, now: t0.addingTimeInterval(61))
        try expect(allowed.shouldPrompt)
        try expectEqual(allowed.ledger.controller.declineTimesMs, nil)
        try expectEqual(allowed.ledger.host.promptTimesMs?.count, 1, "Allow returns only its own prompt")
    },

    TestCase("three prompts from three fresh keys exhaust the host for ten minutes") {
        let t0 = Date(timeIntervalSince1970: 1_756_000_000)
        var host = GuessCounter()
        for minute in 0..<3 {
            let now = t0.addingTimeInterval(TimeInterval(minute * 60))
            let freshKey = GuessLedger(host: host)
            try expect(try ConsentPolicy.admit(freshKey, now: now).shouldPrompt, "prompt \(minute)")
            host = try ConsentPolicy.prompted(freshKey, now: now).ledger.host
        }
        let fourth = try ConsentPolicy.admit(GuessLedger(host: host), now: t0.addingTimeInterval(180))
        try expectFalse(fourth.shouldPrompt)
        try expectEqual(fourth.retryAfterMs, 7 * 60 * 1000)
    },

    TestCase("a stored counter from before the consent fields still decodes, and round-trips") {
        let legacy = Data(#"{"failures":2,"lastFailureMs":5,"lockedUntilMs":0}"#.utf8)
        let counter = try JSONDecoder().decode(GuessCounter.self, from: legacy)
        try expectEqual(counter.failures, 2)
        try expectEqual(counter.declineTimesMs, nil)
        let opened = try ConsentPolicy.prompted(GuessLedger(controller: counter),
                                                now: Date(timeIntervalSince1970: 100))
        try expectEqual(opened.ledger.controller.failures, 2, "the guess history survives a prompt")
        try expectEqual(opened.ledger.controller.declineTimesMs, [100_000])
        let encoded = try JSONEncoder().encode(opened.ledger.controller)
        try expectEqual(try JSONDecoder().decode(GuessCounter.self, from: encoded), opened.ledger.controller)
    },

    TestCase("stored counters are pruned, re-keyed canonically and capped") {
        let now = Date(timeIntervalSince1970: 2_000_000)
        let nowMs: Int64 = 2_000_000_000
        let recent = freshDeviceKey()
        let stale = freshDeviceKey()
        var counters: [String: GuessCounter] = [
            recent: GuessCounter(failures: 1, lastFailureMs: nowMs - 1),
            stale: GuessCounter(failures: 1, lastFailureMs: nowMs - 24 * 3_600_000),
            "not a key": GuessCounter(failures: 1, lastFailureMs: nowMs),
            GuessLedger.hostKey: GuessCounter(promptTimesMs: [nowMs]),
        ]
        var pruned = try GuessLedgerBook.pruned(counters, now: now)
        try expectEqual(Set(pruned.keys), [recent, GuessLedger.hostKey])
        for index in 0..<300 {
            counters[freshDeviceKey()] = GuessCounter(failures: 1, lastFailureMs: nowMs - Int64(index))
        }
        pruned = try GuessLedgerBook.pruned(counters, now: now)
        try expectEqual(pruned.count, 256)
        try expect(pruned[GuessLedger.hostKey] != nil)
    },

    TestCase("only a canonical P-256 key is a device key") {
        let key = freshDeviceKey()
        try expect(DevicePublicKey.isCanonical(key))
        try expectEqual(try DevicePublicKey.canonical(key), key)
        for bad in ["", GuessLedger.hostKey, "not base64!", String(key.dropLast(2)), key + "AAAA"] {
            try expectFalse(DevicePublicKey.isCanonical(bad), bad)
        }
    },

    TestCase("review M-A: a leftover peer never turns a new prompt into a live session") {
        let t0 = Date(timeIntervalSince1970: 1_756_000_000)
        let sessionB = "5e5500000000000000000000000000b2"
        let machine = SessionStateMachine(role: .host)
        machine.consentRequired = true
        _ = machine.signalingAuthenticated(activeSessionID: nil)
        _ = machine.sessionGranted(grant(), now: t0)
        _ = machine.pakeSucceeded(now: t0)
        _ = machine.consentAnswered(allow: true, promptID: machine.consentPromptID, now: t0.addingTimeInterval(2))
        _ = machine.iceStateChanged(to: .connected, now: t0.addingTimeInterval(3))
        try expectEqual(machine.phase, .live)
        try expectEqual(RemoteSignalDisposition.of(signalSessionID: sessionOne, machine: machine, hasPeer: true),
                        .apply)

        let granted = machine.sessionGranted(grant(sessionB), now: t0.addingTimeInterval(10))
        try expectEqual(granted.first, .teardownPeerConnection, "A's peer goes before anything else")
        try expectEqual(RemoteSignalDisposition.of(signalSessionID: sessionOne, machine: machine, hasPeer: false),
                        .drop, "A's signals are no longer this session's")
        _ = machine.pakeSucceeded(now: t0.addingTimeInterval(11))
        var produced: [SessionAction] = []
        for state in [ICELinkState.disconnected, .connected, .completed] {
            produced += machine.iceStateChanged(to: state, now: t0.addingTimeInterval(12))
            try expectEqual(machine.phase, .awaitingConsent, "A's ICE bounce (\(state)) moves nothing")
            try expectEqual(RemoteSignalDisposition.of(signalSessionID: sessionB, machine: machine, hasPeer: true),
                            .hold, "B's sdp is never applied while the owner is asked")
        }
        try expectEqual(produced, [])
        try expectFalse(machine.peerStarted)

        let declined = machine.consentAnswered(allow: false, promptID: machine.consentPromptID,
                                               now: t0.addingTimeInterval(14))
        try expect(declined.contains(.teardownPeerConnection))
        try expect(declined.contains(.sendBye(sessionID: sessionB, reason: Wire.ByeReason.declined)))
        try expectFalse(declined.contains(.startPeerConnection(offerer: false)))
        try expectEqual(machine.phase, .closed(reason: Wire.ByeReason.declined))
        try expectEqual(RemoteSignalDisposition.of(signalSessionID: sessionB, machine: machine, hasPeer: false),
                        .drop, "nothing for B is applied after the decline either")
    },

    TestCase("a malformed server value is refused at the boundary and changes nothing") {
        let machine = SessionStateMachine(role: .host)
        _ = machine.signalingAuthenticated(activeSessionID: nil)
        try expectEqual(machine.sessionGranted(grant("S|offer")), [])
        try expect(machine.lastRejection != nil)
        try expectFalse(machine.hasSession)
        _ = machine.sessionGranted(grant(controller: "Evil Mac"))
        try expectEqual(machine.lastRejection, nil)
        try expectEqual(machine.peerDeviceID, nil, "the prompt then says \"another Mac\"")
    },

    TestCase("review C2: a replaced prompt's Allow never admits the controller that replaced it") {
        let t0 = Date(timeIntervalSince1970: 1_756_000_000)
        let machine = SessionStateMachine(role: .host)
        machine.consentRequired = true
        _ = machine.signalingAuthenticated(activeSessionID: nil)
        _ = machine.sessionGranted(grant(), now: t0)
        _ = machine.pakeSucceeded(now: t0)
        let promptA = try expectNotNil(machine.consentPromptID)

        let replaced = machine.sessionGranted(grant(controller: "739000588"), now: t0.addingTimeInterval(5))
        try expectEqual(replaced, [.teardownPeerConnection, .dismissConsentPrompt(outcome: .cancelled)],
                        "the same session id for another controller still dismisses the open prompt")
        let prompt = machine.pakeSucceeded(now: t0.addingTimeInterval(6))
        let promptB = try expectNotNil(machine.consentPromptID)
        try expectNotEqual(promptA, promptB)
        try expectEqual(prompt, [.promptForConsent(expiresAt: t0.addingTimeInterval(36),
                                                   promptID: promptB, replacesPrevious: true)])

        try expectEqual(machine.consentAnswered(allow: true, promptID: promptA, now: t0.addingTimeInterval(9)), [])
        try expectEqual(machine.consentAnswered(allow: true, promptID: sessionOne, now: t0.addingTimeInterval(9)), [])
        try expectEqual(machine.consentAnswered(allow: true, promptID: promptB, now: t0.addingTimeInterval(7)), [])
        try expectEqual(machine.tick(now: t0.addingTimeInterval(8)), [], "a refused Allow is not queued")
        try expectEqual(machine.phase, .awaitingConsent)
        try expectFalse(machine.peerStarted)
    },

    TestCase("a relay fallback ends with its session; a forced relay does not") {
        let t0 = Date(timeIntervalSince1970: 1_756_000_000)
        let machine = SessionStateMachine(role: .controller)
        _ = machine.signalingAuthenticated(activeSessionID: nil)
        _ = machine.sessionGranted(grant(), now: t0)
        _ = machine.pakeSucceeded(now: t0)
        _ = machine.iceStateChanged(to: .failed, now: t0)
        try expect(machine.relayOnly)
        _ = machine.sessionGranted(grant("5e5500000000000000000000000000b2"), now: t0)
        try expectFalse(machine.relayOnly, "review leftover: relay_only no longer carries over")

        machine.setRelayOnly(true)
        _ = machine.closeLocally(reason: Wire.ByeReason.userEnded)
        _ = machine.sessionGranted(grant(), now: t0)
        try expect(machine.relayOnly, "RC_ICE_POLICY=relay holds for every session")
        _ = machine.pakeSucceeded(now: t0)
        try expectEqual(machine.iceServersArrived(sessionID: sessionOne), [.restartICE(relayOnly: true)])
        try expectEqual(machine.iceServersArrived(sessionID: "5e5500000000000000000000000000b2"), [])
        try expect(machine.lastRejection != nil, "a push for another session is refused")
    },

    TestCase("input_reset is a no-op at the transport when no channel is open") {
        let peer = PeerSession(iceServers: [], isOfferer: true)
        try expectFalse(peer.sendInputReset(),
                        "the coordinator performs .sendInputReset before the peer exists")
        try expectFalse(peer.sendInputReset(), "and it stays a no-op, never a throw")
    },

    TestCase("the UI states are all distinct — Reconnecting is not Disconnected") {
        try expectNotEqual(SessionPhase.reconnecting.summary, SessionPhase.closed(reason: "failed").summary)
        try expectNotEqual(SessionPhase.reconnecting.summary, SessionPhase.idle.summary)
        try expectEqual(SessionPhase.reconnecting.summary, "Reconnecting\u{2026}")
        try expectEqual(SessionPhase.live.summary, "Connected")
    },
])
