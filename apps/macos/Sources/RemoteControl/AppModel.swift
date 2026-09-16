import Foundation
import Combine
import SwiftUI
import RemoteControlCore

/// Single owner of app-wide state. Views observe this; nothing else holds the
/// identity or the identity-file handle.
@MainActor
final class AppModel: ObservableObject {

    @Published var settings: AppSettings
    @Published var permissions: PermissionsModel
    @Published var identity: IdentityStore?
    /// Fatal identity error (damaged or unreadable identity file). Shown instead
    /// of the UI, because carrying on with a half-initialised identity would mean
    /// showing a Device ID and access code that are not the real ones.
    @Published var identityError: String?
    /// True when "Reset Identity" is a sensible offer for `identityError`. A
    /// corrupt file is resettable; a disk I/O failure is not — resetting would
    /// not fix it and would throw the identity away for nothing.
    @Published var identityErrorIsResettable = false

    /// PHASE 3: the real signaling + WebRTC stack. `coordinator` is nil only when
    /// the identity file could not be opened, because there is nothing to
    /// authenticate with in that case.
    @Published var coordinator: SessionCoordinator?
    @Published var selfPresence = SelfPresence()

    /// PHASE 1.4: this Mac's link to a SkipperDesk account (protocol/API.md §1).
    /// Nil only when there is no identity, because the link is bound to the
    /// device key. Controllers never need it; only a host does (SCOPE §3.1).
    @Published var account: AccountLinker?

    @Published var sessionState: SessionState = .idle
    @Published var connectError: String?
    @Published var isConnecting = false
    /// Distinct from `sessionState`: the control plane can be down while the
    /// session is perfectly alive (PROTOCOL.md §4.3).
    @Published var signalingSummary = "Connecting to the signaling server\u{2026}"
    @Published var lastRoundTripMs: Int?

    /// Set only by the DEBUG-only preview control, never by a real session.
    @Published var previewSessionBanner = false

    // MARK: - Phase 5: keyboard capture

    /// PLAN.md §2.4 mechanism 1. While this is on AND this app is frontmost,
    /// an event tap swallows key events locally and forwards them to the host,
    /// so Cmd+Space opens the REMOTE Spotlight.
    @Published var captureKeyboard = false { didSet { applyKeyboardCapture() } }
    /// Specific, named reason capture is not working (almost always the
    /// Accessibility grant). Never a silent failure.
    @Published var keyboardCaptureProblem: String?
    /// True only when the tap is installed AND armed: what the UI badge shows.
    @Published var keyboardCaptureActive = false

    let keyboardCapture = KeyboardCaptureTap()
    private var appIsActive = true

    let launchAtLogin = LaunchAtLogin()
    /// Keeps an unattended host from idle-sleeping. A sleeping Mac stops
    /// heartbeating, goes offline, and cannot be reached by anything.
    private let stayAwake = StayAwake()
    private let fileStore = IdentityFileStore()
    private var observers: [Any] = []
    private var cancellables = Set<AnyCancellable>()

