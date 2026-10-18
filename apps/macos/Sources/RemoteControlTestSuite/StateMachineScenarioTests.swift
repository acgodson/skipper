import Foundation
import RCTestKit
import RemoteControlCore

private struct Scenarios: Decodable {
    let version: Int
    let scenarios: [Scenario]
}

private struct Scenario: Decodable {
    let name: String
    let role: String
    let steps: [Step]
}

private struct Step: Decodable {
    let at: Double
    let `do`: [String: JSONValue]
    let expectActions: [[String: JSONValue]]?
    let expectPhase: String?
    let expectHasSession: Bool?
    let expectResumeInFlight: Bool?
    let expectRelayOnly: Bool?
    let expectConsentRequired: Bool?
    let expectRejected: Bool?
    let expectPeerStarted: Bool?
    let expectPeerDeviceId: String?
}

private enum JSONValue: Decodable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case null

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let b = try? c.decode(Bool.self) { self = .bool(b) }
        else if let n = try? c.decode(Double.self) { self = .number(n) }
        else if let s = try? c.decode(String.self) { self = .string(s) }
        else { throw fail("unsupported JSON value in scenarios") }
    }

    var string: String? { if case .string(let s) = self { return s }; return nil }
    var number: Double? { if case .number(let n) = self { return n }; return nil }
    var boolean: Bool? { if case .bool(let b) = self { return b }; return nil }
}

private func scenariosURL() -> URL {
    if let override = ProcessInfo.processInfo.environment["RC_SCENARIOS_PATH"] {
        return URL(fileURLWithPath: override)
    }
    return protocolVectorURL("session-scenarios.json")
}

private func string(_ obj: [String: JSONValue], _ key: String, _ ctx: String) throws -> String {
    guard let v = obj[key]?.string else { throw fail("\(ctx): missing string \(key)") }
    return v
}

private func action(from obj: [String: JSONValue], _ ctx: String) throws -> SessionAction {
    switch try string(obj, "action", ctx) {
    case "sendConnectReq":
        return .sendConnectReq(deviceID: try string(obj, "deviceId", ctx),
                               accessCode: try string(obj, "accessCode", ctx))
    case "sendResume":
        return .sendResume(sessionID: try string(obj, "sessionId", ctx),
                           sessionToken: try string(obj, "sessionToken", ctx))
    case "scheduleResume":
        guard let sec = obj["afterSec"]?.number else { throw fail("\(ctx): afterSec") }
        return .scheduleResume(afterSec: Int(sec))
    case "sendRenew":
        return .sendRenew(sessionID: try string(obj, "sessionId", ctx),
                          sessionToken: try string(obj, "sessionToken", ctx))
    case "sendInputReset": return .sendInputReset
    case "startPeerConnection":
        guard let offerer = obj["offerer"]?.boolean else { throw fail("\(ctx): offerer") }
        return .startPeerConnection(offerer: offerer)
    case "restartICE":
        guard let relayOnly = obj["relayOnly"]?.boolean else { throw fail("\(ctx): relayOnly") }
        return .restartICE(relayOnly: relayOnly)
    case "reissueWatches": return .reissueWatches
    case "teardownPeerConnection": return .teardownPeerConnection
    case "clearStoredSession": return .clearStoredSession
    case "promptForAccessCode":
        return .promptForAccessCode(reason: try string(obj, "reason", ctx))
    case "sendBye":
        return .sendBye(sessionID: try string(obj, "sessionId", ctx),
                        reason: try string(obj, "reason", ctx))
    case "promptForConsent":
        guard let at = obj["expiresAt"]?.number else { throw fail("\(ctx): expiresAt") }
        guard let replaces = obj["replacesPrevious"]?.boolean else { throw fail("\(ctx): replacesPrevious") }
        return .promptForConsent(expiresAt: Date(timeIntervalSinceReferenceDate: at),
                                 promptID: "", replacesPrevious: replaces)
    case "dismissConsentPrompt":
        let name = try string(obj, "outcome", ctx)
        guard let outcome = ConsentOutcome(rawValue: name) else { throw fail("\(ctx): outcome \(name)") }
        return .dismissConsentPrompt(outcome: outcome)
    case let other: throw fail("\(ctx): unknown action \(other)")
    }
}

