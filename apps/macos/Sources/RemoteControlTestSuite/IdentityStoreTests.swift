import Foundation
import RCTestKit
import RemoteControlCore
import SkipperCore

/// Each case gets its own throwaway directory, so the real identity file is
/// never touched. There is nothing global to clean up any more — that was the
/// whole point of moving off the Keychain.
@MainActor
private func withIdentity(_ body: @MainActor (IdentityFileStore) async throws -> Void) async throws {
    let directory = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("rc-tests-identity-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    try await body(IdentityFileStore(directory: directory))
}

/// A sink that always fails, standing in for "the signaling server is unreachable".
private final class FailingSink: AccessCodeSink {
    struct Boom: Error, LocalizedError { var errorDescription: String? { "no server" } }
    var callCount = 0
    func accessCodeDidChange(deviceID: String, newCode: String) async throws {
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

            // It really is on disk, at 0600, in a 0700 directory.
            try expect(FileManager.default.fileExists(atPath: fileStore.fileURL.path))
            try expectEqual(try SecureFile.currentMode(of: fileStore.fileURL), 0o600)
            try expectEqual(try SecureFile.currentMode(of: fileStore.directory), 0o700)
            try expectEqual(store.keyStorage, .file(fileStore.fileURL))
        }
    },

    // The restart case: a second store over the same file must read the existing
    // values back, not generate new ones.
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

            // And the *private* half survived too: a signature made by the
            // reloaded store verifies under the original's public key.
            let message = Data("nonce".utf8)
            try expect(first.verify(try second.sign(message), for: message),
                       "the reloaded key must be the same private key, not just the same public metadata")

            let record = try requireLoaded(fileStore).record
            try expectEqual(record.accessCode, code)
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

    // THE WRITE-THROUGH CASE the brief calls out explicitly.
    TestCase("refreshAccessCode writes through to disk and the new code survives a reload") {
        try await withIdentity { fileStore in
            let store = try IdentityStore(fileStore: fileStore)
            let original = store.accessCode

            let refreshed = try await store.refreshAccessCode()

            try expectNotEqual(refreshed, original, "refresh must actually change the code")
            try expectEqual(store.accessCode, refreshed)
            try expectNotNil(AccessCode.canonicalize(refreshed))

            // On disk, right now — not just in memory.
            let record = try requireLoaded(fileStore).record
            try expectEqual(record.accessCode, refreshed,
                            "the new code must be the one that survives a restart")
            // And after a full reload.
            let reloaded = try IdentityStore(fileStore: fileStore)
            try expectEqual(reloaded.accessCode, refreshed)
            try expectNotEqual(reloaded.accessCode, original)
            // A refresh must not disturb anything else.
            try expectEqual(reloaded.deviceID, store.deviceID)
            try expectEqual(reloaded.publicKeyBase64, store.publicKeyBase64)
            try expectEqual(reloaded.createdAt, store.createdAt)
        }
    },

    TestCase("refresh notifies the sink with the new code") {
        try await withIdentity { fileStore in
            let sink = PreviewAccessCodeSink()
            let store = try IdentityStore(fileStore: fileStore, sink: sink)
            let original = store.accessCode

            try expect(sink.calls.isEmpty, "constructing must not notify the sink")

            let first = try await store.refreshAccessCode()
            try expectEqual(sink.calls.count, 1)
            try expectEqual(sink.calls.last?.newCode, first)
            try expectEqual(sink.calls.last?.deviceID, store.deviceID)
            try expectNotEqual(sink.calls.last?.newCode, original)

            let second = try await store.refreshAccessCode()
            try expectEqual(sink.calls.count, 2)
            try expectEqual(sink.calls.last?.newCode, second)
            try expectNotEqual(first, second)
            try expectEqual(Set(sink.calls.map(\.newCode)).count, 2)
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
                try expectEqual(try requireLoaded(fileStore).record.accessCode, code)
            }
            try expectEqual(seen.count, 21)
        }
    },

    // Local storage is authoritative; propagation is best-effort.
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
            try expectEqual(try requireLoaded(fileStore).record.accessCode, store.accessCode)
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

    // The user's complaint, expressed as a test: a damaged file must not silently
    // hand the user a brand-new Device ID.
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

            // Nothing was rewritten, so restoring the file restores the identity.
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
            // Device IDs are 9 random digits, so a collision is ~1-in-900-million;
            // assert the key instead and just note the ID changed shape-correctly.
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
])
