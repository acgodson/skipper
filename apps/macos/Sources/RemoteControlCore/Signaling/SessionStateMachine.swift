import Foundation

/// ICE connection states we care about, decoupled from libwebrtc's enum so this
/// file can be unit-tested without a peer connection.
public enum ICELinkState: String, Equatable {
    case new
    case checking
    case connected
    case completed
    case disconnected
    case failed
    case closed

    public var isUp: Bool { self == .connected || self == .completed }
}

/// What the UI shows. `reconnecting` is deliberately distinct from `closed`:
/// PLAN.md §2.1 says a wobble must never look like a dead session.
public enum SessionPhase: Equatable {
    case idle
    case connecting
    case live
    case reconnecting
    case closed(reason: String)

    public var summary: String {
        switch self {
        case .idle: return "Not connected"
        case .connecting: return "Connecting\u{2026}"
        case .live: return "Connected"
        case .reconnecting: return "Reconnecting\u{2026}"
        case .closed(let reason): return "Disconnected (\(reason))"
        }
    }
}

/// The side effects the machine asks its owner to perform. Returning them rather
/// than performing them is what makes PROTOCOL.md §4 testable without a network.
public enum SessionAction: Equatable {
    case sendConnectReq(deviceID: String, accessCode: String)
    case sendResume(sessionID: String, sessionToken: String)
    /// Retry `resume` after a server-mandated delay (§4.3 step 6).
    case scheduleResume(afterSec: Int)
    case sendRenew(sessionID: String, sessionToken: String)
    /// PROTOCOL.md §4.4: after every resume and every detected disconnect.
    case sendInputReset
    case startPeerConnection(offerer: Bool)
    case restartICE
    case reissueWatches
    case teardownPeerConnection
    case clearStoredSession
    /// The ONLY action that may put the access-code prompt back on screen
    /// (§4.3 step 5).
    case promptForAccessCode(reason: String)
    case sendBye(sessionID: String, reason: String)
}

/// PROTOCOL.md §4 as executable code.
///
/// It owns the session identity (id + newest token), the phase the UI shows, and
/// every rule about what a signaling drop, an ICE wobble or a failed `resume`
/// means. It performs no I/O and holds no timers of its own: the owner calls
/// `tick(now:)` and the machine decides when the 3-second ICE-restart delay and
/// the 45-second failure grace have elapsed.
public struct SessionStateMachine {

    // MARK: Configuration

    public var iceRestartDelay: TimeInterval
    public var iceFailureGrace: TimeInterval
    public var renewInterval: TimeInterval

    // MARK: Identity of the session

    public private(set) var role: Wire.Role
    public private(set) var sessionID: String?
    /// The newest token. Rotated on every `resume_ok` / `renew_ok`; PROTOCOL.md
    /// §4.4 says losing it means losing the resume path.
    public private(set) var sessionToken: String?
    public private(set) var peerDeviceID: String?
    /// The access code the controller may silently reuse. Present only when the
    /// user chose Remember; without it a dead session must prompt.
    public var rememberedAccessCode: String?
    /// The code the user just typed for a connect that has not completed yet.
    private var pendingAccessCode: String?

    // MARK: Observable state

    public private(set) var phase: SessionPhase = .idle
    public private(set) var signalingUp = false
    public private(set) var iceState: ICELinkState = .new
    /// PROTOCOL.md §4.4: "Clients must not have two `resume`s in flight."
    public private(set) var resumeInFlight = false

    private var disconnectedSince: Date?
    private var failedSince: Date?
    private var iceRestartRequested = false
    private var lastRenew: Date?
    /// Set when a resume has been asked for but the socket was not up yet.
    private var resumeWanted = false

    public init(
        role: Wire.Role,
        iceRestartDelay: TimeInterval = 3,
        iceFailureGrace: TimeInterval = 45,
        renewInterval: TimeInterval = 300
    ) {
        self.role = role
        self.iceRestartDelay = iceRestartDelay
        self.iceFailureGrace = iceFailureGrace
        self.renewInterval = renewInterval
    }