private func withoutPromptIDs(_ actions: [SessionAction]) -> [SessionAction] {
    actions.map { action in
        guard case .promptForConsent(let expiresAt, _, let replaces) = action else { return action }
        return .promptForConsent(expiresAt: expiresAt, promptID: "", replacesPrevious: replaces)
    }
}

private func promptID(for event: [String: JSONValue], remembered: [String], _ ctx: String) throws -> String? {
    let placeholder = String(repeating: "0", count: 32)
    switch event["prompt"]?.string {
    case "current": return remembered.last ?? placeholder
    case "previous": return remembered.count >= 2 ? remembered[remembered.count - 2] : placeholder
    case nil: return event["promptId"]?.string
    case let other?: throw fail("\(ctx): unknown prompt reference \(other)")
    }
}

private func icd(_ name: String, _ ctx: String) throws -> ICELinkState {
    guard let state = ICELinkState(rawValue: name) else {
        throw fail("\(ctx): unknown ice state \(name)")
    }
    return state
}

private func phaseMatches(_ phase: SessionPhase, _ expected: String) -> Bool {
    switch (phase, expected) {
    case (.idle, "idle"), (.connecting, "connecting"), (.awaitingConsent, "awaitingConsent"),
         (.live, "live"), (.reconnecting, "reconnecting"):
        return true
    case (.closed(let reason), let e) where e.hasPrefix("closed:"):
        return String(e.dropFirst("closed:".count)) == reason
    default:
        return false
    }
}

