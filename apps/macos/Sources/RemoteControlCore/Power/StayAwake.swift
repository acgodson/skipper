import Foundation
import IOKit.pwr_mgt
import SkipperCore

public enum StayAwakeAssertion: String, CaseIterable, Equatable, Sendable {
    case idleSystemSleep
    case displaySleep

    var ioKitType: String {
        switch self {
        case .idleSystemSleep: return kIOPMAssertPreventUserIdleSystemSleep
        case .displaySleep: return kIOPMAssertPreventUserIdleDisplaySleep
        }
    }
}

public enum StayAwakeState: String, Equatable, Sendable {
    case idle
    case reachableHost
    case session

    public init(role: AppRole, isOnline: Bool, phase: SessionPhase?) {
        switch phase {
        case .connecting, .awaitingConsent, .live, .reconnecting:
            self = .session
        case .idle, .closed, .none:
            self = (role == .host && isOnline) ? .reachableHost : .idle
        }
    }

    public var assertions: Set<StayAwakeAssertion> {
        switch self {
        case .idle: return []
        case .reachableHost: return [.idleSystemSleep]
        case .session: return [.idleSystemSleep, .displaySleep]
        }
    }

    /// One string for every state: `pmset -g assertions` is world-readable, and
    /// a reason that changes with the state tells any local process when a
    /// session is live.
    public static let reason = "SkipperDesk"

    public var reason: String { Self.reason }
}

@MainActor
public final class StayAwake {

    private(set) public var state: StayAwakeState = .idle
    private var held: [StayAwakeAssertion: IOPMAssertionID] = [:]
    private var userActivityID = IOPMAssertionID(0)

    public init() {}

    public var heldAssertions: Set<StayAwakeAssertion> { Set(held.keys) }

    public func update(role: AppRole, isOnline: Bool, phase: SessionPhase?) {
        let next = StayAwakeState(role: role, isOnline: isOnline, phase: phase)
        guard next != state else { return }
        let entersSession = (next == .session && state != .session)
        state = next
        releaseAll()
        for assertion in next.assertions.sorted(by: { $0.rawValue < $1.rawValue }) {
            acquire(assertion, reason: next.reason)
        }
        if entersSession && role == .host { declareUserActivity() }
    }

    private func acquire(_ assertion: StayAwakeAssertion, reason: String) {
        var id = IOPMAssertionID(0)
        let result = IOPMAssertionCreateWithName(
            assertion.ioKitType as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            reason as CFString,
            &id
        )
        if result == kIOReturnSuccess {
            held[assertion] = id
            RCLog.info("power: holding \(assertion.rawValue) as \"\(reason)\"")
        } else {
            RCLog.error("power: could not hold \(assertion.rawValue) (IOReturn \(result))")
        }
    }

    private func releaseAll() {
        for (assertion, id) in held {
            IOPMAssertionRelease(id)
            RCLog.info("power: released \(assertion.rawValue)")
        }
        held.removeAll()
    }

    private func declareUserActivity() {
        let result = IOPMAssertionDeclareUserActivity(
            StayAwakeState.session.reason as CFString,
            kIOPMUserActiveLocal,
            &userActivityID
        )
        if result == kIOReturnSuccess {
            RCLog.info("power: declared local user activity so the display comes back")
        } else {
            RCLog.error("power: could not declare user activity (IOReturn \(result))")
        }
    }

    deinit {
        for (_, id) in held { IOPMAssertionRelease(id) }
    }
}