    /// The controller offers by default, both for the first negotiation
    /// (PROTOCOL.md §2.9) and for ICE restarts (§4.3 step 4).
    public var isOfferer: Bool { role == .controller }

    public var hasSession: Bool { sessionID != nil && sessionToken != nil }

    // MARK: - Controller-initiated connect

    /// The user pressed Connect. Only legal from `idle`/`closed`; a client must
    /// never `connect_req` for a session it believes is alive (§4.4).
    public mutating func connectRequested(deviceID: String, accessCode: String, remember: Bool) -> [SessionAction] {
        guard !hasSession else { return [] }
        peerDeviceID = deviceID
        pendingAccessCode = accessCode
        if remember { rememberedAccessCode = accessCode }
        phase = .connecting
        guard signalingUp else { return [] }   // sent as soon as the socket is up
        return [.sendConnectReq(deviceID: deviceID, accessCode: accessCode)]
    }

    /// `connect_ok` (controller) or `session_start` (host).
    public mutating func sessionGranted(_ grant: SessionGrantPayload, now: Date = Date()) -> [SessionAction] {
        sessionID = grant.sessionId
        sessionToken = grant.sessionToken
        peerDeviceID = (role == .controller) ? grant.hostDeviceId : grant.controllerDeviceId
        if role == .host { rememberedAccessCode = nil }
        pendingAccessCode = nil
        phase = .connecting
        lastRenew = now
        iceRestartRequested = false
        return [.startPeerConnection(offerer: isOfferer)]
    }

    /// `serverAdvertisedSessionID` is whatever the last `hello_ok` said we own.
    /// Kept so a `busy` can be recognised as OUR session rather than a stranger's.
    public var serverAdvertisedSessionID: String?
    /// One-shot guard: clear a stale session and retry at most once, so a genuine
    /// `busy` from a real second controller can never become a retry loop.
    private var clearedStaleSession = false

    public mutating func connectFailed(code: String) -> [SessionAction] {
        // `busy` caused by OUR OWN unusable session is recoverable, and it is the
        // single failure that has actually blocked this user in practice.
        // PROTOCOL.md §4.4 says recover with `resume` — but that needs a token we
        // no longer have, so we discard the session instead and connect fresh.
        // `bye` is authorised by device identity server-side, so we may close it.
        if code == "busy", !clearedStaleSession,
           let stale = serverAdvertisedSessionID,
           let peer = peerDeviceID,
           let accessCode = pendingAccessCode ?? rememberedAccessCode {
            clearedStaleSession = true
            serverAdvertisedSessionID = nil
            return [.sendBye(sessionID: stale, reason: "stale_no_token"),
                    .sendConnectReq(deviceID: peer, accessCode: accessCode)]
        }
        pendingAccessCode = nil
        phase = .closed(reason: code)
        return []
    }

    // MARK: - Signaling transitions (PROTOCOL.md §4.3)

    /// Step 1: the control plane died. **Nothing is torn down.** Media over an
    /// established WebRTC path keeps flowing; the UI only says "Reconnecting…"
    /// if the media path is also down.
    public mutating func signalingLost() -> [SessionAction] {
        signalingUp = false
        resumeInFlight = false
        if hasSession {
            resumeWanted = true
            if !iceState.isUp { phase = .reconnecting }
        } else if case .connecting = phase {
            // Keep waiting; the connect_req is re-sent once the socket is back.
        }
        return []
    }

