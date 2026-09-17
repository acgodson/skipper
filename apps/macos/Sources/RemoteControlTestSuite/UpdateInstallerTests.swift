#if DEBUG || SKIPPER_TEST_HOOKS
import Foundation
import RCTestKit
import RemoteControlCore
import SkipperCore

private let adHocRequirement = "identifier \"\(UpdateTrust.bundleIdentifier)\""

private func makeSignedBundle(in directory: URL, build: String) throws -> URL {
    let app = try makeUnsignedBundle(in: directory, identifier: UpdateTrust.bundleIdentifier, build: build)
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
    process.arguments = ["--force", "--sign", "-", "--identifier", UpdateTrust.bundleIdentifier, app.path]
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    try process.run()
    process.waitUntilExit()
    try expectEqual(process.terminationStatus, 0, "codesign failed")
    return app
}

private func installer(installURL: URL, workRoot: URL, running: String = "3") throws -> UpdateInstaller {
    UpdateInstaller.forTesting(
        policy: .withoutNotarization(requirement: adHocRequirement),
        runningBuild: try build(running), installURL: installURL, workRoot: workRoot)
}

private func release(build: String, size: Int64 = 1, url: String = "https://example.com/a.dmg") -> AppRelease {
    AppRelease(version: "1.0.1", build: build, minimumOS: "13.0", url: url,
               sha256: String(repeating: "0", count: 64), size: size)
}

private func expectPrepareRefused(
    _ installer: UpdateInstaller, _ release: AppRelease, _ expected: @escaping (UpdateRefusal) -> Bool
) throws {
    let outcome = BlockingOutcome()
    Task.detached {
        do {
            _ = try await installer.prepare(release)
            outcome.finish(nil)
        } catch {
            outcome.finish(error)
        }
    }
    guard let error = outcome.wait() else { throw fail("expected prepare to refuse \(release.build)") }
    guard let refusal = error as? UpdateRefusal else { throw fail("expected an UpdateRefusal, got \(error)") }
    try expect(expected(refusal), "unexpected refusal \(refusal)")
}

private final class BlockingOutcome: @unchecked Sendable {
    private let semaphore = DispatchSemaphore(value: 0)
    private var error: Error?

    func finish(_ error: Error?) {
        self.error = error
        semaphore.signal()
    }

    func wait() -> Error? {
        semaphore.wait()
        return error
    }
}

