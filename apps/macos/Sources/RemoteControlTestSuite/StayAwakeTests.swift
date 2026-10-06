import RCTestKit
import RemoteControlCore
import SkipperCore

public let stayAwakeSuite = TestSuite("StayAwake", [

    TestCase("an idle app holds nothing") {
        try expectEqual(StayAwakeState.idle.assertions, [])
    },

    TestCase("a reachable host keeps the Mac from idle-sleeping, display untouched") {
        try expectEqual(StayAwakeState.reachableHost.assertions, [.idleSystemSleep])
    },

    TestCase("a live session also keeps the display on, because capture needs it") {
        try expectEqual(StayAwakeState.session.assertions, [.idleSystemSleep, .displaySleep])
    },

    TestCase("each state names itself in pmset") {
        try expectEqual(StayAwakeState.reachableHost.reason, "SkipperDesk is reachable")
        try expectEqual(StayAwakeState.session.reason, "SkipperDesk remote session")
    },

    TestCase("a host that is online is reachable, whatever unattended access says") {
        try expectEqual(StayAwakeState(role: .host, isOnline: true, phase: .idle), .reachableHost)
        try expectEqual(StayAwakeState(role: .host, isOnline: true, phase: nil), .reachableHost)
    },

    TestCase("a host that is not online holds nothing") {
        try expectEqual(StayAwakeState(role: .host, isOnline: false, phase: .idle), .idle)
    },

    TestCase("a controller at rest holds nothing") {
        try expectEqual(StayAwakeState(role: .controller, isOnline: true, phase: .idle), .idle)
    },

    TestCase("every phase of an open session counts as a session") {
        for phase: SessionPhase in [.connecting, .awaitingConsent, .live, .reconnecting] {
            try expectEqual(StayAwakeState(role: .host, isOnline: true, phase: phase), .session)
            try expectEqual(StayAwakeState(role: .controller, isOnline: false, phase: phase), .session)
        }
    },

    TestCase("leaving a session drops a host back to reachable and a controller to idle") {
        let ended = SessionPhase.closed(reason: "user ended")
        try expectEqual(StayAwakeState(role: .host, isOnline: true, phase: ended), .reachableHost)
        try expectEqual(StayAwakeState(role: .controller, isOnline: true, phase: ended), .idle)
    },

    TestCase("signing out of a reachable host releases everything") {
        try expectEqual(StayAwakeState(role: .host, isOnline: false, phase: nil).assertions, [])
    },
])
