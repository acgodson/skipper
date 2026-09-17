import Foundation
import RCTestKit
import RemoteControlCore
import SkipperCore

@MainActor
private func withIdentity(_ body: @MainActor (IdentityFileStore) async throws -> Void) async throws {
    let directory = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("rc-tests-identity-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    try await body(IdentityFileStore(directory: directory))
}

private final class FailingSink: AccessCodeSink {
    struct Boom: Error, LocalizedError { var errorDescription: String? { "no server" } }
    var callCount = 0
    func accessCodeDidChange(deviceID: String) async throws {
        callCount += 1
        throw Boom()
    }
}

public let identitySuite = TestSuite("IdentityStore", [

    TestCase("first launch mints a valid identity and writes it out") {
        try await withIdentity { fileStore in
            try expectFalse(FileManager.default.fileExists(atPath: fileStore.fileURL.path))

            let store = try IdentityStore(fileStore: fileStore)
            try expectNotNil(AccessCode.canonicalize(store.accessCode))
            try expectNotNil(DeviceID.canonicalize(store.deviceID))
            try expectEqual(store.formattedAccessCode.count, 14)
            try expectEqual(store.formattedDeviceID.count, 11)
            try expectEqual(store.publicKeyHex.count, 130)
            try expectEqual(Data(base64Encoded: store.publicKeyBase64)?.count, 91, "base64 DER SPKI")
            try expectNil(store.permissionWarning)

            try expect(FileManager.default.fileExists(atPath: fileStore.fileURL.path))
            try expectEqual(try SecureFile.currentMode(of: fileStore.fileURL), 0o600)
            try expectEqual(try SecureFile.currentMode(of: fileStore.directory), 0o700)
            try expectEqual(store.keyStorage, .file(fileStore.fileURL))
        }
    },

    TestCase("identity survives a restart, byte-identically") {
        try await withIdentity { fileStore in
            let first = try IdentityStore(fileStore: fileStore)
            let code = first.accessCode
            let deviceID = first.deviceID
            let publicKey = first.publicKeyBase64

            let second = try IdentityStore(fileStore: fileStore)
            try expectEqual(second.accessCode, code, "the access code must not rotate on relaunch")
            try expectEqual(second.deviceID, deviceID, "the Device ID is permanent")
            try expectEqual(second.publicKeyBase64, publicKey, "the device key must be reused, not re-minted")
            try expectEqual(second.publicKeyHex, first.publicKeyHex)
            try expectEqual(second.createdAt, first.createdAt)

            let message = Data("nonce".utf8)
            try expect(first.verify(try second.sign(message), for: message),
                       "the reloaded key must be the same private key, not just the same public metadata")

            let record = try requireLoaded(fileStore).record
            try expectNil(record.accessCode, "the code lives in the Keychain, never in the file")
            try expectEqual(record.deviceID, deviceID)
        }
    },

    TestCase("construction never rotates the stored code") {
        try await withIdentity { fileStore in
            let code = try IdentityStore(fileStore: fileStore).accessCode
            for _ in 0..<5 {
                try expectEqual(try IdentityStore(fileStore: fileStore).accessCode, code)
            }
        }
    },

    TestCase("refreshAccessCode writes through to disk and the new code survives a reload") {
        try await withIdentity { fileStore in
            let store = try IdentityStore(fileStore: fileStore)
            let original = store.accessCode

            let refreshed = try await store.refreshAccessCode()

            try expectNotEqual(refreshed, original, "refresh must actually change the code")
            try expectEqual(store.accessCode, refreshed)
            try expectNotNil(AccessCode.canonicalize(refreshed))

            let reloaded = try IdentityStore(fileStore: fileStore)
            try expectEqual(reloaded.accessCode, refreshed)
            try expectNotEqual(reloaded.accessCode, original)
            try expectEqual(reloaded.deviceID, store.deviceID)
            try expectEqual(reloaded.publicKeyBase64, store.publicKeyBase64)
            try expectEqual(reloaded.createdAt, store.createdAt)
        }
    },

    TestCase("refresh notifies the sink without handing it the code") {
        try await withIdentity { fileStore in
            let sink = RecordingAccessCodeSink()
            let store = try IdentityStore(fileStore: fileStore, sink: sink)

            try expect(sink.refreshedDeviceIDs.isEmpty, "constructing must not notify the sink")

            let first = try await store.refreshAccessCode()
            try expectEqual(sink.refreshedDeviceIDs, [store.deviceID])

            let second = try await store.refreshAccessCode()
            try expectEqual(sink.refreshedDeviceIDs.count, 2)
            try expectNotEqual(first, second)
        }
    },

    TestCase("repeated refreshes never repeat a code, and each one lands on disk") {
        try await withIdentity { fileStore in
            let store = try IdentityStore(fileStore: fileStore)
            var seen: Set<String> = [store.accessCode]
            for _ in 0..<20 {
                let code = try await store.refreshAccessCode()
                try expectFalse(seen.contains(code), "refresh reissued a code it had already used")
                seen.insert(code)
                try expectEqual(try IdentityStore(fileStore: fileStore).accessCode, code)
            }
            try expectEqual(seen.count, 21)
        }
    },

    TestCase("refresh keeps the new code even when the sink fails") {
        try await withIdentity { fileStore in
            let sink = FailingSink()
            let store = try IdentityStore(fileStore: fileStore, sink: sink)
            let original = store.accessCode

            try await expectThrows("the sink failure") {
                _ = try await store.refreshAccessCode()
            }

            try expectEqual(sink.callCount, 1)
            try expectNotEqual(store.accessCode, original)
            try expectEqual(try IdentityStore(fileStore: fileStore).accessCode, store.accessCode)
            try expectNotNil(store.lastRefreshError)
        }
    },

    TestCase("server-assigned Device ID seam replaces the local one and persists") {
        try await withIdentity { fileStore in
            let store = try IdentityStore(fileStore: fileStore)
            let local = store.deviceID

            try store.adoptServerAssignedDeviceID("482 719 351")
            try expectEqual(store.deviceID, "482719351")
            try expectNotEqual(store.deviceID, local)
            try expectEqual(try IdentityStore(fileStore: fileStore).deviceID, "482719351", "must persist")

            try store.adoptServerAssignedDeviceID("nonsense")
            try expectEqual(store.deviceID, "482719351", "an invalid assignment must be ignored")
        }
    },

    TestCase("signing works through the store and rejects the wrong message") {
        try await withIdentity { fileStore in
            let store = try IdentityStore(fileStore: fileStore)
            let message = Data("challenge".utf8)
            let signature = try store.sign(message)
            try expectFalse(signature.isEmpty)
            try expect(store.verify(signature, for: message))
            try expectFalse(store.verify(signature, for: Data("a different challenge".utf8)),
                            "a signature must not verify against different data")
            try expectEqual(try store.signatureBase64(for: message).isEmpty, false)
            try expectNotNil(Data(base64Encoded: try store.signatureBase64(for: message)))
        }
    },

    TestCase("a corrupt file makes construction fail rather than mint a new identity") {
        try await withIdentity { fileStore in
            let store = try IdentityStore(fileStore: fileStore)
            let originalID = store.deviceID
            let originalBytes = try Data(contentsOf: fileStore.fileURL)

            try Data("{ garbage".utf8).write(to: fileStore.fileURL)

            var caught: Error?
            do { _ = try IdentityStore(fileStore: fileStore) } catch { caught = error }
            let error = try expectNotNil(caught, "a corrupt file must not be papered over")
            try expect((error as? IdentityFileError)?.isResettable == true)

            try originalBytes.write(to: fileStore.fileURL)
            try expectEqual(try IdentityStore(fileStore: fileStore).deviceID, originalID,
                            "the original identity must still be recoverable")
        }
    },

    TestCase("resetIdentity is the only thing that mints a new identity") {
        try await withIdentity { fileStore in
            let before = try IdentityStore(fileStore: fileStore)
            let oldID = before.deviceID
            let oldKey = before.publicKeyBase64

            try IdentityStore.resetIdentity(fileStore: fileStore)
            try expectFalse(FileManager.default.fileExists(atPath: fileStore.fileURL.path))

            let after = try IdentityStore(fileStore: fileStore)
            try expectNotEqual(after.publicKeyBase64, oldKey, "reset must mint a new keypair")
            try expectNotEqual(after.accessCode, before.accessCode)
            try expectNotNil(DeviceID.canonicalize(after.deviceID))
            _ = oldID
        }
    },

    TestCase("a loosened identity file is reported through the store") {
        try await withIdentity { fileStore in
            _ = try IdentityStore(fileStore: fileStore)
            try FileManager.default.setAttributes(
                [.posixPermissions: NSNumber(value: Int16(0o644))],
                ofItemAtPath: fileStore.fileURL.path
            )
            let reopened = try IdentityStore(fileStore: fileStore)
            let warning = try expectNotNil(reopened.permissionWarning,
                                           "the UI needs to be able to show this")
            try expect(warning.contains("0644"))
            try expectEqual(try SecureFile.currentMode(of: fileStore.fileURL), 0o600)
        }
    },

    TestCase("an access code in the identity file is moved into the Keychain") {
        try await withIdentity { fileStore in
            let key = DeviceKey()
            let legacyCode = try AccessCode.generate()
            let legacy = IdentityRecord(deviceID: "482719351", accessCode: legacyCode,
                                        key: key, createdAt: IdentityRecord.timestamp(),
                                        serverRegistered: true)
            try fileStore.save(legacy)
            try expectEqual(try requireLoaded(fileStore).record.accessCode, legacyCode,
                            "the fixture really is a pre-migration file")

            let secrets = SecretStore(blobs: InMemorySecretStore())
            let store = try IdentityStore(fileStore: fileStore, secrets: secrets,
                                          devFileIdentity: true)

            try expectEqual(store.accessCode, legacyCode, "the code must not be regenerated")
            try expectEqual(try secrets.accessCode(), legacyCode, "and it must now be in the store")
            try expectEqual(store.deviceID, "482719351", "the Device ID is untouched by the move")
            try expect(store.isServerRegistered, "and so is the registration flag")
            try expectEqual(store.publicKeyBase64, try key.publicKeyBase64())

            let record = try requireLoaded(fileStore).record
            try expectNil(record.accessCode, "the file copy is dropped: a move, not a copy")
            try expectEqual(record.deviceID, "482719351")

            let reopened = try IdentityStore(fileStore: fileStore, secrets: secrets,
                                             devFileIdentity: true)
            try expectEqual(reopened.accessCode, legacyCode)
            try expectEqual(reopened.deviceID, "482719351")
        }
    },
])

private final class RecordingAccessCodeSink: AccessCodeSink {

    private(set) var refreshedDeviceIDs: [String] = []

    func accessCodeDidChange(deviceID: String) async throws {
        refreshedDeviceIDs.append(deviceID)
    }
}
