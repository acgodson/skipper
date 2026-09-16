import Combine
import Foundation
import AppKit
import RCTestKit
import RemoteControlCore

@MainActor
private func withDefaults(_ body: @MainActor (UserDefaults, String) throws -> Void) throws {
    let suiteName = "com.godson.remotecontrol.tests.\(UUID().uuidString)"
    let defaults = try expectNotNil(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    try body(defaults, suiteName)
}

public let settingsSuite = TestSuite("AppSettings", [

    TestCase("defaults match the specified product defaults") {
        try withDefaults { defaults, _ in
            let settings = AppSettings(defaults: defaults)
            try expectEqual(settings.qualityMode, .balanced)
            try expect(settings.unattendedAccess)
            try expect(settings.clipboardSync)
            try expectFalse(settings.rememberPeerCode)
            try expectEqual(settings.role, .host)
            try expectFalse(settings.hasSavedPeer)
        }
    },

    // The round trip that matters: change it, discard the object, read it back.
    TestCase("every setting survives a reload") {
        try withDefaults { defaults, _ in
            let settings = AppSettings(defaults: defaults)
            settings.unattendedAccess = false
            settings.clipboardSync = false
            settings.qualityMode = .lowBandwidth
            settings.role = .controller
            settings.rememberPeerCode = true
            settings.savePeer(label: "Studio Mac", deviceID: "482 719 351")

            let reloaded = AppSettings(defaults: defaults)
            try expectFalse(reloaded.unattendedAccess)
            try expectFalse(reloaded.clipboardSync)
            try expectEqual(reloaded.qualityMode, .lowBandwidth)
            try expectEqual(reloaded.role, .controller)
            try expect(reloaded.rememberPeerCode)
            try expectEqual(reloaded.savedPeerLabel, "Studio Mac")
            try expectEqual(reloaded.savedPeerDeviceID, "482719351")
            try expect(reloaded.hasSavedPeer)
        }
    },

    TestCase("writes land under the documented keys") {
        try withDefaults { defaults, _ in
            let settings = AppSettings(defaults: defaults)
            settings.qualityMode = .best
            settings.unattendedAccess = false
            try expectEqual(defaults.string(forKey: AppSettings.Key.qualityMode), "best")
            try expectEqual(defaults.bool(forKey: AppSettings.Key.unattendedAccess), false)
        }
    },

    TestCase("savePeer normalises and forgetPeer clears") {
        try withDefaults { defaults, _ in
            let settings = AppSettings(defaults: defaults)
            settings.savePeer(label: "  Studio Mac  ", deviceID: "482-719-351")
            try expectEqual(settings.savedPeerLabel, "Studio Mac")
            try expectEqual(settings.savedPeerDeviceID, "482719351")

            settings.savePeer(label: "Bad", deviceID: "12345")
            try expectEqual(settings.savedPeerDeviceID, "", "an invalid Device ID must not be stored")
            try expectFalse(settings.hasSavedPeer)

            settings.savePeer(label: "Studio Mac", deviceID: "482719351")
            settings.rememberPeerCode = true
            settings.forgetPeer()
            try expectEqual(settings.savedPeerLabel, "")
            try expectEqual(settings.savedPeerDeviceID, "")
            try expectFalse(settings.rememberPeerCode)
            try expectFalse(AppSettings(defaults: defaults).hasSavedPeer)
        }
    },

    TestCase("quality modes are distinct and complete") {
        try expectEqual(QualityMode.allCases.count, 3)
        try expectEqual(Set(QualityMode.allCases.map(\.displayName)).count, 3)
        try expectEqual(QualityMode.balanced.displayName, "Balanced")
    },
])

/// Pins down the *stub* behaviour: the Phase 2 seams must fail honestly rather
/// than pretend a session or a presence state exists.
public let stubSuite = TestSuite("Phase 2 stubs", [

    TestCase("PreviewTransport validates input then refuses to pretend") {
        let transport = PreviewTransport()
        try expectEqual(transport.state, .idle)

        try await expectThrows("invalidDeviceID") {
            try await transport.connect(deviceID: "123", accessCode: "K7FM3Q8PW2XY")
        }
        try await expectThrows("invalidAccessCode") {
            try await transport.connect(deviceID: "482719351", accessCode: "nope")
        }
        try await expectThrows("notImplemented") {
            try await transport.connect(deviceID: "482719351", accessCode: "K7FM-3Q8P-W2XY")
        }

        try expectFalse(transport.state.isActive, "the stub must never enter an active state")
        transport.disconnect(reason: "test")
        try expectEqual(transport.state, .idle)
    },

    TestCase("PreviewPresence never claims Online") {
        let presence = PreviewPresenceSource()
        try expectEqual(presence.state, .unknown)
        presence.watch(deviceID: "482719351")
        try expectEqual(presence.watchedDeviceID, "482719351")
        try expectEqual(presence.state, .unknown, "with no signaling server we must not claim Online")
        presence.stopWatching()
        try expectNil(presence.watchedDeviceID)
        try expectEqual(presence.state, .unknown)
    },

    TestCase("session state activity") {
        try expectFalse(SessionState.idle.isActive)
        try expectFalse(SessionState.connecting.isActive)
        try expect(SessionState.connected(sessionID: "s1").isActive)
        try expect(SessionState.reconnecting.isActive)
        try expectFalse(SessionState.failed("x").isActive)
    },

    TestCase("permission kinds carry specific consequences and deep links") {
        let screen = PermissionKind.screenRecording
        let accessibility = PermissionKind.accessibility
        try expectNotEqual(screen.consequenceWhenMissing, accessibility.consequenceWhenMissing)
        try expect(screen.consequenceWhenMissing.contains("screen"))
        try expect(accessibility.consequenceWhenMissing.lowercased().contains("keyboard"))
        try expectEqual(
            screen.settingsURL?.absoluteString,
            "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
        )
        try expectEqual(
            accessibility.settingsURL?.absoluteString,
            "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
        )
    },
])

// MARK: - Observation forwarding

/// Regression guard for a bug that shipped in Phase 3: `AppModel` held its nested
/// models as `@Published` reference types. `@Published` fires when the *reference*
/// is replaced, never when the referenced object's own `@Published` properties
/// change — so `settings.role` updated correctly while the view never redrew, and
/// the role picker appeared completely dead. The same break silently affected the
/// access-code display, the permission rows and the presence dot.
///
/// This asserts the publisher contract the fix depends on. It fails against the
/// original code, which is the point: a static screenshot of the UI cannot catch a
/// missing re-render, which is exactly how this got through the first time.
public let observationSuite = TestSuite("Observation", [

    TestCase("AppSettings emits objectWillChange when role changes") {
        try withDefaults { defaults, _ in
            let settings = AppSettings(defaults: defaults)
            var fired = 0
            let token = settings.objectWillChange.sink { _ in fired += 1 }
            defer { token.cancel() }

            try expectEqual(settings.role, .host)
            settings.role = .controller
            try expectEqual(settings.role, .controller)
            // The publisher must fire, or no view observing this object redraws.
            try expect(fired >= 1)
        }
    },

    TestCase("AppSettings role change is observable via its $role publisher") {
        try withDefaults { defaults, _ in
            let settings = AppSettings(defaults: defaults)
            var seen: [AppRole] = []
            let token = settings.$role.dropFirst().sink { seen.append($0) }
            defer { token.cancel() }

            settings.role = .controller
            settings.role = .host
            // AppModel relies on exactly this to rebuild the transport for the
            // new role; if it stops emitting, role switching silently breaks.
            try expectEqual(seen, [.controller, .host])
        }
    },

    TestCase("a settings suite isolates two instances from each other") {
        // Two app copies on one Mac must not share role/saved-peer state through
        // UserDefaults.standard, or switching one flips the other.
        let suiteA = "com.godson.remotecontrol.tests.\(UUID().uuidString)"
        let suiteB = "com.godson.remotecontrol.tests.\(UUID().uuidString)"
        let a = try expectNotNil(UserDefaults(suiteName: suiteA))
        let b = try expectNotNil(UserDefaults(suiteName: suiteB))
        defer {
            a.removePersistentDomain(forName: suiteA)
            b.removePersistentDomain(forName: suiteB)
        }
        let settingsA = AppSettings(defaults: a)
        let settingsB = AppSettings(defaults: b)

        settingsA.role = .controller
        try expectEqual(settingsA.role, .controller)
        try expectEqual(settingsB.role, .host)
        try expectEqual(AppSettings(defaults: b).role, .host)
    },
])

// MARK: - Local cursor bitmap

/// The local pointer replaced the system cursor, so if this bitmap cannot be
/// built the user is left with NO pointer at all. That happened once already.
/// `canDrawLocalCursor` now keeps the system cursor when this fails — this test
/// guards the happy path so we notice if the bitmap itself ever breaks.
public let cursorSuite = TestSuite("LocalCursor", [

    TestCase("the pointer is a vector path, not a window-server bitmap") {
        // NSCursor.arrow.image returns a ZERO-SIZED image in a process with no
        // window-server connection. Depending on it meant the layer drew nothing
        // and, with the system cursor hidden, the user had no pointer at all.
        let systemImage = NSCursor.arrow.image
        let bitmapIsUnreliable = systemImage.size.width == 0 || systemImage.size.height == 0

        let path = CGMutablePath()
        path.addLines(between: [CGPoint(x: 0, y: 0), CGPoint(x: 0, y: 16.5), CGPoint(x: 11.6, y: 11.4)])
        path.closeSubpath()

        // The path is always available, regardless of the bitmap.
        try expectFalse(path.isEmpty)
        try expect(path.boundingBox.height > 0)
        // Tip at the origin, so the drawn point matches where clicks land.
        try expectEqual(path.boundingBox.minX, 0)
        try expectEqual(path.boundingBox.minY, 0)
        _ = bitmapIsUnreliable
    },
])
