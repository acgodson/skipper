import Foundation
import RCTestKit
import RemoteControlCore

private func grant(_ id: String = "sess-1", token: String = "tok-1",
                   host: String = "481930275", controller: String = "111222333") -> SessionGrantPayload {
    SessionGrantPayload(sessionId: id, sessionToken: token, expiresAt: 0, ttlSec: 600,
                        hostDeviceId: host, controllerDeviceId: controller)
}

private func resumeOK(_ id: String = "sess-1", token: String, peerAttached: Bool = true,
                      role: String = "controller") -> ResumeOKPayload {
    ResumeOKPayload(sessionId: id, sessionToken: token, expiresAt: 0, ttlSec: 600,
                    peerAttached: peerAttached, role: role)
}

/// Drives a controller all the way to a live session, so each test starts from
/// the state that actually matters.
private func liveController(remember: Bool = true) -> SessionStateMachine {
    var machine = SessionStateMachine(role: .controller, iceRestartDelay: 3, iceFailureGrace: 45, renewInterval: 300)
    _ = machine.signalingAuthenticated(activeSessionID: nil)
    _ = machine.connectRequested(deviceID: "481930275", accessCode: "K7FM3Q8PW2XY", remember: remember)
    _ = machine.sessionGranted(grant())
    _ = machine.iceStateChanged(to: .checking)
    _ = machine.iceStateChanged(to: .connected)
    return machine
}

private func contains(_ actions: [SessionAction], _ wanted: SessionAction) -> Bool {
    actions.contains(wanted)
}

private func containsResume(_ actions: [SessionAction]) -> Bool {
    actions.contains { if case .sendResume = $0 { return true }; return false }
}

private func containsConnectReq(_ actions: [SessionAction]) -> Bool {
    actions.contains { if case .sendConnectReq = $0 { return true }; return false }
}

