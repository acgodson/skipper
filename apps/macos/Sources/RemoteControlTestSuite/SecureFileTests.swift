import Foundation
import RCTestKit
import RemoteControlCore

public let secureFileSuite = TestSuite("SecureFile", [

    TestCase("a created directory is 0700, and an existing loose one is tightened") {
        try withTempIdentityDirectory { directory in
            try expect(try SecureFile.ensureDirectory(directory), "the first call must create it")
            try expectEqual(try SecureFile.currentMode(of: directory), 0o700)

            try expectFalse(try SecureFile.ensureDirectory(directory), "the second call must not re-create it")

            try FileManager.default.setAttributes(
                [.posixPermissions: NSNumber(value: Int16(0o777))],
                ofItemAtPath: directory.path
            )
            try SecureFile.ensureDirectory(directory)
            try expectEqual(try SecureFile.currentMode(of: directory), 0o700,
                            "a world-writable directory must be repaired, not accepted")
        }
    },

    TestCase("nested directories are created in one call") {
        try withTempIdentityDirectory { directory in
            let nested = directory.appendingPathComponent("a/b/c", isDirectory: true)
            try SecureFile.ensureDirectory(nested)
            try expectEqual(try SecureFile.currentMode(of: nested), 0o700)
        }
    },

    TestCase("writeAtomically creates the directory and a 0600 file") {
        try withTempIdentityDirectory { directory in
            let file = directory.appendingPathComponent("secret")
            let payload = try SecureRandom.data(4096)
            try SecureFile.writeAtomically(payload, to: file)

            try expectEqual(try Data(contentsOf: file), payload, "large payloads must be written in full")
            try expectEqual(try SecureFile.currentMode(of: file), 0o600)
            try expectEqual(try SecureFile.currentMode(of: directory), 0o700)
        }
    },

    TestCase("a zero-byte payload is written faithfully") {
        try withTempIdentityDirectory { directory in
            let file = directory.appendingPathComponent("empty")
            try SecureFile.writeAtomically(Data(), to: file)
            try expectEqual(try Data(contentsOf: file).count, 0)
        }
    },

    TestCase("read returns nil for an absent file and repairs a loose one") {
        try withTempIdentityDirectory { directory in
            let file = directory.appendingPathComponent("secret")
            try expectNil(try SecureFile.read(file), "an absent file is not an error")

            try SecureFile.writeAtomically(Data("hello".utf8), to: file)
            let clean = try expectNotNil(try SecureFile.read(file))
            try expectNil(clean.warning, "a correct file must not produce a warning")
            try expectEqual(clean.data, Data("hello".utf8))

            for loose: Int16 in [0o644, 0o604, 0o640, 0o666, 0o700] {
                try FileManager.default.setAttributes(
                    [.posixPermissions: NSNumber(value: loose)], ofItemAtPath: file.path
                )
                let read = try expectNotNil(try SecureFile.read(file))
                try expectNotNil(read.warning, "mode \(String(loose, radix: 8)) must be flagged")
                try expectEqual(try SecureFile.currentMode(of: file), 0o600)
                try expectEqual(read.data, Data("hello".utf8), "repairing must not corrupt the contents")
            }
        }
    },

    TestCase("a failed write leaves the previous contents and no temp files") {
        try withTempIdentityDirectory { directory in
            let file = directory.appendingPathComponent("secret")
            try SecureFile.writeAtomically(Data("original".utf8), to: file)

            struct Interrupted: Error {}
            try expectThrowsSync("the injected failure") {
                try SecureFile.writeAtomically(
                    Data("replacement".utf8),
                    to: file,
                    beforeRename: { throw Interrupted() }
                )
            }

            try expectEqual(try Data(contentsOf: file), Data("original".utf8),
                            "an interrupted write must be invisible")
            try expectEqual(
                try FileManager.default.contentsOfDirectory(atPath: directory.path),
                ["secret"],
                "no temp file may survive a failed write"
            )
        }
    },

    TestCase("a failed first-ever write leaves no file at all") {
        try withTempIdentityDirectory { directory in
            let file = directory.appendingPathComponent("secret")
            struct Interrupted: Error {}
            try expectThrowsSync {
                try SecureFile.writeAtomically(Data("x".utf8), to: file, beforeRename: { throw Interrupted() })
            }
            try expectFalse(FileManager.default.fileExists(atPath: file.path),
                            "a half-written file must never become visible")
            try expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
        }
    },

    TestCase("remove reports whether something was there") {
        try withTempIdentityDirectory { directory in
            let file = directory.appendingPathComponent("secret")
            try SecureFile.writeAtomically(Data("x".utf8), to: file)
            try expect(try SecureFile.remove(file))
            try expectFalse(try SecureFile.remove(file))
        }
    },

    TestCase("a file where the directory should be is refused, not clobbered") {
        try withTempIdentityDirectory { directory in
            try SecureFile.ensureDirectory(directory.deletingLastPathComponent())
            try Data("not a directory".utf8).write(to: directory)
            try expectThrowsSync("directoryUnavailable") {
                try SecureFile.ensureDirectory(directory)
            }
            try expectEqual(try Data(contentsOf: directory), Data("not a directory".utf8))
        }
    },
])