    /// Steps 3: the socket is back and authenticated.
    public mutating func signalingAuthenticated(activeSessionID: String?) -> [SessionAction] {
        signalingUp = true
        serverAdvertisedSessionID = activeSessionID

        // The server telling us a session is live is authoritative even if we
        // somehow lost our own copy of the id.
        if sessionID == nil, let activeSessionID, sessionToken != nil {
            sessionID = activeSessionID
        }

        // THE DEAD END, fixed (PROTOCOL.md §4.4).
        //
        // The server says WE own a live session, but we hold no token for it —
        // the app was restarted, or replaced, so the token died with the
        // process. We cannot `resume` without a token, and `connect_req` is
        // refused with `busy` by our own session. That left the user stuck on
        // "this Mac already has a remote session" with no way out; in practice
        // it needed a server restart to clear, three times.
        //
        // A session we own but cannot use is rubbish, so throw it away. `bye` is
        // authorised by DEVICE IDENTITY server-side (hub.handleByeLocked checks
        // `s.sideFor(c.deviceID)`), not by the session token — so we are allowed
        // to close our own session even having lost the token. Then connect
        // normally.
        // Only while actually trying to connect. A session the user deliberately
        // ended is none of our business — re-`bye`ing it would be noise, and
        // touching a closed session at all risks bringing it back to life.
        if case .connecting = phase,
           sessionID == nil, sessionToken == nil,
           let stale = activeSessionID,
           let peer = peerDeviceID,
           let code = pendingAccessCode ?? rememberedAccessCode {
            return [.sendBye(sessionID: stale, reason: "stale_no_token"),
                    .sendConnectReq(deviceID: peer, accessCode: code)]
        }

        if hasSession {
            resumeWanted = true
            return beginResumeIfPossible()
        }
        if case .connecting = phase, let peer = peerDeviceID,
           let code = pendingAccessCode ?? rememberedAccessCode {
            return [.sendConnectReq(deviceID: peer, accessCode: code)]
        }
        return []
    }

    private mutating func beginResumeIfPossible() -> [SessionAction] {
        guard resumeWanted, signalingUp, !resumeInFlight,
              let id = sessionID, let token = sessionToken else { return [] }
        resumeInFlight = true
        resumeWanted = false
        return [.sendResume(sessionID: id, sessionToken: token)]
    }

    /// Step 4. Token rotation, watch re-issue, `input_reset`, and an ICE restart
    /// if the media path is not already up.
    public mutating func resumeSucceeded(_ ok: ResumeOKPayload, now: Date = Date()) -> [SessionAction] {
        resumeInFlight = false
        sessionID = ok.sessionId
        sessionToken = ok.sessionToken          // rotated: the old one is dead
        lastRenew = now
        var actions: [SessionAction] = [.reissueWatches, .sendInputReset]
        if !iceState.isUp {
            phase = .reconnecting
            if isOfferer {
                iceRestartRequested = true
                actions.append(.restartICE)
            }
        } else {
            phase = .live
        }
        return actions
    }

    /// Step 5 and 6, plus the rule this project adds on top of PROTOCOL.md: if
    /// the SERVER restarted, every session died and `resume` legitimately returns
    /// `no_session`. A controller holding a remembered code must silently
    /// re-`connect_req`; prompting is only correct when there is no such code.
    public mutating func resumeFailed(code: String, retryAfterSec: Int) -> [SessionAction] {
        resumeInFlight = false

        if code == Wire.ErrorCode.rateLimited {
            resumeWanted = true
            return [.scheduleResume(afterSec: max(retryAfterSec, 1))]
        }

        // Anything other than no_session/bad_token is transient: keep the
        // session and try again when the socket next comes up.
        guard code == Wire.ErrorCode.noSession || code == Wire.ErrorCode.badToken else {
            resumeWanted = true
            return []
        }

        sessionID = nil
        sessionToken = nil
        iceRestartRequested = false
        disconnectedSince = nil
        failedSince = nil

        if role == .controller, let peer = peerDeviceID, let code = rememberedAccessCode {
            phase = .connecting
            var actions: [SessionAction] = [.teardownPeerConnection, .clearStoredSession]
            if signalingUp { actions.append(.sendConnectReq(deviceID: peer, accessCode: code)) }
            return actions
        }

        phase = .idle
        return [.teardownPeerConnection, .clearStoredSession,
                .promptForAccessCode(reason: code)]
    }

