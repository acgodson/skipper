import Foundation
import Security
import RCTestKit
import RemoteControlCore

// TODO: verify on a build with an embedded provisioning profile. Real data-protection Keychain writes need keychain-access-groups; these cases cover query construction and decisions only.

@MainActor
private func withUnreachableKeychain(
    _ body: @MainActor (IdentityFileStore, KeychainBlobs<DeviceKeyAccount>, SecretStore) async throws -> Void
) async throws {
    let directory = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("rc-tests-keychain-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    try await body(
        IdentityFileStore(directory: directory),
        KeychainBlobs<DeviceKeyAccount>(mode: .dataProtection, accessGroup: nil),
        SecretStore(blobs: KeychainBlobs<SecretAccount>(mode: .dataProtection, accessGroup: nil))
    )
}

@MainActor
private func expectUnsigned(_ operation: () throws -> Void) throws {
    do {
        try operation()
    } catch let error as KeychainError {
        try expectEqual(error, .unsigned)
        return
    }
    throw fail("expected KeychainError.unsigned")
}

public let keychainSuite = TestSuite("KeychainItem", [

    TestCase("the access group is the running app's Team ID plus the app identifier") {
        try expectEqual(KeychainAccessGroup.named(teamID: "A1B2C3D4E5"), "A1B2C3D4E5.app.skipperdesk.desktop")
        try expectNil(KeychainAccessGroup.named(teamID: nil))
        try expectNil(KeychainAccessGroup.named(teamID: ""))
        try expectNil(KeychainAccessGroup.named(teamID: "  "))
    },

    TestCase("a data-protection query pins that keychain, the access group and no sync") {
        let query = try KeychainItem.query(account: "access-code", mode: .dataProtection,
                                           accessGroup: "A1B2C3D4E5.app.skipperdesk.desktop")
        try expectEqual(query[kSecClass as String] as? String, kSecClassGenericPassword as String)
        try expectEqual(query[kSecAttrService as String] as? String, "app.skipperdesk.desktop")
        try expectEqual(query[kSecAttrAccount as String] as? String, "access-code")
        try expectEqual(query[kSecUseDataProtectionKeychain as String] as? Bool, true)
        try expectEqual(query[kSecAttrAccessGroup as String] as? String, "A1B2C3D4E5.app.skipperdesk.desktop")
        try expectEqual(query[kSecAttrSynchronizable as String] as? Bool, false)
    },

    TestCase("a login query names no access group, so it needs no entitlement") {
        let query = try KeychainItem.query(account: "access-code", mode: .login,
                                           accessGroup: "A1B2C3D4E5.app.skipperdesk.desktop")
        try expectEqual(query[kSecAttrService as String] as? String, "app.skipperdesk.desktop")
        try expectEqual(query[kSecAttrAccount as String] as? String, "access-code")
        try expectEqual(query[kSecUseDataProtectionKeychain as String] as? Bool, false)
        try expectNil(query[kSecAttrAccessGroup as String])
        try expectNil(query[kSecAttrSynchronizable as String])
    },

    TestCase("the same account in the other keychain is the same account") {
        let item = KeychainItem(account: "device-key", mode: .dataProtection, accessGroup: "A1B2C3D4E5.x")
        try expectEqual(item.counterpart.account, "device-key")
        try expectEqual(item.counterpart.mode, .login)
        try expectEqual(item.counterpart.counterpart.mode, .dataProtection)
    },

    TestCase("data-protection items are readable only after first unlock, on this device") {
        let attributes = KeychainItem.attributes(storing: Data([1, 2, 3]), mode: .dataProtection)
        try expectEqual(attributes[kSecValueData as String] as? Data, Data([1, 2, 3]))
        try expectEqual(attributes[kSecAttrAccessible as String] as? String,
                        kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String)
        let login = KeychainItem.attributes(storing: Data([1, 2, 3]), mode: .login)
        try expectEqual(login[kSecValueData as String] as? Data, Data([1, 2, 3]))
        try expectNil(login[kSecAttrAccessible as String], "the login keychain has no accessibility classes")
    },

    TestCase("the data-protection keychain is chosen only with an access group and a working probe") {
        let group = "A1B2C3D4E5.app.skipperdesk.desktop"
        try expectEqual(SecretStorageMode.decide(accessGroup: group, dataProtectionUsable: true), .dataProtection)
        try expectEqual(SecretStorageMode.decide(accessGroup: group, dataProtectionUsable: false), .login)
        try expectEqual(SecretStorageMode.decide(accessGroup: nil, dataProtectionUsable: true), .login)
        try expectEqual(SecretStorageMode.decide(accessGroup: nil, dataProtectionUsable: false), .login)
    },

    TestCase("the footer explains the login keychain and says nothing about the other one") {
        try expectNil(SecretStorageMode.dataProtection.footerNote)
        try expectEqual(SecretStorageMode.login.footerNote,
                        "Kept in this Mac's login keychain. Another app running as you could read it. "
                            + "A signed SkipperDesk build keeps it out of reach.")
    },

    TestCase("a data-protection build with no access group fails closed before touching the Keychain") {
        try expectUnsigned {
            _ = try KeychainItem.query(account: "device-key", mode: .dataProtection, accessGroup: nil)
        }
        let item = KeychainItem(account: "device-token", mode: .dataProtection, accessGroup: nil)
        try expectUnsigned { _ = try item.load() }
        try expectUnsigned { try item.save(Data([1])) }
        try expectUnsigned { try item.remove() }
        try expectEqual(KeychainError.unsigned.errorDescription,
                        "This build cannot reach the data-protection Keychain and has no access group.")
    },

    TestCase("a build whose selected keychain refuses everything creates no identity and writes no file") {
        try await withUnreachableKeychain { fileStore, blobStore, secrets in
            try expectUnsigned {
                _ = try IdentityStore(fileStore: fileStore, blobStore: blobStore, secrets: secrets,
                                      devFileIdentity: false)
            }
            try expectNil(try fileStore.load(), "no identity may be written when keys cannot be stored")
        }
    },

    TestCase("a build whose keychain refuses never falls back to a file key, even with a working secret store") {
        try await withUnreachableKeychain { fileStore, blobStore, _ in
            try expectUnsigned {
                _ = try IdentityStore(fileStore: fileStore, blobStore: blobStore,
                                      secrets: SecretStore(blobs: InMemorySecretStore()), devFileIdentity: false)
            }
            try expectNil(try fileStore.load())
        }
    },

    TestCase("a build whose keychain refuses will not keep an existing file key in the file") {
        try await withUnreachableKeychain { fileStore, blobStore, _ in
            let record = IdentityRecord(deviceID: "482719351", key: DeviceKey(), createdAt: IdentityRecord.timestamp())
            try fileStore.save(record)
            try expectUnsigned {
                _ = try IdentityStore(fileStore: fileStore, blobStore: blobStore,
                                      secrets: SecretStore(blobs: InMemorySecretStore()), devFileIdentity: false)
            }
            try expectEqual(try requireLoaded(fileStore).record, record, "the identity file is left untouched")
        }
    },
])