public let stateMachineSuite = TestSuite("Session state machine (PROTOCOL.md §4)", [

    // ---- happy path -------------------------------------------------------

    TestCase("a controller connects, gets a grant, and becomes live when ICE connects") {
        var machine = SessionStateMachine(role: .controller)
        _ = machine.signalingAuthenticated(activeSessionID: nil)
        let connect = machine.connectRequested(deviceID: "481930275", accessCode: "K7FM3Q8PW2XY", remember: false)
        try expect(contains(connect, .sendConnectReq(deviceID: "481930275", accessCode: "K7FM3Q8PW2XY")))
        try expectEqual(machine.phase, .connecting)

        let granted = machine.sessionGranted(grant())
        try expect(contains(granted, .startPeerConnection(offerer: true)), "the controller is always the offerer")
        try expectEqual(machine.sessionID, "sess-1")
        try expectEqual(machine.sessionToken, "tok-1")
        try expectEqual(machine.peerDeviceID, "481930275")

        _ = machine.iceStateChanged(to: .checking)
        try expectEqual(machine.phase, .connecting, "checking is not yet live")
        _ = machine.iceStateChanged(to: .connected)
        try expectEqual(machine.phase, .live)
    },

    TestCase("the host is never the offerer for the initial negotiation") {
        var machine = SessionStateMachine(role: .host)
        _ = machine.signalingAuthenticated(activeSessionID: nil)
        let actions = machine.sessionGranted(grant())
        try expect(contains(actions, .startPeerConnection(offerer: false)))
        try expectFalse(machine.isOfferer)
    },

    TestCase("a client must not connect_req for a session it believes is alive (§4.4)") {
        var machine = liveController()
        let actions = machine.connectRequested(deviceID: "999888777", accessCode: "AAAAAAAAAAAA", remember: false)
        try expect(actions.isEmpty, "got \(actions)")
        try expectEqual(machine.sessionID, "sess-1", "the live session must not be replaced")
    },

    // ---- §4.3 step 1: a signaling drop tears down nothing ------------------

    TestCase("losing the signaling socket does NOT tear down the peer connection") {
        var machine = liveController()
        let actions = machine.signalingLost()
        try expectFalse(contains(actions, .teardownPeerConnection),
                        "a control-plane outage must never touch media — got \(actions)")
        try expectFalse(contains(actions, .clearStoredSession))
        try expect(machine.hasSession, "the session must survive the socket")
        try expectEqual(machine.phase, .live,
                        "with ICE still up the UI must keep saying Connected, not Reconnecting")
    },

    TestCase("if media is ALSO down, the UI says Reconnecting — never Disconnected") {
        var machine = liveController()
        _ = machine.iceStateChanged(to: .disconnected)
        _ = machine.signalingLost()
        try expectEqual(machine.phase, .reconnecting)
        try expect(machine.hasSession)
    },

    // ---- §4.3 step 3: resume, never connect_req ---------------------------

    TestCase("on reconnect the client resumes and NEVER sends connect_req") {
        var machine = liveController()
        _ = machine.signalingLost()
        let actions = machine.signalingAuthenticated(activeSessionID: "sess-1")
        try expect(contains(actions, .sendResume(sessionID: "sess-1", sessionToken: "tok-1")))
        try expectFalse(containsConnectReq(actions), "the access code must not be re-sent — got \(actions)")
    },

    TestCase("a resume is sent even when hello_ok carries no activeSessionId") {
        var machine = liveController()
        _ = machine.signalingLost()
        try expect(containsResume(machine.signalingAuthenticated(activeSessionID: nil)))
    },

    // ---- §4.4: never two resumes in flight --------------------------------

    TestCase("two resumes are never in flight at once") {
        var machine = liveController()
        _ = machine.signalingLost()
        let first = machine.signalingAuthenticated(activeSessionID: "sess-1")
        try expect(containsResume(first))
        try expect(machine.resumeInFlight)

        // Anything that could re-trigger a resume while one is outstanding must not.
        try expectFalse(containsResume(machine.signalingAuthenticated(activeSessionID: "sess-1")),
                        "a second hello_ok must not start a second resume")
        try expectFalse(containsResume(machine.tick(now: Date().addingTimeInterval(60))),
                        "a tick must not start a second resume")

        _ = machine.resumeSucceeded(resumeOK(token: "tok-2"))
        try expectFalse(machine.resumeInFlight)
    },

    TestCase("a failed resume clears the in-flight flag so the next one can go") {
        var machine = liveController()
        _ = machine.signalingLost()
        _ = machine.signalingAuthenticated(activeSessionID: "sess-1")
        try expect(machine.resumeInFlight)
        _ = machine.resumeFailed(code: "network", retryAfterSec: 0)
        try expectFalse(machine.resumeInFlight)
        try expect(machine.hasSession, "a transient failure must not destroy the session")
        try expect(containsResume(machine.signalingAuthenticated(activeSessionID: "sess-1")))
    },

    // ---- §4.4: token rotation ---------------------------------------------

    TestCase("resume_ok rotates the stored token, and the next resume uses the new one") {
        var machine = liveController()
        try expectEqual(machine.sessionToken, "tok-1")
        _ = machine.signalingLost()
        _ = machine.signalingAuthenticated(activeSessionID: "sess-1")
        _ = machine.resumeSucceeded(resumeOK(token: "tok-2"))
        try expectEqual(machine.sessionToken, "tok-2", "the old token is dead the moment resume_ok arrives")

        _ = machine.signalingLost()
        let actions = machine.signalingAuthenticated(activeSessionID: "sess-1")
        try expect(contains(actions, .sendResume(sessionID: "sess-1", sessionToken: "tok-2")),
                   "a stale token would be answered with bad_token — got \(actions)")
    },

    TestCase("renew_ok rotates the token too, and only for the right session") {
        var machine = liveController()
        machine.renewSucceeded(RenewOKPayload(sessionId: "sess-1", sessionToken: "tok-9", expiresAt: 0, ttlSec: 600))
        try expectEqual(machine.sessionToken, "tok-9")
        machine.renewSucceeded(RenewOKPayload(sessionId: "other", sessionToken: "wrong", expiresAt: 0, ttlSec: 600))
        try expectEqual(machine.sessionToken, "tok-9", "a renew_ok for another session must be ignored")
    },

    TestCase("renew fires on schedule and not before") {
        let start = Date()
        var machine = liveController()
        _ = machine.sessionGranted(grant(token: "tok-1"), now: start)
        _ = machine.iceStateChanged(to: .connected, now: start)

        let early = machine.tick(now: start.addingTimeInterval(299))
        try expectFalse(early.contains { if case .sendRenew = $0 { return true }; return false })

        let due = machine.tick(now: start.addingTimeInterval(301))
        try expect(due.contains { if case .sendRenew = $0 { return true }; return false },
                   "PROTOCOL.md §2.11: renew every 5 minutes while connected")
    },

    // ---- §4.3 steps 5 and 6, plus the server-restart rule -----------------

    TestCase("no_session with NO remembered code is the only path that prompts") {
        var machine = liveController(remember: false)
        _ = machine.signalingLost()
        _ = machine.signalingAuthenticated(activeSessionID: "sess-1")
        let actions = machine.resumeFailed(code: "no_session", retryAfterSec: 0)
        try expect(contains(actions, .teardownPeerConnection))
        try expect(contains(actions, .clearStoredSession))
        try expect(contains(actions, .promptForAccessCode(reason: "no_session")))
        try expectFalse(machine.hasSession)
        try expectEqual(machine.phase, .idle)
    },

    TestCase("bad_token behaves identically to no_session") {
        var machine = liveController(remember: false)
        _ = machine.signalingLost()
        _ = machine.signalingAuthenticated(activeSessionID: "sess-1")
        let actions = machine.resumeFailed(code: "bad_token", retryAfterSec: 0)
        try expect(contains(actions, .promptForAccessCode(reason: "bad_token")))
    },

    TestCase("SERVER RESTART: no_session with a remembered code reconnects SILENTLY") {
        var machine = liveController(remember: true)
        _ = machine.signalingLost()
        _ = machine.signalingAuthenticated(activeSessionID: nil)
        let actions = machine.resumeFailed(code: "no_session", retryAfterSec: 0)
        try expect(contains(actions, .sendConnectReq(deviceID: "481930275", accessCode: "K7FM3Q8PW2XY")),
                   "a remembered code must be reused rather than shown to the user — got \(actions)")
        try expectFalse(actions.contains { if case .promptForAccessCode = $0 { return true }; return false },
                        "prompting is only correct when there is no remembered code")
        try expect(contains(actions, .teardownPeerConnection), "the dead session's peer connection must go")
        try expectEqual(machine.phase, .connecting)
    },

    TestCase("a host never silently re-connects; it has no code to offer") {
        var machine = SessionStateMachine(role: .host)
        _ = machine.signalingAuthenticated(activeSessionID: nil)
        _ = machine.sessionGranted(grant())
        _ = machine.signalingLost()
        _ = machine.signalingAuthenticated(activeSessionID: "sess-1")
        let actions = machine.resumeFailed(code: "no_session", retryAfterSec: 0)
        try expectFalse(containsConnectReq(actions), "a host cannot initiate; got \(actions)")
        try expect(contains(actions, .teardownPeerConnection))
    },

    TestCase("rate_limited backs off exactly as told and does not prompt") {
        var machine = liveController(remember: false)
        _ = machine.signalingLost()
        _ = machine.signalingAuthenticated(activeSessionID: "sess-1")
        let actions = machine.resumeFailed(code: "rate_limited", retryAfterSec: 240)
        try expect(contains(actions, .scheduleResume(afterSec: 240)))
        try expectFalse(actions.contains { if case .promptForAccessCode = $0 { return true }; return false })
        try expect(machine.hasSession, "rate limiting is not the end of the session")
    },

    // ---- §4.3 step 4 ------------------------------------------------------

    TestCase("resume_ok re-issues watches and sends input_reset, always") {
        var machine = liveController()
        _ = machine.signalingLost()
        _ = machine.signalingAuthenticated(activeSessionID: "sess-1")
        let actions = machine.resumeSucceeded(resumeOK(token: "tok-2"))
        try expect(contains(actions, .reissueWatches), "watches are per-connection (§2.7)")
        try expect(contains(actions, .sendInputReset), "§4.4: after EVERY resume")
    },

    TestCase("resume_ok with ICE already up does not order a needless restart") {
        var machine = liveController()
        _ = machine.signalingLost()
        _ = machine.signalingAuthenticated(activeSessionID: "sess-1")
        let actions = machine.resumeSucceeded(resumeOK(token: "tok-2"))
        try expectFalse(contains(actions, .restartICE), "media never dropped; got \(actions)")
        try expectEqual(machine.phase, .live)
    },

    TestCase("resume_ok with ICE down orders an ICE restart from the controller") {
        var machine = liveController()
        _ = machine.iceStateChanged(to: .disconnected)
        _ = machine.signalingLost()
        _ = machine.signalingAuthenticated(activeSessionID: "sess-1")
        let actions = machine.resumeSucceeded(resumeOK(token: "tok-2"))
        try expect(contains(actions, .restartICE))
        try expectEqual(machine.phase, .reconnecting)
    },

    TestCase("a HOST does not offer the restart by default; the controller does") {
        var machine = SessionStateMachine(role: .host)
        _ = machine.signalingAuthenticated(activeSessionID: nil)
        _ = machine.sessionGranted(grant())
        _ = machine.iceStateChanged(to: .connected)
        _ = machine.iceStateChanged(to: .disconnected)
        _ = machine.signalingLost()
        _ = machine.signalingAuthenticated(activeSessionID: "sess-1")
        let actions = machine.resumeSucceeded(resumeOK(token: "t", role: "host"))
        try expectFalse(contains(actions, .restartICE), "§4.3: the controller restarts by default")
        try expect(contains(actions, .sendInputReset))
    },

    // ---- ICE timing (PLAN.md §2.1) ----------------------------------------

    TestCase("ICE disconnected holds the session and restarts after exactly 3s") {
        let t0 = Date()
        var machine = liveController()
        let dropped = machine.iceStateChanged(to: .disconnected, now: t0)
        try expectEqual(machine.phase, .reconnecting)
        try expect(machine.hasSession, "disconnected must never close the session")
        try expect(contains(dropped, .sendInputReset), "§4.4: after every detected disconnect")

        try expect(machine.tick(now: t0.addingTimeInterval(2.9)).isEmpty,
                   "a restart before 3s would fight a link that is about to recover")
        try expect(contains(machine.tick(now: t0.addingTimeInterval(3.1)), .restartICE))
        // ...and only once.
        try expectFalse(contains(machine.tick(now: t0.addingTimeInterval(10)), .restartICE))
    },

    TestCase("a link that recovers before 3s never restarts, and goes straight back to live") {
        let t0 = Date()
        var machine = liveController()
        _ = machine.iceStateChanged(to: .disconnected, now: t0)
        let recovered = machine.iceStateChanged(to: .connected, now: t0.addingTimeInterval(1.5))
        try expectEqual(machine.phase, .live)
        try expect(contains(recovered, .sendInputReset))
        try expect(machine.tick(now: t0.addingTimeInterval(30)).isEmpty, "no restart is owed any more")
    },

    TestCase("failed alone does not close the session; failed plus 45s does") {
        let t0 = Date()
        var machine = liveController()
        _ = machine.iceStateChanged(to: .failed, now: t0)
        try expect(machine.hasSession)
        try expectEqual(machine.phase, .reconnecting)

        try expect(machine.tick(now: t0.addingTimeInterval(44)).isEmpty,
                   "44 seconds in, the session is still alive")
        try expect(machine.hasSession)

        let closed = machine.tick(now: t0.addingTimeInterval(45.5))
        try expect(closed.contains { if case .sendBye = $0 { return true }; return false },
                   "the grace window expiring must tell the server; got \(closed)")
        try expect(contains(closed, .teardownPeerConnection))
        try expectFalse(machine.hasSession)
        try expectEqual(machine.phase, .closed(reason: "failed"))
    },

    TestCase("recovering inside the 45s grace window keeps the session") {
        let t0 = Date()
        var machine = liveController()
        _ = machine.iceStateChanged(to: .failed, now: t0)
        _ = machine.iceStateChanged(to: .connected, now: t0.addingTimeInterval(30))
        try expectEqual(machine.phase, .live)
        try expect(machine.tick(now: t0.addingTimeInterval(120)).isEmpty)
        try expect(machine.hasSession)
    },

    // ---- input_reset ------------------------------------------------------

    TestCase("input_reset is emitted on every disconnect edge and every resume, idempotently") {
        let t0 = Date()
        var machine = liveController()
        var resets = 0
        func count(_ actions: [SessionAction]) { resets += actions.filter { $0 == .sendInputReset }.count }

        count(machine.iceStateChanged(to: .disconnected, now: t0))          // 1
        count(machine.iceStateChanged(to: .connected, now: t0.addingTimeInterval(1)))  // 2
        count(machine.signalingLost())                                       // 0
        count(machine.signalingAuthenticated(activeSessionID: "sess-1"))     // 0
        count(machine.resumeSucceeded(resumeOK(token: "tok-2")))             // 3
        try expectEqual(resets, 3)

        // Idempotence at the transport layer: sending it twice is harmless, and
        // sending it with no channel open is a no-op rather than an error.
        let peer = PeerSession(iceServers: [], isOfferer: true)
        try expectFalse(peer.sendInputReset(), "no channel yet, so nothing is sent")
        try expectFalse(peer.sendInputReset(), "and it stays a no-op, never a throw")
    },

    // ---- endings ----------------------------------------------------------

    TestCase("the local user ending a session tells the server and clears everything") {
        var machine = liveController()
        let actions = machine.userEnded()
        try expect(contains(actions, .sendBye(sessionID: "sess-1", reason: "user_ended")))
        try expect(contains(actions, .teardownPeerConnection))
        try expect(contains(actions, .clearStoredSession))
        try expectFalse(machine.hasSession)
        try expectEqual(machine.phase, .closed(reason: "user_ended"))
    },

    TestCase("a bye from the peer closes the same way, with the peer's reason") {
        var machine = liveController()
        let actions = machine.closeLocally(reason: "code_refreshed")
        try expect(contains(actions, .teardownPeerConnection))
        try expectEqual(machine.phase, .closed(reason: "code_refreshed"))
        try expectFalse(machine.hasSession)
        // A closed session must not resume itself back to life.
        try expect(machine.signalingAuthenticated(activeSessionID: "sess-1").isEmpty)
    },

    TestCase("closing after the session is already gone does not crash or send bye") {
        var machine = SessionStateMachine(role: .controller)
        try expect(machine.userEnded().isEmpty)
        try expectEqual(machine.phase, .idle)
    },

    TestCase("the UI states are all distinct — Reconnecting is not Disconnected") {
        try expectNotEqual(SessionPhase.reconnecting.summary, SessionPhase.closed(reason: "failed").summary)
        try expectNotEqual(SessionPhase.reconnecting.summary, SessionPhase.idle.summary)
        try expectEqual(SessionPhase.reconnecting.summary, "Reconnecting\u{2026}")
        try expectEqual(SessionPhase.live.summary, "Connected")
    },
])

