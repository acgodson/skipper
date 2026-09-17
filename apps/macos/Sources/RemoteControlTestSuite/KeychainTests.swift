import Foundation
import Security
import RCTestKit
import RemoteControlCore

// TODO: verify on a Developer-ID-signed build. Real data-protection Keychain writes and the legacy move need the keychain-access-groups entitlement; these cases cover query construction and decisions only.

@MainActor
private func withUnsignedKeychain(
    _ body: @MainActor (IdentityFileStore, KeychainBlobs<DeviceKeyAccount>, SecretStore) async throws -> Void
) async throws {
    let directory = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("rc-tests-keychain-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    try await body(
        IdentityFileStore(directory: directory),
        KeychainBlobs<DeviceKeyAccount>(accessGroup: nil),
        SecretStore(blobs: KeychainBlobs<SecretAccount>(accessGroup: nil))
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

    TestCase("every query pins the data-protection keychain, the access group and no sync") {
        let query = try KeychainItem.query(account: "access-code", accessGroup: "A1B2C3D4E5.app.skipperdesk.desktop")
        try expectEqual(query[kSecClass as String] as? String, kSecClassGenericPassword as String)
        try expectEqual(query[kSecAttrService as String] as? String, "app.skipperdesk.desktop")
        try expectEqual(query[kSecAttrAccount as String] as? String, "access-code")
        try expectEqual(query[kSecUseDataProtectionKeychain as String] as? Bool, true)
        try expectEqual(query[kSecAttrAccessGroup as String] as? String, "A1B2C3D4E5.app.skipperdesk.desktop")
        try expectEqual(query[kSecAttrSynchronizable as String] as? Bool, false)
    },

    TestCase("stored items are readable only after first unlock, on this device") {
        let attributes = KeychainItem.attributes(storing: Data([1, 2, 3]))
        try expectEqual(attributes[kSecValueData as String] as? Data, Data([1, 2, 3]))
        try expectEqual(attributes[kSecAttrAccessible as String] as? String,
                        kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String)
    },

    TestCase("without a Team ID every operation fails closed before touching the Keychain") {
        try expectUnsigned { _ = try KeychainItem.query(account: "device-key", accessGroup: nil) }
        let item = KeychainItem(account: "device-token", accessGroup: nil)
        try expectUnsigned { _ = try item.load() }
        try expectUnsigned { try item.save(Data([1])) }
        try expectUnsigned { try item.remove() }
        try expectEqual(KeychainError.unsigned.errorDescription,
                        "This build is not signed by SkipperDesk and cannot store keys.")
    },

    TestCase("an unsigned release build cannot create an identity, and writes no file") {
        try await withUnsignedKeychain { fileStore, blobStore, secrets in
            try expectUnsigned {
                _ = try IdentityStore(fileStore: fileStore, blobStore: blobStore, secrets: secrets,
                                      devFileIdentity: false)
            }
            try expectNil(try fileStore.load(), "no identity may be written when keys cannot be stored")
        }
    },

    TestCase("an unsigned build never falls back to a file key, even with a working secret store") {
        try await withUnsignedKeychain { fileStore, blobStore, _ in
            try expectUnsigned {
                _ = try IdentityStore(fileStore: fileStore, blobStore: blobStore,
                                      secrets: SecretStore(blobs: InMemorySecretStore()), devFileIdentity: false)
            }
            try expectNil(try fileStore.load())
        }
    },

    TestCase("an unsigned build refuses to keep an existing file key in the file") {
        try await withUnsignedKeychain { fileStore, blobStore, _ in
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
            "host-settings", "device-token",
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

    TestCase("an unsigned build migrates nothing") {
        try expectEqual(LegacyKeychainMigration.run(identityCreatedAt: identityCreated, accessGroup: nil), [:])
    },
])
