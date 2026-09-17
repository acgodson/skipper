import CryptoKit
import Foundation
import RCTestKit
import RemoteControlCore

private func expectRefusal(
    _ expected: (UpdateRefusal) -> Bool,
    file: StaticString = #file,
    line: UInt = #line,
    _ operation: () throws -> Void
) throws {
    do {
        try operation()
    } catch let refusal as UpdateRefusal {
        try expect(expected(refusal), "unexpected refusal \(refusal)", file: file, line: line)
        return
    } catch {
        throw fail("expected an UpdateRefusal, got \(error)", file: file, line: line)
    }
    throw fail("expected the update to be refused", file: file, line: line)
}

private func build(_ raw: String) throws -> BuildNumber {
    try expectNotNil(BuildNumber(raw))
}

private func withTemporaryDirectory(_ body: (URL) throws -> Void) throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("rc-update-tests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    try body(directory)
}

private func makeUnsignedBundle(in directory: URL, identifier: String, build: String) throws -> URL {
    let app = directory.appendingPathComponent("SkipperDesk.app", isDirectory: true)
    let contents = app.appendingPathComponent("Contents", isDirectory: true)
    try FileManager.default.createDirectory(
        at: contents.appendingPathComponent("MacOS"), withIntermediateDirectories: true)
    let info: [String: Any] = [
        "CFBundleIdentifier": identifier,
        "CFBundleVersion": build,
        "CFBundleShortVersionString": "9.9.9",
        "CFBundleExecutable": "SkipperDesk",
        "CFBundlePackageType": "APPL",
    ]
    let data = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
    try data.write(to: contents.appendingPathComponent("Info.plist"))
    try Data("#!/bin/sh\n".utf8).write(to: contents.appendingPathComponent("MacOS/SkipperDesk"))
    return app
}

private let teamID = "ABCDE12345"

