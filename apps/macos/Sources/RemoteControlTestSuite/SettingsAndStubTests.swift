import Combine
import Foundation
import AppKit
import RCTestKit
import RemoteControlCore

@MainActor
private func withDefaults(_ body: @MainActor (UserDefaults, SecretStore) throws -> Void) throws {
    let suiteName = "com.godson.remotecontrol.tests.\(UUID().uuidString)"
    let defaults = try expectNotNil(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    try body(defaults, SecretStore(blobs: InMemorySecretStore()))
}

public let settingsSuite = TestSuite("AppSettings", [

    TestCase("defaults match the specified product defaults") {
        try withDefaults { defaults, secrets in
            let settings = AppSettings(defaults: defaults, secrets: secrets)
            try expectEqual(settings.qualityMode, .balanced)
            try expectFalse(settings.unattendedAccess, "a new install asks before each connection")
            try expect(settings.clipboardSync)
            try expectFalse(settings.rememberPeerCode)
            try expectEqual(settings.role, .host)
            try expectFalse(settings.hasSavedPeer)
            try expect(settings.installUpdatesAutomatically)
            try expectFalse(settings.sessionToolbarHidden, "the session toolbar reveals on hover until the user hides it")
        }
    },

    TestCase("an existing install that never touched unattended access keeps it on") {
        try withDefaults { defaults, secrets in
            let settings = AppSettings(defaults: defaults, isExistingInstall: true, secrets: secrets)
            try expect(settings.unattendedAccess, "the old default was on; upgrading must not change behaviour")
            try expectEqual(try secrets.hostSettings(), HostSettings(unattendedAccess: true))
            try expect(AppSettings(defaults: defaults, secrets: secrets).unattendedAccess)
        }
    },

    TestCase("a new install stays off after its identity exists and the app relaunches") {
        try withDefaults { defaults, secrets in
            try expectFalse(AppSettings(defaults: defaults, isExistingInstall: false, secrets: secrets).unattendedAccess)
            try expectFalse(AppSettings(defaults: defaults, isExistingInstall: true, secrets: secrets).unattendedAccess,
                            "the second launch sees an identity file; it must not look like an upgrade")
        }
    },

    TestCase("an existing install keeps an explicit choice either way") {
        try withDefaults { defaults, secrets in
            defaults.set(false, forKey: AppSettings.Key.legacyUnattendedAccess)
            try expectFalse(AppSettings(defaults: defaults, isExistingInstall: true, secrets: secrets).unattendedAccess)
        }
        try withDefaults { defaults, secrets in
            defaults.set(true, forKey: AppSettings.Key.legacyUnattendedAccess)
            try expect(AppSettings(defaults: defaults, isExistingInstall: false, secrets: secrets).unattendedAccess)
        }
    },

    TestCase("every setting survives a reload") {
        try withDefaults { defaults, secrets in
            let settings = AppSettings(defaults: defaults, secrets: secrets)
            settings.unattendedAccess = false
            settings.clipboardSync = false
            settings.qualityMode = .lowBandwidth
            settings.role = .controller
            settings.rememberPeerCode = true
            settings.installUpdatesAutomatically = false
            settings.sessionToolbarHidden = true
            settings.savePeer(label: "Studio Mac", deviceID: "482 719 351")

            let reloaded = AppSettings(defaults: defaults, secrets: secrets)
            try expectFalse(reloaded.unattendedAccess)
            try expectFalse(reloaded.clipboardSync)
            try expectEqual(reloaded.qualityMode, .lowBandwidth)
            try expectEqual(reloaded.role, .controller)
            try expect(reloaded.rememberPeerCode)
            try expectFalse(reloaded.installUpdatesAutomatically)
            try expect(reloaded.sessionToolbarHidden)
            try expectEqual(reloaded.savedPeerLabel, "Studio Mac")
            try expectEqual(reloaded.savedPeerDeviceID, "482719351")
            try expect(reloaded.hasSavedPeer)
        }
    },

    TestCase("writes land under the documented keys") {
        try withDefaults { defaults, secrets in
            let settings = AppSettings(defaults: defaults, secrets: secrets)
            settings.qualityMode = .best
            settings.unattendedAccess = false
            try expectEqual(defaults.string(forKey: AppSettings.Key.qualityMode), "best")
            try expectEqual(try secrets.hostSettings(), HostSettings(unattendedAccess: false),
                            "unattended access lives in secure storage")
            try expectNil(defaults.object(forKey: AppSettings.Key.legacyUnattendedAccess),
                          "and never in UserDefaults")
        }
    },

    TestCase("unattended access migrates out of UserDefaults once") {
        try withDefaults { defaults, secrets in
            defaults.set(true, forKey: AppSettings.Key.legacyUnattendedAccess)
            try expect(AppSettings(defaults: defaults, isExistingInstall: true, secrets: secrets).unattendedAccess)
            try expectEqual(try secrets.hostSettings(), HostSettings(unattendedAccess: true))
            try expectNil(defaults.object(forKey: AppSettings.Key.legacyUnattendedAccess),
                          "the legacy value is removed after the move")
        }
    },

    TestCase("a UserDefaults value written after migration is ignored") {
        try withDefaults { defaults, secrets in
            let settings = AppSettings(defaults: defaults, isExistingInstall: false, secrets: secrets)
            try expectFalse(settings.unattendedAccess)
            defaults.set(true, forKey: AppSettings.Key.legacyUnattendedAccess)
            try expectFalse(AppSettings(defaults: defaults, isExistingInstall: true, secrets: secrets).unattendedAccess,
                            "another process turning unattended access on through UserDefaults has no effect")

            settings.unattendedAccess = true
            defaults.set(false, forKey: AppSettings.Key.legacyUnattendedAccess)
            try expect(AppSettings(defaults: defaults, secrets: secrets).unattendedAccess,
                       "nor does writing false over the owner's choice")
        }
    },

    TestCase("unreadable secure storage asks before every connection") {
        try withDefaults { defaults, _ in
            let blobs = InMemorySecretStore()
            let secrets = SecretStore(blobs: blobs)
            try secrets.saveHostSettings(HostSettings(unattendedAccess: true))
            blobs.isSealed = true
            defaults.set(true, forKey: AppSettings.Key.legacyUnattendedAccess)
            try expectFalse(AppSettings(defaults: defaults, isExistingInstall: true, secrets: secrets).unattendedAccess)
        }
    },

    TestCase("resetting the identity keeps the unattended choice") {
        try withDefaults { defaults, secrets in
            AppSettings(defaults: defaults, secrets: secrets).unattendedAccess = true
            secrets.discardEverything()
            try expect(AppSettings(defaults: defaults, isExistingInstall: false, secrets: secrets).unattendedAccess)
        }
    },

    TestCase("savePeer normalises and forgetPeer clears") {
        try withDefaults { defaults, secrets in
            let settings = AppSettings(defaults: defaults, secrets: secrets)
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
            try expectFalse(AppSettings(defaults: defaults, secrets: secrets).hasSavedPeer)
        }
    },

    TestCase("quality modes are distinct and complete") {
        try expectEqual(QualityMode.allCases.count, 3)
        try expectEqual(Set(QualityMode.allCases.map(\.displayName)).count, 3)
        try expectEqual(QualityMode.balanced.displayName, "Balanced")
    },
])

public let sessionStateSuite = TestSuite("Session state and permissions", [

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

public let observationSuite = TestSuite("Observation", [

    TestCase("AppSettings emits objectWillChange when role changes") {
        try withDefaults { defaults, secrets in
            let settings = AppSettings(defaults: defaults, secrets: secrets)
            var fired = 0
            let token = settings.objectWillChange.sink { _ in fired += 1 }
            defer { token.cancel() }

            try expectEqual(settings.role, .host)
            settings.role = .controller
            try expectEqual(settings.role, .controller)
            try expect(fired >= 1)
        }
    },

    TestCase("AppSettings role change is observable via its $role publisher") {
        try withDefaults { defaults, secrets in
            let settings = AppSettings(defaults: defaults, secrets: secrets)
            var seen: [AppRole] = []
            let token = settings.$role.dropFirst().sink { seen.append($0) }
            defer { token.cancel() }

            settings.role = .controller
            settings.role = .host
            try expectEqual(seen, [.controller, .host])
        }
    },

    TestCase("a settings suite isolates two instances from each other") {
        let suiteA = "com.godson.remotecontrol.tests.\(UUID().uuidString)"
        let suiteB = "com.godson.remotecontrol.tests.\(UUID().uuidString)"
        let a = try expectNotNil(UserDefaults(suiteName: suiteA))
        let b = try expectNotNil(UserDefaults(suiteName: suiteB))
        defer {
            a.removePersistentDomain(forName: suiteA)
            b.removePersistentDomain(forName: suiteB)
        }
        let secrets = SecretStore(blobs: InMemorySecretStore())
        let settingsA = AppSettings(defaults: a, secrets: secrets)
        let settingsB = AppSettings(defaults: b, secrets: secrets)

        settingsA.role = .controller
        try expectEqual(settingsA.role, .controller)
        try expectEqual(settingsB.role, .host)
        try expectEqual(AppSettings(defaults: b, secrets: secrets).role, .host)
    },
])