    // MARK: - ICE transitions (PLAN.md §2.1)

    public mutating func iceStateChanged(to newState: ICELinkState, now: Date = Date()) -> [SessionAction] {
        let previous = iceState
        iceState = newState
        guard hasSession else { return [] }

        switch newState {
        case .connected, .completed:
            disconnectedSince = nil
            failedSince = nil
            iceRestartRequested = false
            phase = .live
            // A media path that just came back may be on the other side of a
            // gap in which keys were logically held down.
            return previous.isUp ? [] : [.sendInputReset]

        case .disconnected:
            if disconnectedSince == nil { disconnectedSince = now }
            failedSince = nil
            phase = .reconnecting
            return [.sendInputReset]

        case .failed:
            if failedSince == nil { failedSince = now }
            phase = .reconnecting
            return [.sendInputReset]

        case .closed:
            return []

        case .new, .checking:
            return []
        }
    }

    /// Drives the two time-based rules. Call at least once a second.
    public mutating func tick(now: Date = Date()) -> [SessionAction] {
        var actions: [SessionAction] = []
        guard hasSession else { return actions }

        // "On `disconnected`, hold the session and start an ICE restart after 3s."
        if let since = disconnectedSince, !iceRestartRequested,
           now.timeIntervalSince(since) >= iceRestartDelay {
            iceRestartRequested = true
            if isOfferer { actions.append(.restartICE) }
        }

        // "Only `failed` PLUS a 45s grace window closes the session."
        if let since = failedSince, now.timeIntervalSince(since) >= iceFailureGrace {
            let id = sessionID
            actions.append(contentsOf: closeLocally(reason: Wire.ByeReason.failed))
            if let id { actions.append(.sendBye(sessionID: id, reason: Wire.ByeReason.failed)) }
            return actions
        }

        // Renew every 5 minutes while a session is live, so a drop at minute 59
        // is still resumable (PROTOCOL.md §2.11).
        if signalingUp, !resumeInFlight, let id = sessionID, let token = sessionToken,
           let last = lastRenew, now.timeIntervalSince(last) >= renewInterval {
            lastRenew = now
            actions.append(.sendRenew(sessionID: id, sessionToken: token))
        }

        // A resume that could not be sent when the socket came up.
        actions.append(contentsOf: beginResumeIfPossible())
        return actions
    }

    /// `renew_ok` — token rotated, same rules as resume.
    public mutating func renewSucceeded(_ ok: RenewOKPayload, now: Date = Date()) {
        guard ok.sessionId == sessionID else { return }
        sessionToken = ok.sessionToken
        lastRenew = now
    }

    public mutating func renewFailed(code: String, now: Date = Date()) -> [SessionAction] {
        // A renew failure is not itself terminal — the resume path is what
        // matters — but no_session/bad_token mean the session is genuinely gone.
        guard code == Wire.ErrorCode.noSession || code == Wire.ErrorCode.badToken else { return [] }
        return resumeFailed(code: code, retryAfterSec: 0)
    }

    // MARK: - Endings

    /// The peer or the server said `bye`, or the local user ended it.
    public mutating func closeLocally(reason: String) -> [SessionAction] {
        sessionID = nil
        sessionToken = nil
        pendingAccessCode = nil
        resumeInFlight = false
        resumeWanted = false
        disconnectedSince = nil
        failedSince = nil
        iceRestartRequested = false
        iceState = .closed
        phase = .closed(reason: reason)
        return [.sendInputReset, .teardownPeerConnection, .clearStoredSession]
    }

    /// The local user pressed End Session / Disconnect.
    public mutating func userEnded(reason: String = Wire.ByeReason.userEnded) -> [SessionAction] {
        guard let id = sessionID else {
            phase = .idle
            return []
        }
        var actions: [SessionAction] = [.sendBye(sessionID: id, reason: reason)]
        actions.append(contentsOf: closeLocally(reason: reason))
        return actions
    }
}