    /// The live presence of the saved peer, driven by `watch`/`presence` pushes.
    /// Falls back to a never-Online stub only when there is no identity at all.
    var presence: any PeerPresenceSource { coordinator?.presence ?? offlineStub }
    private let offlineStub = PreviewPresenceSource()

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
    }

    /// Hold a power assertion whenever this Mac is a reachable host.
    ///
    /// A sleeping Mac stops heartbeating, the server marks it offline after 40s,
    /// and NO reconnect logic can recover that — there is nothing running to
    /// reconnect. Leaving this to a System Settings toggle the user has to find
    /// is a design flaw in an unattended-access tool, not a documentation gap.
    ///
    /// Not held while merely controlling: the controlling Mac sleeping is the
    /// user's business; a host that sleeps silently disappears.
    private func applyStayAwake() {
        stayAwake.update(enabled: settings.role == .host && settings.unattendedAccess)
    }

    // MARK: - Keyboard capture

    private func configureKeyboardCapture() {
        keyboardCapture.onKey = { [weak self] down, keycode, modifiers in
            self?.coordinator?.sendKey(down: down, keycode: keycode, modifiers: modifiers)
        }
        keyboardCapture.onEscapeHatch = { [weak self] in
            // The one combo that is never forwarded, so nobody can trap
            // themselves with every shortcut going to the other Mac.
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

    /// Capture is armed only while the toggle is on, a session is showing, and
    /// this app is frontmost. Losing focus disarms it, so clicking away behaves
    /// completely normally.
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

    /// SwiftUI only observes the object a view actually declares. `@Published` on
    /// a *reference* type fires when the reference is replaced, NOT when that
    /// object's own `@Published` properties change. Every nested model here
    /// (`settings`, `permissions`, `identity`, `coordinator`, the presence
    /// source…) is its own `ObservableObject`, so without this forwarding the
    /// model updates correctly and the view simply never redraws: switching role
    /// would do nothing on screen, a refreshed access code would keep showing the
    /// old one, a revoked permission would not surface, and the online/offline
    /// dot would never move.
    ///
    /// Must be re-run whenever `identity` or `coordinator` is replaced.
    private func rewireObservation() {
        cancellables.removeAll()

        bind(settings)
        bind(permissions)
        bind(identity)
        bind(launchAtLogin)
        bind(selfPresence)
        bind(coordinator)
        bind(account)
        bindPresence(presence)

        // Switching role must rebuild the transport: the role is baked into
        // SignalingClient at init and decides which side offers SDP, so a
        // coordinator still registered as host cannot drive a controller session.
        // Hopped off the publisher callback so we never cancel this very
        // subscription from inside its own delivery.
        // The quality picker is a controller-side control: it is sent to the
        // host, which is the machine that actually encodes.
        settings.$qualityMode
            .dropFirst()
            .sink { [weak self] mode in
                Task { @MainActor in self?.coordinator?.setQuality(mode.wireMode) }
            }
            .store(in: &cancellables)

        // The Clipboard Sync setting is honoured live, not only at connect.
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

    /// `PeerPresenceSource` is intentionally not `ObservableObject` — an
    /// existential carrying that associated type is awkward to store — so the
    /// concrete conformances are bound individually.
    private func bindPresence(_ source: any PeerPresenceSource) {
        if let live = source as? SignalingPresenceSource {
            bind(live)
        } else if let stub = source as? PreviewPresenceSource {
            bind(stub)
        }
    }

    /// Tears down and rebuilds the signaling/WebRTC stack for the current role.
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

    /// Brings up the signaling client so the saved peer's online dot is live
    /// before the user presses anything, and so an incoming session can be
    /// accepted while this Mac is the host (PLAN.md §2.2).
    private func startTransport() {
        guard let identity else { return }
        let coordinator = SessionCoordinator(identity: identity, role: settings.role == .host ? .host : .controller)
        self.coordinator = coordinator
        coordinator.onEvent = { [weak self] event in self?.apply(event) }
        coordinator.onAccessCodeRequired = { [weak self] reason in
            // The ONLY path that puts the code prompt back on screen.
            self?.connectError = ConnectFailure(
                WireError.protocolError(code: reason, message: "the session ended", retryAfterSec: 0)
            ).localizedDescription
            self?.sessionState = .idle
        }
        coordinator.setQuality(settings.qualityMode.wireMode)
        coordinator.start()
        startAutoConnectIfRequested()
    }

    /// TEST HOOK, off unless `RC_AUTOCONNECT="<deviceId>:<accessCode>"` is set in
    /// the environment.
    ///
    /// It exists because the acceptance check for this phase is "run two real
    /// app instances and see the remote desktop", and pressing Connect needs a
    /// human hand or an Accessibility grant for the automation tool — neither of
    /// which a build script has. It changes nothing for a normal launch: no
    /// environment variable, no behaviour. It is also refused unless
    /// `RC_IDENTITY_DIR` is set, so it cannot fire against a real installed
    /// identity even if the variable were somehow inherited.
    private func startAutoConnectIfRequested() {
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
            connect(deviceID: parts[0], accessCode: parts[1], remember: false, label: "Auto-connected Mac")
        }
    }

    private func apply(_ event: CoordinatorEvent) {
        guard let coordinator else { return }
        switch event {
        case .signalingState(let state):
            switch state {
            case .authenticated(let deviceID):
                signalingSummary = "Signed in to the signaling server as \(DeviceID.formatted(deviceID))."
                selfPresence.update(reachable: true,
                    detail: "This Mac is reachable. Another Mac can connect with the Device ID and access code above.")
            case .connecting, .authenticating:
                signalingSummary = "Connecting to the signaling server\u{2026}"
                selfPresence.setUnknown(detail: "Contacting the signaling server\u{2026}")
            case .waitingToRetry(let delay):
                signalingSummary = String(format: "Signaling server unreachable. Retrying in %.1fs.", delay)
                selfPresence.update(reachable: false,
                    detail: "Cannot reach the signaling server, so no one can connect to this Mac right now. Retrying automatically.")
            case .stopped(let why):
                signalingSummary = why
                selfPresence.update(reachable: false, detail: why)
            case .idle:
                signalingSummary = "Not connected."
                selfPresence.setUnknown(detail: "Not connected.")
            }
        case .roundTrip(let seconds):
            lastRoundTripMs = Int((seconds * 1000).rounded())
        case .connectFailed(let failure):
            connectError = failure.localizedDescription
            isConnecting = false
        case .phase:
            sessionState = coordinator.state
            if case .connecting = coordinator.phase {} else { isConnecting = false }
        case .silentReconnect:
            // Deliberately silent: the user never learns the server restarted.
            connectError = nil
        default:
            break
        }
        sessionState = coordinator.state
    }

    /// Attempts to open the identity file. Never regenerates on failure — see
    /// `resetIdentity()` for the only path that discards an identity.
    private func loadIdentity() {
        do {
            // The sink is set by SessionCoordinator, which owns the signaling
            // client that propagates a refresh to the server.
            self.identity = try IdentityStore(fileStore: fileStore)
            self.identityError = nil
            self.identityErrorIsResettable = false
        } catch {
            self.identity = nil
            self.identityError = error.localizedDescription
            self.identityErrorIsResettable = (error as? IdentityFileError)?.isResettable ?? false
            // Contains no secret material: the access code and private key are
            // never part of these errors.
            NSLog("RCIdentity failure: %@", String(describing: error))
        }
    }

    /// Explicit, user-chosen destruction of this Mac's identity. Deletes the
    /// identity file and mints a brand-new Device ID, access code and keypair.
    /// The peer Mac's saved entry will stop working and has to be re-entered.
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
        // `identity` is a fresh object; the old subscription pointed at the
        // discarded one.
        rewireObservation()
    }

    // MARK: - Account

    /// Brings up the account link and subscribes to the URL scheme the browser
    /// answers on. The stored token is restored in the background; the UI shows
    /// "unlinked" until the server has confirmed otherwise.
    private func startAccount() {
        guard let identity else { return }
        let account = AccountLinker(identity: identity)
        self.account = account
        URLCallbackBus.shared.handler = { [weak self] url in
            self?.account?.handleCallback(url)
        }
        Task { await account.restore() }
        startAutoLinkIfRequested()
    }

    /// TEST HOOK, off unless `RC_AUTOLINK=1`, and refused unless
    /// `RC_IDENTITY_DIR` is set so it can never fire against a real install.
    ///
    /// It presses "Link this Mac" for a verification script. Everything after
    /// that is the real flow: the browser opens the sign-in page, the one-time
    /// code comes back over `skipperdesk://link`, and the token is exchanged
    /// against the real API — none of which a script can start without a hand
    /// on the mouse.
    private func startAutoLinkIfRequested() {
        let environment = ProcessInfo.processInfo.environment
        guard environment["RC_AUTOLINK"] == "1", environment["RC_IDENTITY_DIR"] != nil else { return }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            if case .unlinked = account?.state { account?.beginLink() }
        }
    }

    func linkAccount() { account?.beginLink() }

    func cancelAccountLink() { account?.cancelLink() }

    func unlinkAccount() {
        Task { await account?.unlink() }
    }

    func retryAccount() {
        Task { await account?.restore() }
    }

    // MARK: - Host

    var sessionActive: Bool { sessionState.isActive || previewSessionBanner }

    /// The controller shows the remote desktop instead of the connect form for
    /// the whole life of a session — including while it is reconnecting, when
    /// dropping back to the form would look like the session had died.
    var showsRemoteScreen: Bool {
        guard settings.role == .controller, identityError == nil else { return false }
        return sessionState.isActive || isReconnecting
    }

    /// True while the session is alive but the media path is re-establishing.
    /// The UI must show this as "Reconnecting…", never as "Disconnected".
    var isReconnecting: Bool {
        if case .reconnecting = coordinator?.phase { return true }
        return false
    }

    /// Either side may end the session locally (PLAN.md §2.3).
    func endSession() {
        // Capture must die with the session: leaving a tap installed that
        // swallows every keystroke with nowhere to send them would look exactly
        // like a frozen Mac.
        captureKeyboard = false
        coordinator?.disconnect(reason: Wire.ByeReason.userEnded)
        sessionState = .idle
        previewSessionBanner = false
    }

    func refreshAccessCode() {
        guard let identity else { return }
        Task {
            do {
                _ = try await identity.refreshAccessCode()
            } catch {
                // The new code is already stored locally; this is a propagation error.
                connectError = error.localizedDescription
            }
        }
    }

    // MARK: - Controller

    func rememberedPeerCode() -> String {
        ((try? fileStore.loadPeerAccessCode()) ?? nil) ?? ""
    }

    func storePeerCode(_ code: String) {
        try? fileStore.savePeerAccessCode(code)
    }

    func forgetPeerCode() {
        _ = try? fileStore.forgetPeerAccessCode()
    }

    func connect(deviceID: String, accessCode: String, remember: Bool, label: String) {
        connectError = nil
        isConnecting = true
        settings.savePeer(label: label, deviceID: deviceID)
        if remember {
            storePeerCode(accessCode)
            settings.rememberPeerCode = true
        } else {
            forgetPeerCode()
            settings.rememberPeerCode = false
        }
        if let peer = DeviceID.canonicalize(deviceID) {
            presence.watch(deviceID: peer)
        }
        Task {
            guard let coordinator else {
                connectError = ConnectFailure.notConnectedToServer.localizedDescription
                isConnecting = false
                return
            }
            do {
                try await coordinator.connect(deviceID: deviceID, accessCode: accessCode, remember: remember)
                sessionState = coordinator.state
            } catch {
                connectError = (error as? ConnectFailure)?.localizedDescription
                    ?? error.localizedDescription
                sessionState = .idle
                isConnecting = false
            }
        }
    }
}
