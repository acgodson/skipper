import Foundation
import RCTestKit
import RemoteControlCore

/// What `StateMachineScenarioTests.swift` cannot prove.
///
/// The rules of PROTOCOL.md §4 are pinned by the shared vectors, which now run
/// through the FFI, so nothing that a scenario already asserts is repeated here.
/// What is left is the part of the machine's Swift surface that the vectors do
/// not touch and `SessionCoordinator` depends on: the identity it reads back,
/// the remembered access code it consults before deciding to prompt, the
/// configured timings it passes in from `RCConfig`, and the phase summaries the
/// UI renders.

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
        try expect(machine.tick(now: t0.addingTimeInterval(11)).contains(.restartICE))

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
