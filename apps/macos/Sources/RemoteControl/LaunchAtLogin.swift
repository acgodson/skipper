import Foundation
import ServiceManagement

/// "Launch at Login" via `SMAppService.mainApp`.
///
/// This only works for a real, code-signed `.app` bundle. Run the raw SwiftPM
/// binary and registration fails; we surface that instead of pretending.
@MainActor
final class LaunchAtLogin: ObservableObject {

    @Published private(set) var isEnabled: Bool = false
    @Published private(set) var lastError: String?
    @Published private(set) var isAvailable: Bool = false

    init() {
        isAvailable = Bundle.main.bundleIdentifier != nil && Bundle.main.bundleURL.pathExtension == "app"
        refresh()
    }

    func refresh() {
        guard isAvailable else { isEnabled = false; return }
        isEnabled = SMAppService.mainApp.status == .enabled
    }

    func set(_ enabled: Bool) {
        guard isAvailable else {
            lastError = "Launch at Login needs the packaged RemoteControl.app. "
                + "Build it with scripts/build.sh and run it from there."
            return
        }
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
        refresh()
    }

    var statusDescription: String {
        guard isAvailable else { return "Unavailable outside the app bundle" }
        switch SMAppService.mainApp.status {
        case .enabled: return "Enabled"
        case .requiresApproval: return "Needs approval in System Settings \u{203A} General \u{203A} Login Items"
        case .notFound: return "Not registered"
        case .notRegistered: return "Not registered"
        @unknown default: return "Unknown"
        }
    }
}