public let updateSuite = TestSuite("Self-update", [

    TestCase("build numbers compare numerically, component by component") {
        try expect(try build("4") > build("3"))
        try expect(try build("10") > build("9"))
        try expect(try build("1.10") > build("1.9"))
        try expect(try build("2") > build("1.99.99"))
        try expectEqual(try build("1.0"), try build("1"))
        try expectFalse(try build("1.0") > build("1"))
    },

    TestCase("malformed build numbers are rejected") {
        for raw in ["", "3b", "1..2", "-1", " 3", "1.2.3.4.5", "1234567890", "٣"] {
            try expectNil(BuildNumber(raw), "'\(raw)' parsed")
        }
    },

    TestCase("an equal or lower build is never an update") {
        let running = try build("3")
        try expectEqual(try UpdateTrust.requireNewer(candidate: "4", running: running), try build("4"))
        try expectRefusal({ if case .notNewer = $0 { return true }; return false }) {
            _ = try UpdateTrust.requireNewer(candidate: "3", running: running)
        }
        try expectRefusal({ if case .notNewer = $0 { return true }; return false }) {
            _ = try UpdateTrust.requireNewer(candidate: "2.9", running: running)
        }
        try expectRefusal({ if case .notNewer = $0 { return true }; return false }) {
            _ = try UpdateTrust.requireNewer(candidate: nil, running: running)
        }
    },

    TestCase("a release is offered only when newer and the OS is new enough") {
        let running = try build("3")
        let os = try build("14.2")
        func release(build: String, minimumOS: String) -> AppRelease {
            AppRelease(version: "1.0.1", build: build, minimumOS: minimumOS,
                       url: "https://example.com/a.dmg", sha256: String(repeating: "0", count: 64), size: 1)
        }
        try expect(UpdateTrust.isOffered(release(build: "4", minimumOS: "13.0"), running: running, os: os))
        try expect(UpdateTrust.isOffered(release(build: "4", minimumOS: "14.2"), running: running, os: os))
        try expectFalse(UpdateTrust.isOffered(release(build: "3", minimumOS: "13.0"), running: running, os: os))
        try expectFalse(UpdateTrust.isOffered(release(build: "2", minimumOS: "13.0"), running: running, os: os))
        try expectFalse(UpdateTrust.isOffered(release(build: "4", minimumOS: "15.0"), running: running, os: os))
        try expectFalse(UpdateTrust.isOffered(release(build: "4", minimumOS: "fifteen"), running: running, os: os))
    },

    TestCase("the requirement pins the identifier, Developer ID and the given Team ID") {
        let requirement = try UpdateTrust.designatedRequirement(teamID: teamID)
        try expectEqual(requirement,
            "anchor apple generic and identifier \"app.skipperdesk.desktop\""
            + " and certificate 1[field.1.2.840.113635.100.6.2.6] exists"
            + " and certificate leaf[field.1.2.840.113635.100.6.1.13] exists"
            + " and certificate leaf[subject.OU] = \"ABCDE12345\"")
    },

    TestCase("no requirement is built without a well-formed Team ID") {
        try expectRefusal({ $0 == .noTeamIdentifier }) { _ = try UpdateTrust.designatedRequirement(teamID: nil) }
        try expectRefusal({ $0 == .noTeamIdentifier }) { _ = try UpdateTrust.designatedRequirement(teamID: "") }
        for bad in ["abcde12345", "ABCDE1234", "ABCDE123456", "ABCDE\" or anchor apple", "ABCDE 1234"] {
            try expectRefusal({ $0 == .invalidTeamIdentifier }) {
                _ = try UpdateTrust.designatedRequirement(teamID: bad)
            }
        }
    },

    TestCase("updates are disabled without a Team ID, an app bundle, or a self-consistent signature") {
        try expectEqual(UpdateAvailability.resolve(teamID: nil, isAppBundle: true, runningSatisfies: { _ in true }),
                        .disabledInDevelopment)
        try expectEqual(UpdateAvailability.resolve(teamID: teamID, isAppBundle: false, runningSatisfies: { _ in true }),
                        .disabledInDevelopment)
        try expectEqual(UpdateAvailability.resolve(teamID: teamID, isAppBundle: true, runningSatisfies: { _ in false }),
                        .disabledInDevelopment)
        let requirement = try UpdateTrust.designatedRequirement(teamID: teamID)
        try expectEqual(UpdateAvailability.resolve(teamID: teamID, isAppBundle: true, runningSatisfies: { $0 == requirement }),
                        .enabled(requirement: requirement))
        try expectEqual(UpdateStatus.disabledInDevelopment.sentence, "Updates are disabled in development builds.")
    },

    TestCase("the test runner itself has updates disabled") {
        let checker = UpdateChecker(availability: .current())
        try expectFalse(checker.isEnabled)
        try expectEqual(checker.status, .disabledInDevelopment)
    },

    TestCase("only https, or http on loopback, is an acceptable download source") {
        _ = try UpdateTrust.requireSecureSource("https://downloads.skipperdesk.app/SkipperDesk-1.0.1.dmg")
        _ = try UpdateTrust.requireSecureSource("http://127.0.0.1:18080/SkipperDesk.dmg")
        _ = try UpdateTrust.requireSecureSource("http://localhost/SkipperDesk.dmg")
        for bad in ["http://downloads.skipperdesk.app/a.dmg", "ftp://x/a.dmg", "file:///tmp/a.dmg",
                    "https://user@x/a.dmg", "not a url"] {
            try expectRefusal({ if case .insecureSource = $0 { return true }; return false }) {
                _ = try UpdateTrust.requireSecureSource(bad)
            }
        }
    },

    TestCase("a download must match both the announced size and sha256") {
        try withTemporaryDirectory { directory in
            let fixture = directory.appendingPathComponent("fixture.dmg")
            let bytes = Data((0..<70_000).map { UInt8($0 % 251) })
            try bytes.write(to: fixture)
            let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
            let size = Int64(bytes.count)

            try UpdateVerifier.verifyDownload(at: fixture, sha256: digest, size: size)
            try UpdateVerifier.verifyDownload(at: fixture, sha256: digest.uppercased(), size: size)

            try expectRefusal({ $0 == .sizeMismatch(expected: size + 1, actual: size) }) {
                try UpdateVerifier.verifyDownload(at: fixture, sha256: digest, size: size + 1)
            }
            var flipped = Array(digest)
            flipped[0] = flipped[0] == "0" ? "1" : "0"
            try expectRefusal({ $0 == .digestMismatch }) {
                try UpdateVerifier.verifyDownload(at: fixture, sha256: String(flipped), size: size)
            }
            try expectRefusal({ $0 == .malformedRelease("sha256") }) {
                try UpdateVerifier.verifyDownload(at: fixture, sha256: "abcd", size: size)
            }

            var tampered = bytes
            tampered[35_000] ^= 0xFF
            try tampered.write(to: fixture)
            try expectRefusal({ $0 == .digestMismatch }) {
                try UpdateVerifier.verifyDownload(at: fixture, sha256: digest, size: size)
            }
        }
    },

    TestCase("an unsigned bundle is refused by signature and notarization checks") {
        try withTemporaryDirectory { directory in
            let app = try makeUnsignedBundle(in: directory, identifier: UpdateTrust.bundleIdentifier, build: "99")
            let requirement = try UpdateTrust.designatedRequirement(teamID: teamID)
            try expectRefusal({ if case .signatureInvalid = $0 { return true }; return false }) {
                try UpdateVerifier.verifySignature(ofAppAt: app, requirement: requirement)
            }
            try expectRefusal({ if case .notNotarized = $0 { return true }; return false }) {
                try UpdateVerifier.verifyNotarized(appAt: app)
            }
            try expectRefusal({ if case .signatureInvalid = $0 { return true }; return false }) {
                _ = try UpdateVerifier.verifyApp(at: app, requirement: requirement, newerThan: try build("3"))
            }
        }
    },

    TestCase("a validly signed app from someone else is refused") {
        let calculator = URL(fileURLWithPath: "/System/Applications/Calculator.app")
        guard FileManager.default.fileExists(atPath: calculator.path) else { return }
        let requirement = try UpdateTrust.designatedRequirement(teamID: teamID)
        try expectRefusal({ if case .signatureInvalid = $0 { return true }; return false }) {
            try UpdateVerifier.verifySignature(ofAppAt: calculator, requirement: requirement)
        }
    },

    TestCase("the bundle must be SkipperDesk and strictly newer") {
        try withTemporaryDirectory { directory in
            let running = try build("3")
            let other = try makeUnsignedBundle(in: directory, identifier: "com.example.other", build: "99")
            try expectRefusal({ $0 == .wrongBundleIdentifier("com.example.other") }) {
                _ = try UpdateVerifier.verifyBundle(appAt: other, newerThan: running)
            }
            try FileManager.default.removeItem(at: other)
            let same = try makeUnsignedBundle(in: directory, identifier: UpdateTrust.bundleIdentifier, build: "3")
            try expectRefusal({ if case .notNewer = $0 { return true }; return false }) {
                _ = try UpdateVerifier.verifyBundle(appAt: same, newerThan: running)
            }
            try FileManager.default.removeItem(at: same)
            let newer = try makeUnsignedBundle(in: directory, identifier: UpdateTrust.bundleIdentifier, build: "4")
            let info = try UpdateVerifier.verifyBundle(appAt: newer, newerThan: running)
            try expectEqual(info.build, try build("4"))
            try expectEqual(info.version, "9.9.9")
        }
    },

    TestCase("unattended installs happen only in quiet hours, with no session, when allowed") {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try expectNotNil(TimeZone(identifier: "UTC"))
        func at(_ hour: Int, _ minute: Int) throws -> Date {
            try expectNotNil(calendar.date(from: DateComponents(year: 2026, month: 9, day: 17, hour: hour, minute: minute)))
        }
        func allowed(_ date: Date, auto: Bool = true, session: Bool = false) -> Bool {
            UpdatePolicy.shouldInstallUnattended(at: date, calendar: calendar,
                                                 installsAutomatically: auto, sessionActive: session)
        }
        try expect(allowed(try at(3, 0)))
        try expect(allowed(try at(4, 59)))
        try expectFalse(allowed(try at(2, 59)))
        try expectFalse(allowed(try at(5, 0)))
        try expectFalse(allowed(try at(15, 30)))
        try expectFalse(allowed(try at(3, 30), session: true))
        try expectFalse(allowed(try at(3, 30), auto: false))
        try expectFalse(UpdatePolicy.shouldInstallOnQuit(installsAutomatically: false))
        try expect(UpdatePolicy.shouldInstallOnQuit(installsAutomatically: true))
    },

    TestCase("periodic checks stay within a day plus or minus the jitter") {
        try expectEqual(UpdatePolicy.nextCheckDelay(unit: 0), 23 * 3600)
        try expectEqual(UpdatePolicy.nextCheckDelay(unit: 1), 25 * 3600)
        try expectEqual(UpdatePolicy.nextCheckDelay(unit: 0.5), 24 * 3600)
    },
])