// MARK: - The "already has a remote session" dead end

/// Regression tests for the bug that blocked this user THREE times in real use
/// and each time needed a server restart to clear.
///
/// Setup: the app is restarted (or replaced), so the in-memory session token is
/// gone, but the server still holds a live session for this device and reports it
/// as `activeSessionId`. Resume is impossible without the token; `connect_req` is
/// refused with `busy` by the device's own session. The old code ignored
/// `activeSessionId` unless a token was present and fell straight through to
/// `connect_req`, leaving no way out from inside the app.
public let staleSessionSuite = TestSuite("StaleSessionRecovery", [

    TestCase("a session we own but cannot resume is discarded, not surfaced as busy") {
        var machine = SessionStateMachine(role: .controller)
        machine.rememberedAccessCode = "AAAA-BBBB-CCCC"
        _ = machine.connectRequested(deviceID: "739000587", accessCode: "AAAA-BBBB-CCCC", remember: true)

        // No token: this is a fresh process that inherited nothing.
        let actions = machine.signalingAuthenticated(activeSessionID: "stale-session-id")

        // It must throw the unusable session away...
        try expect(actions.contains(.sendBye(sessionID: "stale-session-id", reason: "stale_no_token")))
        // ...and must NOT try to resume, which cannot work without a token.
        for action in actions {
            if case .sendResume = action { throw TestFailure(message: "resumed without a token") }
        }
    },

    TestCase("busy against our own session clears it and retries exactly once") {
        var machine = SessionStateMachine(role: .controller)
        _ = machine.connectRequested(deviceID: "739000587", accessCode: "AAAA-BBBB-CCCC", remember: false)
        _ = machine.signalingAuthenticated(activeSessionID: "mine-123")

        let first = machine.connectFailed(code: "busy")
        try expect(first.contains(.sendBye(sessionID: "mine-123", reason: "stale_no_token")))
        try expect(first.contains(.sendConnectReq(deviceID: "739000587", accessCode: "AAAA-BBBB-CCCC")))

        // A SECOND busy is a real conflict — someone else is genuinely connected.
        // Retrying again would be an infinite loop, so it must surface instead.
        let second = machine.connectFailed(code: "busy")
        try expectEqual(second, [])
        try expectEqual(machine.phase, .closed(reason: "busy"))
    },

    TestCase("busy with no advertised session is someone else's and is surfaced") {
        var machine = SessionStateMachine(role: .controller)
        _ = machine.connectRequested(deviceID: "739000587", accessCode: "AAAA-BBBB-CCCC", remember: false)
        _ = machine.signalingAuthenticated(activeSessionID: nil)

        // Nothing of ours to clear: do not send bye for a session we do not own.
        let actions = machine.connectFailed(code: "busy")
        try expectEqual(actions, [])
        try expectEqual(machine.phase, .closed(reason: "busy"))
    },

    TestCase("a resumable session still resumes and is never discarded") {
        var machine = SessionStateMachine(role: .controller)
        _ = machine.sessionGranted(grant("live-1", token: "tok-1", host: "739000587"))

        let actions = machine.signalingAuthenticated(activeSessionID: "live-1")
        try expect(actions.contains(.sendResume(sessionID: "live-1", sessionToken: "tok-1")))
        for action in actions {
            if case .sendBye = action { throw TestFailure(message: "discarded a session it could have resumed") }
        }
    },
])
