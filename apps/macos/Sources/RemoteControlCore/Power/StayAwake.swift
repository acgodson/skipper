import Foundation
import IOKit.pwr_mgt

@MainActor
public final class StayAwake {

    private var assertionID: IOPMAssertionID = IOPMAssertionID(0)
    private(set) public var isHeld = false

    public init() {}

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
