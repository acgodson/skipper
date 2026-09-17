import AppKit
import Foundation

public final class UpdateInstaller: @unchecked Sendable {

    private let runningAppURL: URL
    private let requirement: String
    private let runningBuild: BuildNumber
    private let fileManager = FileManager.default

    public init(requirement: String, runningBuild: BuildNumber, runningAppURL: URL = Bundle.main.bundleURL) {
        self.requirement = requirement
        self.runningBuild = runningBuild
        self.runningAppURL = runningAppURL
    }

    public func prepare(_ release: AppRelease) async throws -> StagedUpdate {
        let source = try UpdateTrust.requireSecureSource(release.url)
        guard release.size > 0 else { throw UpdateRefusal.malformedRelease("size") }
        _ = try UpdateTrust.requireNewer(candidate: release.build, running: runningBuild)

        let work = fileManager.temporaryDirectory
            .appendingPathComponent("SkipperDesk-update-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: work) }

        let image = work.appendingPathComponent("update.dmg")
        try await BoundedDownload(limit: release.size).fetch(source, to: image)
        try UpdateVerifier.verifyDownload(at: image, sha256: release.sha256, size: release.size)

        let staging = try stagingDirectory()
        let staged = staging.appendingPathComponent(UpdateTrust.appName, isDirectory: true)
        do {
            let mounted = try MountedDiskImage.attach(image, under: work.appendingPathComponent("mnt"))
            defer { mounted.detach() }
            try fileManager.copyItem(at: try mounted.bundledApp(), to: staged)
            let verified = try UpdateVerifier.verifyApp(at: staged, requirement: requirement, newerThan: runningBuild)
            return StagedUpdate(appURL: staged, version: verified.version, build: verified.build,
                                critical: release.critical)
        } catch {
            try? fileManager.removeItem(at: staging)
            throw error
        }
    }

    public func discard(_ staged: StagedUpdate) {
        try? fileManager.removeItem(at: staged.appURL.deletingLastPathComponent())
    }

    public func install(_ staged: StagedUpdate) throws {
        guard runningAppURL.pathExtension == "app" else { throw UpdateRefusal.notAnAppBundle }
        _ = try UpdateVerifier.verifyApp(at: staged.appURL, requirement: requirement, newerThan: runningBuild)
        do {
            _ = try fileManager.replaceItemAt(runningAppURL, withItemAt: staged.appURL)
        } catch {
            throw UpdateRefusal.installFailed(error.localizedDescription)
        }
        discard(staged)
    }

    @MainActor
    public func relaunch() {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        configuration.activates = false
        NSWorkspace.shared.openApplication(at: runningAppURL, configuration: configuration) { _, error in
            if let error { RCLog.error("update: relaunch failed: \(error.localizedDescription)") }
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
    }

    private func stagingDirectory() throws -> URL {
        try fileManager.url(
            for: .itemReplacementDirectory, in: .userDomainMask,
            appropriateFor: runningAppURL, create: true)
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
