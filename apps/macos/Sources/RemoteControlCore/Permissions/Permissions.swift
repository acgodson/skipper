import Foundation
import CoreGraphics
import ApplicationServices
#if canImport(AppKit)
import AppKit
#endif

public enum PermissionKind: String, CaseIterable, Identifiable {
    case screenRecording
    case accessibility

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .screenRecording: return "Screen Recording"
        case .accessibility: return "Accessibility"
        }
    }

    /// Named, specific consequence. Never a generic "permissions missing".
    public var consequenceWhenMissing: String {
        switch self {
        case .screenRecording:
            return "Without this, this Mac cannot share its screen. A controller can connect but will see nothing."
        case .accessibility:
            return "Without this, this Mac cannot accept remote mouse or keyboard input. You will see the screen but cannot control it."
        }
    }

    public var grantedSummary: String {
        switch self {
        case .screenRecording: return "This Mac can share its screen."
        case .accessibility: return "This Mac can accept remote mouse and keyboard input."
        }
    }

    /// Deep link straight to the exact System Settings pane.
    public var settingsURL: URL? {
        switch self {
        case .screenRecording:
            return URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")
        case .accessibility:
            return URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
        }
    }
}

/// Live view of the two macOS privacy permissions the app depends on.
///
/// Re-checked whenever the app becomes active, plus on a slow timer, so that
/// revoking a permission in System Settings while the app is open is noticed
/// rather than discovered at the worst moment mid-session.
@MainActor
public final class PermissionsModel: ObservableObject {

    @Published public private(set) var granted: [PermissionKind: Bool] = [:]
    @Published public private(set) var lastChecked: Date = .distantPast

    private var timer: Timer?
    private var observer: Any?

    public init(startMonitoring: Bool = true) {
        refresh()
        if startMonitoring { self.startMonitoring() }
    }

    deinit {
        timer?.invalidate()
        #if canImport(AppKit)
        if let observer { NotificationCenter.default.removeObserver(observer) }
        #endif
    }

    public func isGranted(_ kind: PermissionKind) -> Bool { granted[kind] ?? false }

    public var allGranted: Bool { PermissionKind.allCases.allSatisfy(isGranted) }

    public var missing: [PermissionKind] { PermissionKind.allCases.filter { !isGranted($0) } }

    /// Read-only status probes. Neither of these raises a system dialog.
    public func refresh() {
        granted = [
            .screenRecording: CGPreflightScreenCaptureAccess(),
            .accessibility: AXIsProcessTrusted(),
        ]
        lastChecked = Date()
    }

    public func startMonitoring() {
        #if canImport(AppKit)
        observer = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        #endif
        timer?.invalidate()
        let timer = Timer(timeInterval: 3.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    /// Asks macOS to show its own consent dialog. We never try to bypass it.
    public func request(_ kind: PermissionKind) {
        switch kind {
        case .screenRecording:
            _ = CGRequestScreenCaptureAccess()
        case .accessibility:
            let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
            _ = AXIsProcessTrustedWithOptions(options as CFDictionary)
        }
        refresh()
    }

    public func openSettings(for kind: PermissionKind) {
        #if canImport(AppKit)
        guard let url = kind.settingsURL else { return }
        NSWorkspace.shared.open(url)
        #endif
    }
}
