import Foundation
import IOKit.pwr_mgt

/// Holds a macOS power assertion so an unattended host does not idle-sleep.
///
/// WHY THIS EXISTS: a sleeping Mac runs nothing. It stops heartbeating, the
/// signaling server marks it offline after 40s, and the controller simply cannot
/// reach it — no reconnect logic can rescue that, because there is nothing
/// running to reconnect. For a tool whose entire purpose is "leave a Mac
/// somewhere and reach it later", relying on the user to find the right System
/// Settings toggle is a design flaw, not a documentation gap.
///
/// The assertion is held while UNATTENDED ACCESS is enabled — not merely while a
/// session is active. The machine has to be awake to *accept* a connection; only
/// staying awake during a session would be useless.
///
/// HONEST LIMITS, so nobody is surprised:
///  * This prevents *idle* sleep. It does NOT stop sleep when a laptop lid is
///    closed (clamshell sleep), which needs external power + display, nor a
///    user explicitly choosing Sleep, nor low-battery sleep.
///  * The display is still allowed to sleep. Keeping pixels lit is not required
///    to stay reachable, and forcing it would waste power and burn screens.
@MainActor
public final class StayAwake {

    private var assertionID: IOPMAssertionID = IOPMAssertionID(0)
    private(set) public var isHeld = false

    public init() {}

    /// Reason string surfaced in `pmset -g assertions`, so the cause of a Mac
    /// not sleeping is discoverable rather than mysterious.
    private static let reason = "RemoteControl: unattended access enabled" as CFString

    public func update(enabled: Bool) {
        enabled ? acquire() : release()
    }

    private func acquire() {
        guard !isHeld else { return }
        var id = IOPMAssertionID(0)
        let result = IOPMAssertionCreateWithName(
            kIOPMAssertPreventUserIdleSystemSleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            Self.reason,
            &id
        )
        if result == kIOReturnSuccess {
            assertionID = id
            isHeld = true
            RCLog.info("power: holding idle-sleep assertion")
        } else {
            // Never fail silently: if we cannot hold it, the Mac will vanish.
            RCLog.error("power: could not hold the sleep assertion (IOReturn \(result))")
        }
    }

    private func release() {
        guard isHeld else { return }
        IOPMAssertionRelease(assertionID)
        assertionID = IOPMAssertionID(0)
        isHeld = false
        RCLog.info("power: released idle-sleep assertion")
    }

    deinit {
        if isHeld { IOPMAssertionRelease(assertionID) }
    }
}
