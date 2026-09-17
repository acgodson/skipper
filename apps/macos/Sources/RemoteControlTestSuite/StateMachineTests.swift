import Foundation
import RCTestKit
import RemoteControlCore

private func grant(_ id: String = "sess-1", token: String = "tok-1",
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

        try expectEqual(machine.sessionID, "sess-1")
        try expectEqual(machine.sessionToken, "tok-1")
        try expectEqual(machine.peerDeviceID, "481930275", "the controller's peer is the host")
        try expect(machine.hasSession)
        try expect(machine.signalingUp)
        try expectEqual(machine.iceState, .new)

        _ = machine.iceStateChanged(to: .connected)
        try expectEqual(machine.iceState, .connected)
        try expectEqual(machine.phase, .live)
    },

    TestCase("a host reads back the opposite peer and never offers") {
        let machine = SessionStateMachine(role: .host)
        _ = machine.signalingAuthenticated(activeSessionID: nil)
        _ = machine.sessionGranted(grant())
        try expectFalse(machine.isOfferer, "handleRemoteSDP starts the peer with this")
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
        try expectEqual(prompt, [.promptForConsent(expiresAt: t0.addingTimeInterval(30))])
        try expectEqual(machine.phase, .awaitingConsent)
        try expectEqual(machine.consentExpiresAt, t0.addingTimeInterval(30))
        try expectEqual(SessionState(phase: machine.phase, sessionID: machine.sessionID), .connecting,
                        "waiting for the owner is not a session anyone is in yet")

        let allowed = machine.consentAnswered(allow: true, now: t0.addingTimeInterval(3))
        try expectEqual(allowed, [.dismissConsentPrompt(outcome: .allowed), .startPeerConnection(offerer: false)])
        try expectEqual(machine.consentExpiresAt, nil)
    },

    TestCase("only a declined or unanswered prompt counts against the controller") {
        try expect(ConsentOutcome.declined.countsAsDecline)
        try expect(ConsentOutcome.timedOut.countsAsDecline)
        try expectFalse(ConsentOutcome.allowed.countsAsDecline)
        try expectFalse(ConsentOutcome.cancelled.countsAsDecline, "a controller that hung up was not refused")
    },

    TestCase("the consent ledger round-trips through the core's policy") {
        let t0 = Date(timeIntervalSince1970: 1_756_000_000)
        var ledger = ConsentLedger()
        try expect(try ConsentPolicy.admit(ledger, now: t0).shouldPrompt)
        ledger = try ConsentPolicy.declined(ledger, now: t0).ledger
        try expect(try ConsentPolicy.admit(ledger, now: t0).shouldPrompt, "one decline still asks")
        let second = try ConsentPolicy.declined(ledger, now: t0.addingTimeInterval(60))
        try expectFalse(second.shouldPrompt, "two declines in ten minutes stop the prompts")
        try expectEqual(second.retryAfterMs, 9 * 60 * 1000)
        try expect(try ConsentPolicy.admit(second.ledger, now: t0.addingTimeInterval(600)).shouldPrompt,
                   "the window is ten minutes from the first decline")
        let cleared = try ConsentPolicy.allowed(second.ledger, now: t0.addingTimeInterval(61))
        try expect(cleared.shouldPrompt)
        try expectEqual(cleared.ledger, ConsentLedger())
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
