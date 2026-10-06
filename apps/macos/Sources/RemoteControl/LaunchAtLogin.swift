import Foundation
import ServiceManagement

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
            lastError = "Launch at login needs the installed SkipperDesk app. "
                + "Move SkipperDesk to your Applications folder and open it from there."
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
        guard isAvailable else { return "Move SkipperDesk to your Applications folder to use this" }
        switch SMAppService.mainApp.status {
        case .enabled: return "Enabled"
        case .requiresApproval: return "Needs approval in System Settings \u{203A} General \u{203A} Login Items"
        case .notFound, .notRegistered: return "Off"
        @unknown default: return "Unknown"
        }
    }
}