let updateInstallerCases: [TestCase] = [

    TestCase("prepare refuses an oversized or insecure release before downloading") {
        try withTemporaryDirectory { directory in
            let subject = try installer(installURL: directory.appendingPathComponent("SkipperDesk.app"),
                                        workRoot: directory.appendingPathComponent("support/Updates"))
            try expectPrepareRefused(subject, release(build: "4", size: UpdateTrust.maximumDownloadBytes + 1)) {
                $0 == .exceedsSizeCap(UpdateTrust.maximumDownloadBytes + 1)
            }
            try expectPrepareRefused(subject, release(build: "4", url: "http://downloads.skipperdesk.app/a.dmg")) {
                if case .insecureSource = $0 { return true }; return false
            }
        }
    },

    TestCase("never downgrade below the copy at the install location") {
        try withTemporaryDirectory { directory in
            let installed = try makeUnsignedBundle(in: directory, identifier: UpdateTrust.bundleIdentifier, build: "10")
            let subject = try installer(installURL: installed, workRoot: directory.appendingPathComponent("support/Updates"))
            try expectEqual(subject.installedBuild, try build("10"))
            try expectEqual(subject.buildFloor, try build("10"))
            for candidate in ["4", "9.9", "10", "10.0"] {
                try expectPrepareRefused(subject, release(build: candidate)) {
                    if case .notNewer = $0 { return true }; return false
                }
            }

            let source = directory.appendingPathComponent("source", isDirectory: true)
            try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
            let older = try makeSignedBundle(in: source, build: "5")
            try expectRefusal({ if case .notNewer = $0 { return true }; return false }) {
                _ = try subject.stage(appAt: older)
            }
            try expectEqual(UpdateVerifier.installedBuild(at: installed), try build("10"))

            try FileManager.default.removeItem(at: installed)
            _ = try makeUnsignedBundle(in: directory, identifier: "com.example.other", build: "99")
            try expectNil(subject.installedBuild)
            try expectEqual(subject.buildFloor, try build("3"))
        }
    },

    TestCase("a staged bundle is copied into a private directory and installed only after re-verification") {
        try withTemporaryDirectory { directory in
            let workRoot = directory.appendingPathComponent("support/Updates", isDirectory: true)
            let applications = directory.appendingPathComponent("Applications", isDirectory: true)
            try FileManager.default.createDirectory(at: applications, withIntermediateDirectories: true)
            let target = try makeUnsignedBundle(in: applications, identifier: UpdateTrust.bundleIdentifier, build: "3")
            let source = directory.appendingPathComponent("source", isDirectory: true)
            try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
            let newer = try makeSignedBundle(in: source, build: "4")
            let subject = try installer(installURL: target, workRoot: workRoot)

            let staged = try subject.stage(appAt: newer)
            try expect(staged.appURL.path.hasPrefix(workRoot.path + "/"))
            let work = staged.appURL.deletingLastPathComponent()
            let mode = try FileManager.default.attributesOfItem(atPath: work.path)[.posixPermissions] as? NSNumber
            try expectEqual(mode?.intValue, 0o700)
            try expectEqual((try FileManager.default.attributesOfItem(atPath: workRoot.path)[.posixPermissions] as? NSNumber)?.intValue, 0o700)

            try FileManager.default.removeItem(at: staged.appURL.appendingPathComponent("Contents/_CodeSignature"))
            try expectRefusal({ if case .signatureInvalid = $0 { return true }; return false }) {
                try subject.install(staged)
            }
            try expectEqual(UpdateVerifier.installedBuild(at: target), try build("3"))
            try expectFalse(FileManager.default.fileExists(atPath: work.path))
            try expectEqual(try FileManager.default.contentsOfDirectory(atPath: applications.path), ["SkipperDesk.app"])

            let swapped = try subject.stage(appAt: newer)
            let decoy = directory.appendingPathComponent("decoy", isDirectory: true)
            try FileManager.default.createDirectory(at: decoy, withIntermediateDirectories: true)
            let unsigned = try makeUnsignedBundle(in: decoy, identifier: UpdateTrust.bundleIdentifier, build: "99")
            try FileManager.default.removeItem(at: swapped.appURL)
            try FileManager.default.moveItem(at: unsigned, to: swapped.appURL)
            try expectRefusal({
                switch $0 {
                case .signatureInvalid, .installedCopyRejected: return true
                default: return false
                }
            }) {
                try subject.install(swapped)
            }
            try expectEqual(UpdateVerifier.installedBuild(at: target), try build("3"))
            try expectEqual(try FileManager.default.contentsOfDirectory(atPath: applications.path), ["SkipperDesk.app"])

            let good = try subject.stage(appAt: newer)
            var besideDuringInstall: [String] = []
            subject.afterSwapForTesting = { _ in
                besideDuringInstall = (try? FileManager.default.contentsOfDirectory(atPath: applications.path)) ?? []
            }
            try subject.install(good)
            try expectEqual(besideDuringInstall, ["SkipperDesk.app"])
            try expectEqual(try FileManager.default.contentsOfDirectory(atPath: workRoot.path), [])
            try expectEqual(UpdateVerifier.installedBuild(at: target), try build("4"))
            try UpdateVerifier.verifySignature(ofAppAt: target, requirement: adHocRequirement)
            try expectFalse(FileManager.default.fileExists(atPath: good.appURL.deletingLastPathComponent().path))
            let leftovers = try FileManager.default.contentsOfDirectory(atPath: applications.path)
            try expectEqual(leftovers, ["SkipperDesk.app"])

            try expectRefusal({ if case .notNewer = $0 { return true }; return false }) {
                _ = try subject.stage(appAt: newer)
            }
        }
    },

    TestCase("the update work directory refuses a planted or shared parent") {
        try withTemporaryDirectory { directory in
            let shared = directory.appendingPathComponent("shared/Updates", isDirectory: true)
            try FileManager.default.createDirectory(at: shared, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o777])
            try FileManager.default.setAttributes([.posixPermissions: 0o777], ofItemAtPath: shared.path)
            let source = directory.appendingPathComponent("source", isDirectory: true)
            try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
            let newer = try makeSignedBundle(in: source, build: "4")
            let target = directory.appendingPathComponent("SkipperDesk.app")
            try expectRefusal({ if case .unsafeWorkDirectory = $0 { return true }; return false }) {
                _ = try installer(installURL: target, workRoot: shared).stage(appAt: newer)
            }

            let elsewhere = directory.appendingPathComponent("elsewhere", isDirectory: true)
            try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            let linkParent = directory.appendingPathComponent("linked", isDirectory: true)
            try FileManager.default.createDirectory(at: linkParent, withIntermediateDirectories: true)
            let link = linkParent.appendingPathComponent("Updates")
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: elsewhere)
            try expectRefusal({ if case .unsafeWorkDirectory = $0 { return true }; return false }) {
                _ = try installer(installURL: target, workRoot: link).stage(appAt: newer)
            }

            let openParent = directory.appendingPathComponent("open", isDirectory: true)
            let privateRoot = openParent.appendingPathComponent("Updates", isDirectory: true)
            try FileManager.default.createDirectory(at: privateRoot, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            for mode in [0o777, 0o775, 0o757] {
                try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: openParent.path)
                try expectRefusal({ if case .unsafeWorkDirectory = $0 { return true }; return false }) {
                    _ = try installer(installURL: target, workRoot: privateRoot).stage(appAt: newer)
                }
            }
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: openParent.path)
            _ = try installer(installURL: target, workRoot: privateRoot).stage(appAt: newer)
        }
    },

    TestCase("the sealed build and version must be the ones the release announced") {
        try withTemporaryDirectory { directory in
            let source = directory.appendingPathComponent("source", isDirectory: true)
            try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
            let newer = try makeSignedBundle(in: source, build: "4")
            let subject = try installer(installURL: directory.appendingPathComponent("SkipperDesk.app"),
                                        workRoot: directory.appendingPathComponent("support/Updates"))
            func announced(_ build: String, _ version: String) -> AppRelease {
                AppRelease(version: version, build: build, minimumOS: "13.0", url: "https://example.com/a.dmg",
                           sha256: String(repeating: "0", count: 64), size: 1)
            }
            for (build, version) in [("5", "9.9.9"), ("4.1", "9.9.9"), ("4", "9.9.8"), ("4", "9.9.9.0")] {
                try expectRefusal({ if case .announcedMismatch = $0 { return true }; return false }) {
                    _ = try subject.stage(appAt: newer, announced: announced(build, version))
                }
            }
            for build in ["4", "4.0", "04", "4.0.0"] {
                let staged = try subject.stage(appAt: newer, announced: announced(build, "9.9.9"))
                subject.discard(staged)
            }
        }
    },

    TestCase("a staged file with a second hard link is refused and a held write handle cannot reach the install") {
        try withTemporaryDirectory { directory in
            let applications = directory.appendingPathComponent("Applications", isDirectory: true)
            try FileManager.default.createDirectory(at: applications, withIntermediateDirectories: true)
            let source = directory.appendingPathComponent("source", isDirectory: true)
            try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
            let target = try makeSignedBundle(in: applications, build: "3")
            let newer = try makeSignedBundle(in: source, build: "4")
            let subject = try installer(installURL: target, workRoot: directory.appendingPathComponent("support/Updates"))

            let linked = try subject.stage(appAt: newer)
            let outside = directory.appendingPathComponent("held-link")
            try FileManager.default.linkItem(at: linked.appURL.appendingPathComponent("Contents/Info.plist"), to: outside)
            try expectRefusal({ if case .sharedStagingFile = $0 { return true }; return false }) {
                try subject.install(linked)
            }
            try expectEqual(UpdateVerifier.installedBuild(at: target), try build("3"))

            let staged = try subject.stage(appAt: newer)
            let executable = staged.appURL.appendingPathComponent("Contents/MacOS/SkipperDesk").path
            let handle = open(executable, O_WRONLY)
            try expect(handle >= 0)
            defer { close(handle) }
            try subject.install(staged)
            let written = Data("tampered".utf8).withUnsafeBytes { pwrite(handle, $0.baseAddress, $0.count, 0) }
            try expect(written > 0)
            try UpdateVerifier.verifySignature(ofAppAt: target, requirement: adHocRequirement)
            try expectEqual(UpdateVerifier.installedBuild(at: target), try build("4"))
        }
    },

    TestCase("a rejected install is rolled back only to a previous app that passes the publisher check") {
        try withTemporaryDirectory { directory in
            let workRoot = directory.appendingPathComponent("support/Updates", isDirectory: true)
            let applications = directory.appendingPathComponent("Applications", isDirectory: true)
            try FileManager.default.createDirectory(at: applications, withIntermediateDirectories: true)
            let source = directory.appendingPathComponent("source", isDirectory: true)
            try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
            let newer = try makeSignedBundle(in: source, build: "4")
            let breakInstalled: (URL) -> Void = {
                try? FileManager.default.removeItem(at: $0.appendingPathComponent("Contents/_CodeSignature"))
            }

            let signedTarget = try makeSignedBundle(in: applications, build: "3")
            let subject = try installer(installURL: signedTarget, workRoot: workRoot)
            subject.afterSwapForTesting = breakInstalled
            try expectRefusal({ if case .installedCopyRejected = $0 { return true }; return false }) {
                try subject.install(try subject.stage(appAt: newer))
            }
            try expectEqual(UpdateVerifier.installedBuild(at: signedTarget), try build("3"))
            try UpdateVerifier.verifySignature(ofAppAt: signedTarget, requirement: adHocRequirement)
            try expectEqual(try FileManager.default.contentsOfDirectory(atPath: applications.path), ["SkipperDesk.app"])
            try expectEqual(try FileManager.default.contentsOfDirectory(atPath: workRoot.path), [])

            try FileManager.default.removeItem(at: signedTarget)
            let unsignedTarget = try makeUnsignedBundle(in: applications, identifier: UpdateTrust.bundleIdentifier, build: "3")
            try expectRefusal({ if case .installIncomplete = $0 { return true }; return false }) {
                try subject.install(try subject.stage(appAt: newer))
            }
            try expect(FileManager.default.fileExists(atPath: unsignedTarget.path), "the install path was deleted")
            try expectEqual(UpdateVerifier.installedBuild(at: unsignedTarget), try build("4"))
            try expectEqual(try FileManager.default.contentsOfDirectory(atPath: applications.path), ["SkipperDesk.app"])
            let kept = try FileManager.default.contentsOfDirectory(atPath: workRoot.path)
            try expectEqual(kept.count, 1)
            let keptApp = workRoot.appendingPathComponent(kept[0]).appendingPathComponent("SkipperDesk.app")
            try expectEqual(UpdateVerifier.installedBuild(at: keptApp), try build("3"))
            try expectEqual(UpdateStatus.needsReinstall.sentence,
                            "SkipperDesk could not finish updating. Reinstall from skipperdesk.app.")
        }
    },
]
#else
import RCTestKit

let updateInstallerCases: [TestCase] = []
#endif
