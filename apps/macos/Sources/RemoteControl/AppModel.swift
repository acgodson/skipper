import Foundation
import Combine
import SwiftUI
import RemoteControlCore

@MainActor
final class AppModel: ObservableObject {

    @Published var settings: AppSettings
    @Published var permissions: PermissionsModel
    @Published var identity: IdentityStore?
    @Published var identityError: String?
    @Published var identityErrorIsResettable = false

    @Published var coordinator: SessionCoordinator?
    @Published var selfPresence = SelfPresence()

    @Published var account: AccountLinker?

    @Published var sessionState: SessionState = .idle
    @Published var connectError: String?
    @Published var isConnecting = false
    @Published var signalingReady = false
    @Published var lastRoundTripMs: Int?

    @Published var trustedControllers: [TrustedControllerEntry] = []

    // MARK: - Phase 5: keyboard capture

    @Published var captureKeyboard = false { didSet { applyKeyboardCapture() } }
    @Published var keyboardCaptureProblem: String?
    @Published var keyboardCaptureActive = false

    let keyboardCapture = KeyboardCaptureTap()
    private var appIsActive = true

    let launchAtLogin = LaunchAtLogin()
    let updates = UpdateChecker()
    private let stayAwake = StayAwake()
    private let fileStore = IdentityFileStore()
    private let browserOpener = AccountBrowserOpener()
    private var observers: [Any] = []
    private var cancellables = Set<AnyCancellable>()

    var presence: any PeerPresenceSource { coordinator?.presence ?? offlinePresence }
    private let offlinePresence = SignalingPresenceSource()

    init() {
        let settings = AppSettings()
        self.settings = settings
        self.permissions = PermissionsModel()
        loadIdentity()
        startAccount()
        startTransport()
        if let peer = DeviceID.canonicalize(settings.savedPeerDeviceID) {
            presence.watch(deviceID: peer)
        }
        rewireObservation()
        configureKeyboardCapture()
        applyStayAwake()
        startUpdates()
    }

    private func startUpdates() {
        updates.isSessionActive = { [weak self] in self?.sessionActive ?? false }
        updates.installsAutomatically = { [weak self] in self?.settings.installUpdatesAutomatically ?? false }
        updates.start()
    }

    func checkForUpdates() { updates.checkNow() }

    func restartToUpdate() { updates.restartToUpdate() }

    private func applyStayAwake() {
        stayAwake.update(enabled: settings.role == .host && settings.unattendedAccess)
    }

    // MARK: - Keyboard capture

