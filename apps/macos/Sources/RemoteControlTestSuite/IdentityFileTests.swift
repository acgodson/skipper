import Foundation
import RCTestKit
import RemoteControlCore

/// Every case runs against a throwaway directory under the system temp dir, so
/// the user's real `~/Library/Application Support/RemoteControl/identity.json`
/// is never read, written or deleted by the test suite.
func withTempIdentityDirectory(_ body: (URL) throws -> Void) throws {
    let directory = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("rc-tests-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    try body(directory)
}

/// `expectNotNil` cannot infer the type through a nested generic here, and an
/// explicit annotation at every call site would drown the assertions.
func requireLoaded(
    _ store: IdentityFileStore,
    file: StaticString = #file,
    line: UInt = #line
) throws -> IdentityFileStore.Loaded {
    guard let loaded = try store.load() else {
        throw fail("expected an identity on disk, found none", file: file, line: line)
    }
    return loaded
}

private func mode(of url: URL) throws -> Int16 {
    try SecureFile.currentMode(of: url)
}

/// A complete, genuinely valid record: real nine-digit ID, real 12-symbol code,
/// real P-256 key. Everything `load()` validates has to actually hold.
private func sampleRecord() throws -> IdentityRecord {
    IdentityRecord(
        deviceID: try DeviceID.generateLocal(),
        accessCode: try AccessCode.generate(),
        key: DeviceKey(),
        createdAt: Date(timeIntervalSince1970: 1_755_600_000)
    )
}

public let identityFileSuite = TestSuite("IdentityFileStore", [

    // MARK: Round trip

    TestCase("an identity round-trips byte-identically through the file") {
        try withTempIdentityDirectory { directory in
            let store = IdentityFileStore(directory: directory)
            let record = try sampleRecord()

            try store.save(record)
            let loaded = try requireLoaded(store).record

            try expectEqual(loaded, record, "every field must survive the round trip unchanged")
            try expectEqual(loaded.privateKeyBase64, record.privateKeyBase64)
            try expectEqual(loaded.deviceID, record.deviceID)
            try expectEqual(loaded.accessCode, record.accessCode)
            try expectEqual(loaded.createdAt, record.createdAt)
            try expectEqual(loaded.schemaVersion, IdentityRecord.currentSchemaVersion)
        }
    },

    TestCase("no file yet means first launch, not an error") {
        try withTempIdentityDirectory { directory in
            let store = IdentityFileStore(directory: directory)
            try expectNil(try store.load(), "an absent file must load as nil, not throw")
        }
    },

    // MARK: Permissions

    TestCase("the file is created 0600 and the directory 0700") {
        try withTempIdentityDirectory { directory in
            let store = IdentityFileStore(directory: directory)
            let record = try sampleRecord()
            try store.save(record)

            try expectEqual(try mode(of: store.fileURL), 0o600, "the identity file must be owner read/write only")
            try expectEqual(try mode(of: directory), 0o700, "the directory must be owner-only")
        }
    },

    TestCase("a world-readable file is detected and tightened, with a warning") {
        try withTempIdentityDirectory { directory in
            let store = IdentityFileStore(directory: directory)
            let record = try sampleRecord()
            try store.save(record)

            // Deliberately loosen it, exactly as a bad backup restore would.
            try FileManager.default.setAttributes(
                [.posixPermissions: NSNumber(value: Int16(0o644))],
                ofItemAtPath: store.fileURL.path
            )
            try expectEqual(try mode(of: store.fileURL), 0o644, "the test setup itself must have loosened it")

            let loaded = try requireLoaded(store)
            try expectNotNil(loaded.permissionWarning, "loosened permissions must be reported, not silently fixed")
            try expect(loaded.permissionWarning!.contains("0644"), "the warning must name the mode it found")
            try expectEqual(try mode(of: store.fileURL), 0o600, "and must actually be repaired on disk")

            // A second load finds it already correct and says nothing.
            try expectNil(try requireLoaded(store).permissionWarning)
        }
    },

    TestCase("a loosened directory is re-tightened on the next write") {
        try withTempIdentityDirectory { directory in
            let store = IdentityFileStore(directory: directory)
            let record = try sampleRecord()
            try store.save(record)

            try FileManager.default.setAttributes(
                [.posixPermissions: NSNumber(value: Int16(0o755))],
                ofItemAtPath: directory.path
            )
            try expectEqual(try mode(of: directory), 0o755)

            try store.save(record)
            try expectEqual(try mode(of: directory), 0o700)
        }
    },

    // MARK: Corruption never regenerates

    TestCase("a corrupt file errors specifically and does NOT regenerate") {
        try withTempIdentityDirectory { directory in
            let store = IdentityFileStore(directory: directory)
            let record = try sampleRecord()
            try store.save(record)

            let damaged = Data("{ this is not json".utf8)
            try damaged.write(to: store.fileURL)

            var caught: IdentityFileError?
            do {
                _ = try store.load()
            } catch let error as IdentityFileError {
                caught = error
            }
            let error = try expectNotNil(caught, "a damaged file must throw IdentityFileError")
            guard case .corrupt = error else {
                throw fail("expected .corrupt, got \(error)")
            }
            try expect(error.isResettable, "the UI must be able to offer Reset Identity")
            try expect(error.errorDescription!.contains("NOT been replaced"),
                       "the message must tell the user their identity was left alone")

            // THE POINT OF THIS CASE: the bytes on disk are untouched.
            try expectEqual(try Data(contentsOf: store.fileURL), damaged,
                            "loading a corrupt file must not rewrite or delete it")
        }
    },

    TestCase("an empty file is corrupt, not first launch") {
        try withTempIdentityDirectory { directory in
            let store = IdentityFileStore(directory: directory)
            try SecureFile.ensureDirectory(directory)
            try Data().write(to: store.fileURL)

            var caught: IdentityFileError?
            do { _ = try store.load() } catch let error as IdentityFileError { caught = error }
            let error = try expectNotNil(caught)
            guard case .corrupt(_, let reason) = error else {
                throw fail("expected .corrupt, got \(error)")
            }
            try expect(reason.contains("empty"), "reason was \(reason)")
        }
    },

    TestCase("structurally valid JSON with nonsense contents is rejected") {
        try withTempIdentityDirectory { directory in
            let store = IdentityFileStore(directory: directory)
            try SecureFile.ensureDirectory(directory)

            // deviceId that is not nine digits, valid everything else.
            let bad: [String: Any] = [
                "schemaVersion": 1,
                "deviceId": "12",
                "accessCode": try AccessCode.generate(),
                "privateKey": IdentityRecord(deviceID: "111111111", accessCode: try AccessCode.generate(), key: DeviceKey(), createdAt: Date()).privateKeyBase64,
                "createdAt": "2026-08-19T00:00:00Z",
            ]
            try JSONSerialization.data(withJSONObject: bad).write(to: store.fileURL)

            var caught: IdentityFileError?
            do { _ = try store.load() } catch let error as IdentityFileError { caught = error }
            let error = try expectNotNil(caught)
            guard case .invalidContents = error else {
                throw fail("expected .invalidContents, got \(error)")
            }
            try expect(error.isResettable)
        }
    },

    TestCase("a private key that is not a P-256 scalar is rejected") {
        try withTempIdentityDirectory { directory in
            let store = IdentityFileStore(directory: directory)
            try SecureFile.ensureDirectory(directory)
            let bad: [String: Any] = [
                "schemaVersion": 1,
                "deviceId": try DeviceID.generateLocal(),
                "accessCode": try AccessCode.generate(),
                // 32 bytes of 0xFF is above the curve order: not a usable scalar.
                "privateKey": Data(repeating: 0xFF, count: 32).base64EncodedString(),
                "createdAt": "2026-08-19T00:00:00Z",
            ]
            try JSONSerialization.data(withJSONObject: bad).write(to: store.fileURL)
            try expectThrowsSync { _ = try store.load() }
        }
    },

    TestCase("a newer schema version is refused rather than misread") {
        try withTempIdentityDirectory { directory in
            let store = IdentityFileStore(directory: directory)
            var record = try sampleRecord()
            record.schemaVersion = IdentityRecord.currentSchemaVersion + 1
            try store.save(record)

            var caught: IdentityFileError?
            do { _ = try store.load() } catch let error as IdentityFileError { caught = error }
            let error = try expectNotNil(caught)
            guard case .unsupportedSchema(_, let found, let supported) = error else {
                throw fail("expected .unsupportedSchema, got \(error)")
            }
            try expectEqual(found, IdentityRecord.currentSchemaVersion + 1)
            try expectEqual(supported, IdentityRecord.currentSchemaVersion)
        }
    },

    // MARK: Atomicity

    TestCase("a write that fails part-way leaves the previous identity intact") {
        try withTempIdentityDirectory { directory in
            let good = try sampleRecord()
            try IdentityFileStore(directory: directory).save(good)
            let goodBytes = try Data(contentsOf: IdentityFileStore(directory: directory).fileURL)

            struct Interrupted: Error {}
            // Same store, but the write is aborted after the temp file exists and
            // has been fsynced — the exact window a crash would land in.
            let failing = IdentityFileStore(directory: directory, beforeRename: { throw Interrupted() })
            let replacement = try sampleRecord()
            try expectThrowsSync { try failing.save(replacement) }

            let store = IdentityFileStore(directory: directory)
            try expectEqual(try Data(contentsOf: store.fileURL), goodBytes,
                            "the interrupted write must not have touched the live file")
            let reloaded = try requireLoaded(store).record
            try expectEqual(reloaded, good, "the previous identity must still load")
            try expectNotEqual(reloaded.deviceID, replacement.deviceID)

            // And no half-written temp file is left behind holding key material.
            let leftovers = try FileManager.default.contentsOfDirectory(atPath: directory.path)
                .filter { $0.contains(".tmp-") }
            try expect(leftovers.isEmpty, "temp files left behind: \(leftovers)")
        }
    },

    TestCase("overwriting repeatedly never leaves a partial or extra file") {
        try withTempIdentityDirectory { directory in
            let store = IdentityFileStore(directory: directory)
            for _ in 0..<25 {
                let record = try sampleRecord()
                try store.save(record)
                let loaded = try requireLoaded(store).record
                try expectEqual(loaded, record)
            }
            let entries = try FileManager.default.contentsOfDirectory(atPath: directory.path)
            try expectEqual(entries, [IdentityFileStore.fileName], "the directory must hold exactly one file")
        }
    },

    // MARK: Reset

    TestCase("reset removes the file and reports whether it was there") {
        try withTempIdentityDirectory { directory in
            let store = IdentityFileStore(directory: directory)
            let record = try sampleRecord()
            try store.save(record)

            try expect(try store.reset(), "reset must report that it removed something")
            try expectNil(try store.load(), "after a reset the store looks like first launch")
            try expectFalse(try store.reset(), "a second reset has nothing to remove")
        }
    },

    // MARK: Peer code

    TestCase("the saved peer code round-trips and is 0600") {
        try withTempIdentityDirectory { directory in
            let store = IdentityFileStore(directory: directory)
            try expectNil(try store.loadPeerAccessCode())

            let code = try AccessCode.generate()
            try store.savePeerAccessCode(AccessCode.formatted(code).lowercased())
            try expectEqual(try store.loadPeerAccessCode(), code, "it must be stored canonicalised")
            try expectEqual(try mode(of: store.peerCodeURL), 0o600)

            try expect(try store.forgetPeerAccessCode())
            try expectNil(try store.loadPeerAccessCode())
            try expectFalse(try store.forgetPeerAccessCode())
        }
    },

    TestCase("an invalid peer code is not written at all") {
        try withTempIdentityDirectory { directory in
            let store = IdentityFileStore(directory: directory)
            try store.savePeerAccessCode("nope")
            try expectFalse(FileManager.default.fileExists(atPath: store.peerCodeURL.path))
        }
    },

    TestCase("forgetting the peer code never touches the identity file") {
        try withTempIdentityDirectory { directory in
            let store = IdentityFileStore(directory: directory)
            let record = try sampleRecord()
            try store.save(record)
            try store.savePeerAccessCode(try AccessCode.generate())

            try expect(try store.forgetPeerAccessCode())
            try expectEqual(try requireLoaded(store).record, record)
        }
    },
])

// MARK: - Helpers

/// `expectThrows` in RCTestKit is async; these bodies are synchronous. This keeps
/// the call sites readable without making every case pointlessly async, and it
/// reports through the runner like any other assertion rather than trapping.
func expectThrowsSync(
    _ description: String = "an error",
    file: StaticString = #file,
    line: UInt = #line,
    _ body: () throws -> Void
) throws {
    do {
        try body()
    } catch {
        return
    }
    throw fail("expected \(description) to be thrown", file: file, line: line)
}
