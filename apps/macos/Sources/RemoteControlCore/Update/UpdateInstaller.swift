import AppKit
import Darwin
import Foundation

public final class UpdateInstaller: @unchecked Sendable {

    private let installURL: URL
    private let policy: UpdateSignaturePolicy
    private let runningBuild: BuildNumber
    private let workRoot: URL
    private let fileManager = FileManager.default

    public convenience init(requirement: String, runningBuild: BuildNumber, installURL: URL = Bundle.main.bundleURL) {
        self.init(policy: UpdateSignaturePolicy(requirement: requirement), runningBuild: runningBuild,
                  installURL: installURL, workRoot: UpdateInstaller.defaultWorkRoot)
    }

    init(policy: UpdateSignaturePolicy, runningBuild: BuildNumber, installURL: URL, workRoot: URL) {
        self.policy = policy
        self.runningBuild = runningBuild
        self.installURL = installURL
        self.workRoot = workRoot
    }

    public static var defaultWorkRoot: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return support
            .appendingPathComponent(UpdateTrust.bundleIdentifier, isDirectory: true)
            .appendingPathComponent("Updates", isDirectory: true)
    }

    public var installedBuild: BuildNumber? { UpdateVerifier.installedBuild(at: installURL) }

    public var buildFloor: BuildNumber { BuildNumber.floor(runningBuild, installedBuild) ?? runningBuild }

    public func prepare(_ release: AppRelease) async throws -> StagedUpdate {
        let floor = buildFloor
        let source = try UpdateTrust.requireSecureSource(release.url)
        try UpdateTrust.requireAcceptableSize(release.size)
        _ = try UpdateTrust.requireNewer(candidate: release.build, running: floor)

        let work = try PrivateDirectory.create(under: workRoot)
        do {
            let image = work.appendingPathComponent("update.dmg")
            try await BoundedDownload(limit: UpdateTrust.downloadLimit(announced: release.size)).fetch(source, to: image)
            try UpdateVerifier.verifyDownload(at: image, sha256: release.sha256, size: release.size)
            let mountRoot = work.appendingPathComponent("mnt", isDirectory: true)
            let mounted = try MountedDiskImage.attach(image, under: mountRoot)
            defer {
                mounted.detach()
                try? fileManager.removeItem(at: mountRoot)
                try? fileManager.removeItem(at: image)
            }
            return try stage(appAt: try mounted.bundledApp(), into: work, floor: floor, critical: release.critical)
        } catch {
            try? fileManager.removeItem(at: work)
            throw error
        }
    }

#if DEBUG || SKIPPER_TEST_HOOKS
    public static func forTesting(
        policy: UpdateSignaturePolicy, runningBuild: BuildNumber, installURL: URL, workRoot: URL
    ) -> UpdateInstaller {
        UpdateInstaller(policy: policy, runningBuild: runningBuild, installURL: installURL, workRoot: workRoot)
    }

    public func stage(appAt source: URL, critical: Bool = false) throws -> StagedUpdate {
        let work = try PrivateDirectory.create(under: workRoot)
        do {
            return try stage(appAt: source, into: work, floor: buildFloor, critical: critical)
        } catch {
            try? fileManager.removeItem(at: work)
            throw error
        }
    }
#endif

    private func stage(appAt source: URL, into work: URL, floor: BuildNumber, critical: Bool) throws -> StagedUpdate {
        let copy = work.appendingPathComponent(UpdateTrust.appName, isDirectory: true)
        try fileManager.copyItem(at: source, to: copy)
        let sealed = try UpdateVerifier.seal(appAt: copy, policy: policy, newerThan: floor)
        return StagedUpdate(sealed: sealed, critical: critical)
    }

    public func discard(_ staged: StagedUpdate) {
        try? fileManager.removeItem(at: staged.appURL.deletingLastPathComponent())
    }

    public func install(_ staged: StagedUpdate) throws {
        defer { discard(staged) }
        guard installURL.pathExtension == "app" else { throw UpdateRefusal.notAnAppBundle }
        let floor = buildFloor
        try UpdateVerifier.recheck(staged.sealed, policy: policy, newerThan: floor)

        let backupName = ".\(UpdateTrust.appName).previous-\(UUID().uuidString)"
        let backup = installURL.deletingLastPathComponent().appendingPathComponent(backupName, isDirectory: true)
        do {
            _ = try fileManager.replaceItemAt(
                installURL, withItemAt: staged.appURL,
                backupItemName: backupName, options: [.withoutDeletingBackupItem])
        } catch {
            throw UpdateRefusal.installFailed(error.localizedDescription)
        }

        do {
            let installed = try UpdateVerifier.seal(appAt: installURL, policy: policy, newerThan: floor)
            guard installed.build == staged.build else {
                throw UpdateRefusal.notNewer(candidate: installed.build.description, running: staged.build.description)
            }
        } catch {
            try rollBack(from: backup)
            throw UpdateRefusal.installedCopyRejected(String(describing: error))
        }
        try? fileManager.removeItem(at: backup)
    }

    private func rollBack(from backup: URL) throws {
        do {
            _ = try fileManager.replaceItemAt(installURL, withItemAt: backup)
        } catch {
            try? fileManager.removeItem(at: installURL)
            throw UpdateRefusal.installFailed("rollback failed: \(error.localizedDescription)")
        }
    }

    @MainActor
    public func relaunch() {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        configuration.activates = false
        NSWorkspace.shared.openApplication(at: installURL, configuration: configuration) { _, error in
            if let error { RCLog.error("update: relaunch failed: \(error.localizedDescription)") }
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
    }
}