public let scenarioSuite = TestSuite("Shared state-machine scenarios (through the Rust core FFI)", [

    TestCase("every shared scenario passes through the FFI-backed machine") {
        let data = try Data(contentsOf: scenariosURL())
        let file = try JSONDecoder().decode(Scenarios.self, from: data)
        try expectGreaterThanOrEqual(file.scenarios.count, 80, "scenario file looks truncated")
        var stepsRun = 0

        for scenario in file.scenarios {
            let role: Wire.Role = scenario.role == "host" ? .host : .controller
            let machine = SessionStateMachine(role: role)
            var promptIDs: [String] = []

            for (i, step) in scenario.steps.enumerated() {
                let ctx = "scenario \(scenario.name) step \(i) (at \(step.at)s)"
                let now = Date(timeIntervalSinceReferenceDate: step.at)
                let e = step.`do`

                var actions: [SessionAction]?
                switch try string(e, "event", ctx) {
                case "connectRequested":
                    actions = machine.connectRequested(
                        deviceID: try string(e, "deviceId", ctx),
                        accessCode: try string(e, "accessCode", ctx),
                        remember: e["remember"]?.boolean ?? false)
                case "sessionGranted":
                    actions = machine.sessionGranted(SessionGrantPayload(
                        sessionId: try string(e, "sessionId", ctx),
                        sessionToken: try string(e, "sessionToken", ctx),
                        expiresAt: 0, ttlSec: 600,
                        hostDeviceId: try string(e, "hostDeviceId", ctx),
                        controllerDeviceId: try string(e, "controllerDeviceId", ctx)), now: now)
                case "connectFailed":
                    actions = machine.connectFailed(code: try string(e, "code", ctx))
                case "signalingLost":
                    actions = machine.signalingLost()
                case "signalingAuthenticated":
                    actions = machine.signalingAuthenticated(activeSessionID: e["activeSessionId"]?.string)
                case "resumeSucceeded":
                    actions = machine.resumeSucceeded(ResumeOKPayload(
                        sessionId: try string(e, "sessionId", ctx),
                        sessionToken: try string(e, "sessionToken", ctx),
                        expiresAt: 0, ttlSec: 600, peerAttached: true,
                        role: scenario.role), now: now)
                case "resumeFailed":
                    actions = machine.resumeFailed(
                        code: try string(e, "code", ctx),
                        retryAfterSec: Int(e["retryAfterSec"]?.number ?? 0))
                case "iceStateChanged":
                    actions = machine.iceStateChanged(to: try icd(try string(e, "state", ctx), ctx), now: now)
                case "tick":
                    actions = machine.tick(now: now)
                case "renewSucceeded":
                    machine.renewSucceeded(RenewOKPayload(
                        sessionId: try string(e, "sessionId", ctx),
                        sessionToken: try string(e, "sessionToken", ctx),
                        expiresAt: 0, ttlSec: 600), now: now)
                    actions = nil
                case "renewFailed":
                    actions = machine.renewFailed(code: try string(e, "code", ctx), now: now)
                case "setRelayOnly":
                    guard let relayOnly = e["relayOnly"]?.boolean else { throw fail("\(ctx): relayOnly") }
                    machine.setRelayOnly(relayOnly)
                    actions = []
                case "closeLocally":
                    actions = machine.closeLocally(reason: try string(e, "reason", ctx))
                case "userEnded":
                    actions = machine.userEnded(reason: try string(e, "reason", ctx))
                case "pakeSucceeded":
                    actions = machine.pakeSucceeded(now: now)
                case "consentAnswered":
                    guard let allow = e["allow"]?.boolean else { throw fail("\(ctx): allow") }
                    actions = machine.consentAnswered(
                        allow: allow, promptID: try promptID(for: e, remembered: promptIDs, ctx), now: now)
                case "iceServersArrived":
                    actions = machine.iceServersArrived(sessionID: try string(e, "sessionId", ctx))
                case "setConsentRequired":
                    guard let required = e["required"]?.boolean else { throw fail("\(ctx): required") }
                    machine.consentRequired = required
                    actions = []
                case let other:
                    throw fail("\(ctx): unknown event \(other)")
                }

                for case .promptForConsent(_, let id, _) in actions ?? [] {
                    try expectEqual(id.count, 32, "\(ctx): prompt id")
                    try expectNotEqual(id, machine.sessionID ?? "", "\(ctx): a prompt is never named by the session id")
                    try expectFalse(promptIDs.contains(id), "\(ctx): a prompt id was reused")
                    promptIDs.append(id)
                }
                try expectEqual(machine.lastRejection != nil, step.expectRejected ?? false,
                                "\(ctx): rejection \(machine.lastRejection ?? "none")")
                if let expected = step.expectActions {
                    let want = try expected.map { try action(from: $0, ctx) }
                    guard let got = actions else { throw fail("\(ctx): expectActions on a non-action event") }
                    try expectEqual(withoutPromptIDs(got), want, "\(ctx): actions differ")
                }
                if let phase = step.expectPhase {
                    try expect(phaseMatches(machine.phase, phase),
                               "\(ctx): phase is \(machine.phase), expected \(phase)")
                }
                if let has = step.expectHasSession {
                    try expectEqual(machine.hasSession, has, "\(ctx): hasSession")
                }
                if let inFlight = step.expectResumeInFlight {
                    try expectEqual(machine.resumeInFlight, inFlight, "\(ctx): resumeInFlight")
                }
                if let required = step.expectConsentRequired {
                    try expectEqual(machine.consentRequired, required, "\(ctx): consentRequired")
                }
                if let relayOnly = step.expectRelayOnly {
                    try expectEqual(machine.relayOnly, relayOnly, "\(ctx): relayOnly")
                }
                if let started = step.expectPeerStarted {
                    try expectEqual(machine.peerStarted, started, "\(ctx): peerStarted")
                }
                if let peer = step.expectPeerDeviceId {
                    try expectEqual(machine.peerDeviceID, peer.isEmpty ? nil : peer, "\(ctx): peerDeviceId")
                }
                stepsRun += 1
            }
        }
        try expectGreaterThanOrEqual(stepsRun, 550, "only \(stepsRun) steps ran; file looks truncated")
    },
])