    private func configureKeyboardCapture() {
        keyboardCapture.onKey = { [weak self] down, keycode, modifiers in
            self?.coordinator?.sendKey(down: down, keycode: keycode, modifiers: modifiers)
        }
        keyboardCapture.onEscapeHatch = { [weak self] in
            self?.captureKeyboard = false
        }
        keyboardCapture.onProblem = { [weak self] message in
            self?.keyboardCaptureProblem = message
        }
        for name in [NSApplication.didBecomeActiveNotification, NSApplication.didResignActiveNotification] {
            let observer = NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                MainActor.assumeIsolated {
                    self?.appIsActive = (note.name == NSApplication.didBecomeActiveNotification)
                    self?.applyKeyboardCapture()
                }
            }
            observers.append(observer)
        }
    }

    private func applyKeyboardCapture() {
        let wanted = captureKeyboard && showsRemoteScreen
        if wanted && !keyboardCapture.isInstalled {
            if keyboardCapture.install() {
                keyboardCaptureProblem = nil
            } else {
                captureKeyboard = false
                keyboardCaptureActive = false
                return
            }
        }
        keyboardCapture.isCapturing = wanted && appIsActive
        keyboardCaptureActive = keyboardCapture.isCapturing
        if !wanted { keyboardCapture.uninstall() }
    }

    private func rewireObservation() {
        cancellables.removeAll()

        bind(settings)
        bind(permissions)
        bind(identity)
        bind(launchAtLogin)
        bind(updates)
        bind(selfPresence)
        bind(coordinator)
        bind(account)
        bindPresence(presence)

        settings.$qualityMode
            .dropFirst()
            .sink { [weak self] mode in
                Task { @MainActor in self?.coordinator?.setQuality(mode.wireMode) }
            }
            .store(in: &cancellables)

        coordinator?.clipboardSyncEnabled = settings.clipboardSync
        settings.$clipboardSync
            .sink { [weak self] enabled in
                Task { @MainActor in self?.coordinator?.clipboardSyncEnabled = enabled }
            }
            .store(in: &cancellables)

        settings.$role
            .dropFirst()
            .sink { [weak self] _ in
                Task { @MainActor in
                    self?.restartTransport()
                    self?.applyStayAwake()
                }
            }
            .store(in: &cancellables)

        settings.$unattendedAccess
            .dropFirst()
            .sink { [weak self] _ in
                Task { @MainActor in self?.applyStayAwake() }
            }
            .store(in: &cancellables)
    }

    private func bind<T: ObservableObject>(_ object: T?)
    where T.ObjectWillChangePublisher == ObservableObjectPublisher {
        object?.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
    }

    private func bindPresence(_ source: any PeerPresenceSource) {
        if let live = source as? SignalingPresenceSource { bind(live) }
    }

    private func restartTransport() {
        coordinator?.stop()
        coordinator = nil
        sessionState = .idle
        isConnecting = false
        connectError = nil
        lastRoundTripMs = nil
        startTransport()
        if let peer = DeviceID.canonicalize(settings.savedPeerDeviceID) {
            presence.watch(deviceID: peer)
        }
        rewireObservation()
    }

    private func startTransport() {
        guard let identity else { return }
        let coordinator = SessionCoordinator(identity: identity, role: settings.role == .host ? .host : .controller)
        self.coordinator = coordinator
        coordinator.onEvent = { [weak self] event in self?.apply(event) }
        coordinator.onAccessCodeRequired = { [weak self] reason in
            self?.connectError = EntitlementPresentation.sentence(for: ConnectFailure(
                WireError.protocolError(code: reason, message: "the session ended", retryAfterSec: 0)
            ))
            self?.sessionState = .idle
        }
        coordinator.setQuality(settings.qualityMode.wireMode)
        coordinator.start()
        startAutoConnectIfRequested()
    }

    private func startAutoConnectIfRequested() {
        #if DEBUG
        let environment = ProcessInfo.processInfo.environment
        guard let spec = environment["RC_AUTOCONNECT"],
              environment["RC_IDENTITY_DIR"] != nil,
              settings.role == .controller else { return }
        let parts = spec.split(separator: ":", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return }
        Task { @MainActor in
            for _ in 0..<120 {
                if coordinator?.signalingState.isAuthenticated == true { break }
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
            connect(deviceID: parts[0], accessCode: parts[1], remember: false, label: "")
        }
        #endif
    }

    private func apply(_ event: CoordinatorEvent) {
        guard let coordinator else { return }
        switch event {
        case .signalingState(let state):
            switch state {
            case .authenticated:
                signalingReady = true
                selfPresence.update(reachable: true,
                    detail: "This Mac is reachable. Another Mac can connect with the Device ID and access code above.")
            case .connecting, .authenticating:
                signalingReady = false
                selfPresence.setUnknown(detail: "Connecting to SkipperDesk\u{2026}")
            case .waitingToRetry:
                signalingReady = false
                selfPresence.update(reachable: false,
                    detail: "Cannot reach SkipperDesk, so no one can connect to this Mac right now. Retrying automatically.")
            case .stopped(let why):
                signalingReady = false
                selfPresence.update(reachable: false, detail: why)
            case .idle:
                signalingReady = false
                selfPresence.setUnknown(detail: "Not connected.")
            }
        case .roundTrip(let seconds):
            lastRoundTripMs = Int((seconds * 1000).rounded())
        case .connectFailed(let failure):
            connectError = EntitlementPresentation.sentence(for: failure)
            isConnecting = false
        case .phase:
            sessionState = coordinator.state
            if case .connecting = coordinator.phase {} else { isConnecting = false }
        case .silentReconnect:
            connectError = nil
        default:
            break
        }
        sessionState = coordinator.state
    }

    private func loadIdentity() {
        do {
            self.identity = try IdentityStore(fileStore: fileStore)
            self.identityError = nil
            self.identityErrorIsResettable = false
        } catch {
            self.identity = nil
            self.identityError = error.localizedDescription
            self.identityErrorIsResettable = (error as? IdentityFileError)?.isResettable ?? false
            NSLog("RCIdentity failure: %@", String(describing: error))
        }
    }

    func resetIdentity() {
        do {
            try IdentityStore.resetIdentity(fileStore: fileStore)
        } catch {
            identityError = error.localizedDescription
            identityErrorIsResettable = false
            return
        }
        loadIdentity()
        startAccount()
        rewireObservation()
    }

    // MARK: - Account

    private func startAccount() {
        guard let identity else { return }
        let opener = browserOpener
        let account = AccountLinker(identity: identity, openInBrowser: { opener.open($0) })
        self.account = account
        URLCallbackBus.shared.handler = { [weak self] url in
            self?.account?.handleCallback(url)
        }
        Task { await account.restore() }
        startAutoLinkIfRequested()
    }

    private func startAutoLinkIfRequested() {
        let environment = ProcessInfo.processInfo.environment
        guard environment["RC_AUTOLINK"] == "1", environment["RC_IDENTITY_DIR"] != nil else { return }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            if case .unlinked = account?.state { account?.beginLink() }
        }
    }

    func linkAccount() {
        account?.beginLink()
    }

    func cancelAccountLink() { account?.cancelLink() }

    func unlinkAccount() {
        Task { await account?.unlink() }
    }

    func retryAccount() {
        Task { await account?.restore() }
    }

    // MARK: - Host

    var sessionActive: Bool { sessionState.isActive }

    var showsRemoteScreen: Bool {
        guard settings.role == .controller, identityError == nil else { return false }
        return sessionState.isActive || isReconnecting
    }

    var isReconnecting: Bool {
        if case .reconnecting = coordinator?.phase { return true }
        return false
    }

    func endSession() {
        captureKeyboard = false
        coordinator?.disconnect(reason: Wire.ByeReason.userEnded)
        sessionState = .idle
    }

    func refreshAccessCode() {
        guard let identity else { return }
        Task {
            do {
                _ = try await identity.refreshAccessCode()
            } catch {
                connectError = error.localizedDescription
            }
            reloadTrustedControllers()
        }
    }

    // MARK: - Trusted controllers

    func reloadTrustedControllers() {
        guard let identity else {
            trustedControllers = []
            return
        }
        let stored = (try? identity.secrets.trustedControllers()) ?? [:]
        trustedControllers = stored
            .map { TrustedControllerEntry(pubkey: $0.key, controller: $0.value) }
            .sorted { $0.lastSeen > $1.lastSeen }
    }

    func revokeTrustedControllers() {
        try? identity?.secrets.revokeControllers()
        reloadTrustedControllers()
    }

    func removeTrustedController(pubkey: String) {
        try? identity?.secrets.remove(pubkey: pubkey)
        reloadTrustedControllers()
    }

    // MARK: - Controller

    func rememberedPeerCode(forHost deviceID: String) -> String {
        guard let canonical = DeviceID.canonicalize(deviceID) else { return "" }
        return ((try? identity?.secrets.peerCode(forHost: canonical)) ?? nil) ?? ""
    }

    func forgetPeerCode(forHost deviceID: String) {
        guard let canonical = DeviceID.canonicalize(deviceID) else { return }
        try? identity?.secrets.forgetPeerCode(forHost: canonical)
    }

    func connect(deviceID: String, accessCode: String, remember: Bool, label: String) {
        connectError = nil
        isConnecting = true
        settings.savePeer(label: label, deviceID: deviceID)
        settings.rememberPeerCode = remember
        if !remember { forgetPeerCode(forHost: deviceID) }
        if let peer = DeviceID.canonicalize(deviceID) {
            presence.watch(deviceID: peer)
        }
        Task {
            guard let coordinator else {
                connectError = EntitlementPresentation.sentence(for: .notConnectedToServer)
                isConnecting = false
                return
            }
            do {
                try await coordinator.connect(deviceID: deviceID, accessCode: accessCode, remember: remember)
                sessionState = coordinator.state
            } catch {
                connectError = (error as? ConnectFailure).map(EntitlementPresentation.sentence(for:))
                    ?? error.localizedDescription
                sessionState = .idle
                isConnecting = false
            }
        }
    }
}