enum PrivateDirectory {

    static func create(under root: URL) throws -> URL {
        try ensureOwned(root.deletingLastPathComponent(), requirePrivate: false)
        try ensureOwned(root, requirePrivate: true)
        let directory = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        guard mkdir(directory.path, 0o700) == 0 else { throw UpdateRefusal.unsafeWorkDirectory(directory.path) }
        try requireOwned(directory, requirePrivate: true)
        return directory
    }

    private static func ensureOwned(_ directory: URL, requirePrivate: Bool) throws {
        if mkdir(directory.path, 0o700) != 0, errno != EEXIST {
            throw UpdateRefusal.unsafeWorkDirectory(directory.path)
        }
        try requireOwned(directory, requirePrivate: requirePrivate)
    }

    private static func requireOwned(_ directory: URL, requirePrivate: Bool) throws {
        var info = stat()
        guard lstat(directory.path, &info) == 0,
              info.st_mode & S_IFMT == S_IFDIR,
              info.st_uid == getuid(),
              !requirePrivate || info.st_mode & 0o077 == 0
        else { throw UpdateRefusal.unsafeWorkDirectory(directory.path) }
    }
}

private final class BoundedDownload: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {

    private let limit: Int64
    private let lock = NSLock()
    private var destination: URL?
    private var continuation: CheckedContinuation<Void, Error>?
    private var outcome: Error?

    init(limit: Int64) {
        self.limit = limit
    }

    func fetch(_ source: URL, to destination: URL) async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 30 * 60
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        self.destination = destination
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            lock.withLock { self.continuation = continuation }
            session.downloadTask(with: source).resume()
        }
    }

    func urlSession(
        _ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64
    ) {
        if totalBytesWritten > limit || totalBytesExpectedToWrite > limit {
            lock.withLock { outcome = UpdateRefusal.tooLarge(expected: limit) }
            downloadTask.cancel()
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        let status = (downloadTask.response as? HTTPURLResponse)?.statusCode ?? 0
        do {
            guard (200..<300).contains(status) else {
                throw UpdateRefusal.imageUnusable("download answered HTTP \(status)")
            }
            guard let destination else { throw UpdateRefusal.imageUnusable("no destination") }
            let size = ((try? FileManager.default.attributesOfItem(atPath: location.path))?[.size] as? NSNumber)?.int64Value ?? .max
            guard size <= limit else { throw UpdateRefusal.tooLarge(expected: limit) }
            try FileManager.default.moveItem(at: location, to: destination)
        } catch {
            lock.withLock { if outcome == nil { outcome = error } }
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let result: Error? = lock.withLock { outcome ?? error }
        let pending = lock.withLock { () -> CheckedContinuation<Void, Error>? in
            defer { continuation = nil }
            return continuation
        }
        if let result {
            pending?.resume(throwing: result)
        } else {
            pending?.resume()
        }
    }

    func urlSession(
        _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void
    ) {
        guard let url = request.url, (try? UpdateTrust.requireSecureSource(url.absoluteString)) != nil else {
            lock.withLock { outcome = UpdateRefusal.insecureSource(request.url?.absoluteString ?? "") }
            completionHandler(nil)
            task.cancel()
            return
        }
        completionHandler(request)
    }
}