private let identityCreated = Date(timeIntervalSince1970: 1_800_000_000)

private func present(_ offset: TimeInterval?, migrated: Bool = false) -> LegacyKeychainState {
    LegacyKeychainState(
        present: true,
        createdAt: offset.map { identityCreated.addingTimeInterval($0) },
        migratedCopyPresent: migrated
    )
}

private let aDayBefore: TimeInterval = -86_400
private let anHourAfter: TimeInterval = 3_600

public let legacyKeychainMigrationSuite = TestSuite("LegacyKeychainMigration", [

    TestCase("every account the app stores is considered for migration") {
        try expectEqual(Set(LegacyKeychainMigration.accounts), [
            "device-key", "device-key-software", "access-code", "peer-codes",
            "trusted-controllers", "guess-counters", "device-id-cert", "host-key-pins",
            "host-settings", "device-token", "pending-host-keys",
        ])
    },

    TestCase("absent legacy items are left alone") {
        let decisions = LegacyKeychainMigration.decide(
            ["access-code": LegacyKeychainState(present: false)], identityCreatedAt: identityCreated)
        try expectEqual(decisions["access-code"], .nothing)
    },

    TestCase("items written by this identity are adopted") {
        let decisions = LegacyKeychainMigration.decide([
            "device-key": present(0),
            "access-code": present(0.4),
            "peer-codes": present(anHourAfter),
            "trusted-controllers": present(anHourAfter),
            "guess-counters": present(anHourAfter),
            "device-token": present(anHourAfter),
        ], identityCreatedAt: identityCreated)
        try expect(decisions.values.allSatisfy { $0 == .adopt }, "\(decisions)")
    },

    TestCase("an access code saved a moment before the record's rounded timestamp is still adopted") {
        let decisions = LegacyKeychainMigration.decide(
            ["access-code": present(-2)], identityCreatedAt: identityCreated)
        try expectEqual(decisions["access-code"], .adopt)
    },

    TestCase("an access code older than the identity is rejected and only the code-bound items go with it") {
        let decisions = LegacyKeychainMigration.decide([
            "device-key": present(aDayBefore),
            "device-key-software": present(aDayBefore),
            "access-code": present(aDayBefore),
            "trusted-controllers": present(anHourAfter),
            "guess-counters": present(anHourAfter),
            "peer-codes": present(anHourAfter),
            "device-token": present(anHourAfter),
        ], identityCreatedAt: identityCreated)
        try expectEqual(decisions["access-code"], .reject)
        try expectEqual(decisions["trusted-controllers"], .reject)
        try expectEqual(decisions["guess-counters"], .reject)
        try expectEqual(decisions["device-key"], .adopt, "the device key is never regenerated")
        try expectEqual(decisions["device-key-software"], .adopt, "the device key is never regenerated")
        try expectEqual(decisions["peer-codes"], .adopt)
        try expectEqual(decisions["device-token"], .adopt)
    },

    TestCase("an access code with no creation date is treated as suspicious") {
        let decisions = LegacyKeychainMigration.decide(
            ["access-code": present(nil)], identityCreatedAt: identityCreated)
        try expectEqual(decisions["access-code"], .reject)
    },

    TestCase("a device token planted before the identity existed is not adopted") {
        let decisions = LegacyKeychainMigration.decide(
            ["device-token": present(aDayBefore)], identityCreatedAt: identityCreated)
        try expectEqual(decisions["device-token"], .reject)
    },

    TestCase("with no identity file there is nothing to preserve, so nothing is adopted") {
        let decisions = LegacyKeychainMigration.decide([
            "device-key": present(aDayBefore),
            "access-code": present(aDayBefore),
            "peer-codes": present(aDayBefore),
        ], identityCreatedAt: nil)
        try expect(decisions.values.allSatisfy { $0 == .reject }, "\(decisions)")
    },

    TestCase("an item already in the data-protection keychain wins; the legacy copy is dropped") {
        let decisions = LegacyKeychainMigration.decide([
            "access-code": present(aDayBefore, migrated: true),
            "device-key": present(0, migrated: true),
        ], identityCreatedAt: identityCreated)
        try expectEqual(decisions["access-code"], .dropLegacy)
        try expectEqual(decisions["device-key"], .dropLegacy)
    },

    TestCase("a build that cannot reach the data-protection keychain migrates nothing, either way") {
        try expectEqual(LegacyKeychainMigration.run(
            identityCreatedAt: identityCreated, mode: .dataProtection,
            accessGroup: nil, dataProtectionUsable: false), [:])
        try expectEqual(LegacyKeychainMigration.run(
            identityCreatedAt: identityCreated, mode: .login,
            accessGroup: "A1B2C3D4E5.app.skipperdesk.desktop", dataProtectionUsable: false), [:])
    },

    TestCase("items coming back from the data-protection keychain are adopted without suspicion") {
        let decisions = LegacyKeychainMigration.decide([
            "device-key": present(aDayBefore),
            "access-code": present(aDayBefore),
            "trusted-controllers": present(nil),
            "guess-counters": present(aDayBefore),
            "device-token": present(aDayBefore),
        ], identityCreatedAt: identityCreated, source: .dataProtection)
        try expect(decisions.values.allSatisfy { $0 == .adopt }, "\(decisions)")
    },

    TestCase("a copy already in the login keychain still wins over the data-protection one") {
        let decisions = LegacyKeychainMigration.decide([
            "access-code": present(anHourAfter, migrated: true),
            "peer-codes": present(anHourAfter),
        ], identityCreatedAt: identityCreated, source: .dataProtection)
        try expectEqual(decisions["access-code"], .dropLegacy)
        try expectEqual(decisions["peer-codes"], .adopt)
    },

    TestCase("with no identity file, items from the data-protection keychain are still adopted") {
        let decisions = LegacyKeychainMigration.decide(
            ["device-key": present(aDayBefore)], identityCreatedAt: nil, source: .dataProtection)
        try expectEqual(decisions["device-key"], .adopt)
    },
])
