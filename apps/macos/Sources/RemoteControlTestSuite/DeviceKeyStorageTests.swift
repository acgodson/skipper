import Foundation
import CryptoKit
import Security
import RCTestKit
import RemoteControlCore

// TODO: verify on a Developer-ID-signed build. These cases run in a plain test

@MainActor
private func withIdentityDirectory(
    _ body: @MainActor (IdentityFileStore, InMemoryDeviceKeyStore) async throws -> Void
) async throws {
    let directory = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("rc-tests-storage-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    try await body(IdentityFileStore(directory: directory), InMemoryDeviceKeyStore())
}

private func writeFileBackedIdentity(_ fileStore: IdentityFileStore, key: DeviceKey) throws -> IdentityRecord {
    let record = IdentityRecord(
        deviceID: try DeviceID.generateLocal(),
        accessCode: try AccessCode.generate(),
        key: key,
        createdAt: IdentityRecord.timestamp()
    )
    try fileStore.save(record)
    return record
}

public let deviceKeyStorageSuite = TestSuite("DeviceKeyStorage", [

    // MARK: - Wire compatibility

    TestCase("a Keychain key emits DER SPKI and DER ECDSA, exactly as the Go verifier expects") {
        let store = InMemoryDeviceKeyStore()
        let key = try KeychainDeviceKey.create(in: store)

        try expectEqual(key.storage, .keychain)
        try expectEqual(key.publicKeyDER.count, 91, "P-256 SPKI")
        try expectEqual(key.publicKeyDER.first, 0x30)
        try expectEqual(Data(base64Encoded: key.publicKeyBase64), key.publicKeyDER)

        let nonce = try SecureRandom.data(32)
        let signature = try key.sign(nonce)
        try expectEqual(signature.first, 0x30, "ASN.1 DER SEQUENCE, not raw r||s")
        try expectNotEqual(signature.count, 64, "64 bytes would be raw r||s, which Go rejects")

        let publicKey = try P256.Signing.PublicKey(derRepresentation: key.publicKeyDER)
        let parsed = try P256.Signing.ECDSASignature(derRepresentation: signature)
        try expect(publicKey.isValidSignature(parsed, for: nonce))
        try expectFalse(
            publicKey.isValidSignature(parsed, for: Data(nonce.base64EncodedString().utf8)),
            "must be a signature over the raw nonce, not over its base64 text"
        )

        var tampered = signature
        tampered[tampered.count - 1] ^= 0x01
        try expectFalse(key.verify(tampered, for: nonce), "a tampered signature must be rejected")
    },

    TestCase("a Keychain key reloads from the stored blob as the same key") {
        let store = InMemoryDeviceKeyStore()
        let created = try KeychainDeviceKey.create(in: store)
        let reloaded = try expectNotNil(try KeychainDeviceKey.load(from: store))

        try expectEqual(reloaded.publicKeyDER, created.publicKeyDER)
        let message = Data("nonce".utf8)
        try expect(created.verify(try reloaded.sign(message), for: message),
                   "the reloaded key must be the same private key")
    },

    TestCase("nothing stored means nothing loaded — never a silently minted key") {
        try expectNil(try KeychainDeviceKey.load(from: InMemoryDeviceKeyStore()))
    },

    // MARK: - Migration

    TestCase("an existing file key moves to the Keychain and keeps its Device ID") {
        try await withIdentityDirectory { fileStore, blobStore in
            let original = DeviceKey()
            let before = try writeFileBackedIdentity(fileStore, key: original)

            let store = try IdentityStore(fileStore: fileStore, blobStore: blobStore, devFileIdentity: false)

            try expectEqual(store.deviceID, before.deviceID, "the Device ID must survive the migration")
            try expectEqual(store.accessCode, before.accessCode)
            try expectEqual(store.createdAt, before.createdAt)
            try expectEqual(store.keyStorage, .keychain)
            try expectEqual(store.keyStorageLabel, "Keychain")
            try expectEqual(store.publicKeyBase64, try original.publicKeyBase64(),
                            "the SAME key must move; a new key would change this device's identity")

            let stored = try expectNotNil(try blobStore.load(.software))
            try expectEqual(try DeviceKey(rawPrivateKey: stored).publicKeyBase64(),
                            try original.publicKeyBase64())
            let record = try requireLoaded(fileStore).record
            try expectNil(record.privateKeyBase64, "the file must no longer hold the private key")
            try expectEqual(record.keyStorage, "keychain")
            try expectEqual(record.deviceID, before.deviceID)
        }
    },

    TestCase("a migrated identity reopens from the Keychain, still unchanged") {
        try await withIdentityDirectory { fileStore, blobStore in
            let original = DeviceKey()
            let before = try writeFileBackedIdentity(fileStore, key: original)

            _ = try IdentityStore(fileStore: fileStore, blobStore: blobStore, devFileIdentity: false)
            let second = try IdentityStore(fileStore: fileStore, blobStore: blobStore, devFileIdentity: false)

            try expectEqual(second.deviceID, before.deviceID)
            try expectEqual(second.keyStorage, .keychain)
            try expectEqual(second.publicKeyBase64, try original.publicKeyBase64())

            let message = Data("nonce".utf8)
            try expect(second.verify(try second.sign(message), for: message))
        }
    },

    TestCase("a Keychain that refuses leaves the key in the file rather than regenerating") {
        try await withIdentityDirectory { fileStore, blobStore in
            let original = DeviceKey()
            let before = try writeFileBackedIdentity(fileStore, key: original)
            blobStore.isSealed = true

            let store = try IdentityStore(fileStore: fileStore, blobStore: blobStore, devFileIdentity: false)

            try expectEqual(store.deviceID, before.deviceID)
            try expectEqual(store.publicKeyBase64, try original.publicKeyBase64())
            try expectEqual(store.keyStorage, .file(fileStore.fileURL))
            try expectEqual(store.keyStorageLabel, "file (dev)")
            try expectNotNil(store.keyStorageNote, "the UI must be told the key did not move")
            let kept = try expectNotNil(try requireLoaded(fileStore).record.privateKeyBase64)
            try expectEqual(try DeviceKey(rawPrivateKey: try expectNotNil(Data(base64Encoded: kept))).publicKeyBase64(),
                            try original.publicKeyBase64(),
                            "the file copy must stay while it is the only copy")
        }
    },

    // MARK: - Selection order

    TestCase("a brand-new identity takes the strongest backend that works, never the file") {
        try await withIdentityDirectory { fileStore, blobStore in
            let store = try IdentityStore(fileStore: fileStore, blobStore: blobStore, devFileIdentity: false)

            let expected: DeviceKeyStorage = SecureEnclaveDeviceKey.isSupported ? .secureEnclave : .keychain
            try expectEqual(store.keyStorage, expected)
            try expectEqual(try requireLoaded(fileStore).record.keyStorage, expected.recordValue)
            try expectNil(try requireLoaded(fileStore).record.privateKeyBase64,
                          "a new identity must never leave its private key in the file")
            try expectEqual(store.publicKeyHex.count, 130)

            let message = Data("nonce".utf8)
            try expect(store.verify(try store.sign(message), for: message))

            let reopened = try IdentityStore(fileStore: fileStore, blobStore: blobStore, devFileIdentity: false)
            try expectEqual(reopened.deviceID, store.deviceID)
            try expectEqual(reopened.publicKeyBase64, store.publicKeyBase64)
            try expectEqual(reopened.keyStorage, expected)
        }
    },

    TestCase("a Keychain-backed identity whose key has vanished is refused, never re-minted") {
        try await withIdentityDirectory { fileStore, blobStore in
            _ = try writeFileBackedIdentity(fileStore, key: DeviceKey())
            let first = try IdentityStore(fileStore: fileStore, blobStore: blobStore, devFileIdentity: false)
            try expectEqual(first.keyStorage, .keychain)
            try blobStore.remove(.software)

            var caught: IdentityFileError?
            do {
                _ = try IdentityStore(fileStore: fileStore, blobStore: blobStore, devFileIdentity: false)
            } catch let error as IdentityFileError {
                caught = error
            }
            let error = try expectNotNil(caught)
            guard case .invalidContents = error else { throw fail("expected .invalidContents, got \(error)") }
            try expectEqual(try requireLoaded(fileStore).record.deviceID, first.deviceID,
                            "a failed open must leave the identity file alone")
        }
    },

    TestCase("an overridden identity directory keeps the key in the file") {
        try await withIdentityDirectory { fileStore, blobStore in
            try expectFalse(fileStore.isDefaultLocation)
            try expect(IdentityStore.usesDevFileIdentity(fileStore: fileStore))

            let store = try IdentityStore(fileStore: fileStore, blobStore: blobStore)
            try expectEqual(store.keyStorage, .file(fileStore.fileURL))
            try expectNotNil(try requireLoaded(fileStore).record.privateKeyBase64)
            try expectNil(try blobStore.load(.software), "the shared Keychain slot must be left alone")

            let reopened = try IdentityStore(fileStore: fileStore, blobStore: blobStore)
            try expectEqual(reopened.deviceID, store.deviceID)
            try expectEqual(reopened.publicKeyBase64, store.publicKeyBase64)
        }
    },

    TestCase("the storage kind has a plain label and no jargon") {
        try expectEqual(DeviceKeyStorage.secureEnclave.label, "Secure Enclave")
        try expectEqual(DeviceKeyStorage.keychain.label, "Keychain")
        try expectEqual(DeviceKeyStorage.file(URL(fileURLWithPath: "/tmp/x")).label, "file (dev)")
        try expectEqual(DeviceKeyStorage.secureEnclave.recordValue, "secureEnclave")
        try expectEqual(DeviceKeyStorage.keychain.recordValue, "keychain")
        try expectEqual(DeviceKeyStorage.file(URL(fileURLWithPath: "/tmp/x")).recordValue, "file")
    },

    // MARK: - Fail closed

    TestCase("policy: a new key goes to the Secure Enclave, else the Keychain, else nowhere") {
        let sealed = KeychainError.status(errSecNotAvailable)
        try expectEqual(DeviceKeyPolicy.newKey(secureEnclaveFailure: nil, keychainFailure: nil), .secureEnclave)
        guard case .keychain(let note?) = DeviceKeyPolicy.newKey(secureEnclaveFailure: sealed, keychainFailure: nil) else {
            throw fail("a working Keychain must be used, with a note")
        }
        try expect(note.contains("Secure Enclave"))
        try expectEqual(DeviceKeyPolicy.newKey(secureEnclaveFailure: sealed, keychainFailure: sealed),
                        .refuse(.notStoredSecurely(detail: sealed.localizedDescription)),
                        "a signed build must never fall back to the file")
        try expectEqual(DeviceKeyPolicy.newKey(secureEnclaveFailure: KeychainError.unsigned,
                                               keychainFailure: KeychainError.unsigned),
                        .refuse(.unsigned))
        let message = try expectNotNil(DeviceKeyRefusal.notStoredSecurely(detail: "x").error.localizedDescription)
        try expect(message.hasPrefix("SkipperDesk could not store its key securely."), message)
    },

    TestCase("policy: an existing file key moves, or is used for this launch with a visible note, never regenerates") {
        let sealed = KeychainError.status(errSecNotAvailable)
        try expectEqual(DeviceKeyPolicy.existingFileKey(migrationFailure: nil), .moveToKeychain)
        try expectEqual(DeviceKeyPolicy.existingFileKey(migrationFailure: sealed),
                        .useFileForThisLaunch(note: "This Mac's key could not be moved to secure storage."),
                        "a failed move is never silently fine")
        try expectEqual(DeviceKeyPolicy.existingFileKey(migrationFailure: KeychainError.unsigned), .refuse(.unsigned))
    },

    TestCase("a new identity with no secure store fails closed and writes nothing") {
        try await withIdentityDirectory { fileStore, blobStore in
            blobStore.isSealed = true
            var caught: Error?
            do {
                _ = try IdentityStore(fileStore: fileStore, blobStore: blobStore, devFileIdentity: false)
            } catch {
                caught = error
            }
            let error = try expectNotNil(caught, "identity creation must fail")
            guard case .notStoredSecurely = error as? DeviceKeyStorageError else {
                throw fail("expected DeviceKeyStorageError.notStoredSecurely, got \(error)")
            }
            try expect(error.localizedDescription.hasPrefix("SkipperDesk could not store its key securely."))
            try expectNil(try fileStore.load(), "no identity file may be written, least of all one holding a key")
        }
    },
])
