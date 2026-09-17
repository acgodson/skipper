import AppKit
import Foundation
import SkipperCore

public struct UpdateInstallContext: Equatable, Sendable {
    public let role: AppRole
    public let phase: SessionPhase?

    public init(role: AppRole, phase: SessionPhase?) {
        self.role = role
        self.phase = phase
    }

    public var sessionIsIdle: Bool {
        switch phase {
        case .none, .idle, .closed: return true
        case .connecting, .awaitingConsent, .live, .reconnecting: return false
        }
    }
}

public enum UpdatePolicy {

    public static let checkInterval: TimeInterval = 24 * 60 * 60
    public static let checkJitter: TimeInterval = 60 * 60
    public static let launchDelay: ClosedRange<TimeInterval> = 20...120
    public static let quietHours = 3..<5
    public static let quietHourPoll: TimeInterval = 10 * 60

    public static func nextCheckDelay(unit: Double) -> TimeInterval {
        checkInterval + (unit * 2 - 1) * checkJitter
    }

    public static func isUnattendedWindowOpen(_ context: UpdateInstallContext?) -> Bool {
        guard let context else { return false }
        return context.role == .host && context.sessionIsIdle
    }

    public static func mayRestartToUpdate(_ context: UpdateInstallContext?) -> Bool {
        context?.sessionIsIdle ?? false
    }

    public static func shouldInstallUnattended(
        at date: Date, calendar: Calendar = .current, installsAutomatically: Bool, context: UpdateInstallContext?
    ) -> Bool {
        installsAutomatically && isUnattendedWindowOpen(context)
            && quietHours.contains(calendar.component(.hour, from: date))
    }

    public static func shouldInstallOnQuit(installsAutomatically: Bool) -> Bool {
        installsAutomatically
    }
}

public enum UpdateStatus: Equatable {
    case disabledInDevelopment
    case idle
    case checking
    case upToDate
    case downloading(version: String)
    case ready(StagedUpdate)
    case unavailable

    public var sentence: String? {
        switch self {
        case .disabledInDevelopment: return UpdateAvailability.disabledSentence
        case .idle: return nil
        case .checking: return "Checking for updates\u{2026}"
        case .upToDate: return "SkipperDesk is up to date."
        case .downloading(let version): return "Downloading SkipperDesk \(version)\u{2026}"
        case .ready(let staged): return "SkipperDesk \(staged.version) is ready. Restart to update."
        case .unavailable: return "Could not check for updates. SkipperDesk will try again later."
        }
    }

    public var staged: StagedUpdate? {
        if case .ready(let staged) = self { return staged }
        return nil
    }

    var isBusy: Bool {
        switch self {
        case .checking, .downloading: return true
        default: return false
        }
    }
}

@MainActor
public final class UpdateChecker: ObservableObject {

    @Published public private(set) var status: UpdateStatus

    public var installContext: () -> UpdateInstallContext? = { nil }
    public var installsAutomatically: () -> Bool = { true }

    private let api: APIClient
    private let track: ReleaseTrack
    private let installer: UpdateInstaller?
    private var refusedBuilds = RefusedBuilds()
    private var periodic: Task<Void, Never>?
    private var quietHourTimer: Timer?
    private var terminateObserver: Any?

    public init(
        api: APIClient = APIClient(),
        track: ReleaseTrack = ReleaseTrack(),
        availability: UpdateAvailability = .current(),
        runningBuild: BuildNumber? = .running
    ) {
        self.api = api
        self.track = track
        if case .enabled(let requirement) = availability, let runningBuild {
            installer = UpdateInstaller(requirement: requirement, runningBuild: runningBuild)
            status = .idle
        } else {
            installer = nil
            status = .disabledInDevelopment
            RCLog.info("update: \(UpdateAvailability.disabledSentence) The running app has no Developer ID Team ID.")
        }
    }

    public var isEnabled: Bool { installer != nil }

    public func start() {
        guard isEnabled, periodic == nil else { return }
        periodic = Task { [weak self] in
            var delay = TimeInterval.random(in: UpdatePolicy.launchDelay)
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                guard !Task.isCancelled else { return }
                await self?.check()
                delay = UpdatePolicy.nextCheckDelay(unit: Double.random(in: 0...1))
            }
        }
        quietHourTimer = Timer.scheduledTimer(withTimeInterval: UpdatePolicy.quietHourPoll, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.installIfQuietHour() }
        }
        terminateObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.installOnQuit() }
        }
    }

    public func checkNow() {
        guard isEnabled else {
            RCLog.info("update: check requested; \(UpdateAvailability.disabledSentence)")
            return
        }
        Task { await check() }
    }

    public func restartToUpdate() {
        guard let installer, let staged = status.staged,
              UpdatePolicy.mayRestartToUpdate(installContext()) else { return }
        install(staged, with: installer, relaunch: true)
    }

    private func check() async {
        guard let installer, !status.isBusy, status.staged == nil else { return }
        status = .checking
        let release: AppRelease?
        do {
            release = try await api.latestRelease(track: track)
        } catch {
            RCLog.info("update: check failed: \(error.localizedDescription)")
            status = .unavailable
            return
        }
        let os = BuildNumber(ProcessInfo.processInfo.operatingSystemVersion)
        guard let release, UpdateTrust.isOffered(release, running: installer.buildFloor, os: os),
              !refusedBuilds.contains(release.build) else {
            status = .upToDate
            return
        }
        status = .downloading(version: release.version)
        do {
            let staged = try await installer.prepare(release)
            status = .ready(staged)
            RCLog.info("update: \(staged.version) (\(staged.build)) verified and staged")
            installIfQuietHour()
        } catch {
            refusedBuilds.insert(release.build)
            RCLog.error("update: discarded build \(release.build): \(error)")
            status = .upToDate
        }
    }

    private func installIfQuietHour() {
        guard let installer, let staged = status.staged,
              UpdatePolicy.shouldInstallUnattended(
                at: Date(), installsAutomatically: installsAutomatically(), context: installContext())
        else { return }
        install(staged, with: installer, relaunch: true)
    }

    private func installOnQuit() {
        guard let installer, let staged = status.staged,
              UpdatePolicy.shouldInstallOnQuit(installsAutomatically: installsAutomatically()) else { return }
        install(staged, with: installer, relaunch: false)
    }

    private func install(_ staged: StagedUpdate, with installer: UpdateInstaller, relaunch: Bool) {
        do {
            try installer.install(staged)
            status = .idle
            RCLog.info("update: installed \(staged.version)")
            if relaunch { installer.relaunch() }
        } catch {
            refusedBuilds.insert(staged.build)
            status = .upToDate
            RCLog.error("update: install of \(staged.version) abandoned: \(error)")
        }
    }
}

public struct RefusedBuilds: Equatable, Sendable {
    private var keys: Set<BuildNumber> = []

    public init() {}

    public mutating func insert(_ build: BuildNumber) {
        keys.insert(build)
    }

    public mutating func insert(_ raw: String) {
        guard let build = BuildNumber(raw) else { return }
        keys.insert(build)
    }

    public func contains(_ raw: String) -> Bool {
        guard let build = BuildNumber(raw) else { return true }
        return keys.contains(build)
    }
}
