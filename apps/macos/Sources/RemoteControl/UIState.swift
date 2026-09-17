import Foundation
import RemoteControlCore
import SkipperDesign

struct TrustedControllerEntry: Identifiable {
    let pubkey: String
    let label: String
    let firstSeen: Date
    let lastSeen: Date

    var id: String { pubkey }

    init(pubkey: String, controller: TrustedController) {
        self.pubkey = pubkey
        self.label = controller.label
        self.firstSeen = controller.firstSeen
        self.lastSeen = controller.lastSeen
    }

    var displayName: String {
        label.isEmpty ? "Unnamed Mac" : label
    }

    var shortKey: String {
        String(pubkey.prefix(10))
    }

    func lastSeenSentence(now: Date = Date()) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return "Last connected \(formatter.localizedString(for: lastSeen, relativeTo: now))"
    }
}

enum ConnectionStatus {
    case online
    case offline
    case connecting
    case reconnecting
    case sessionActive

    var label: String {
        switch self {
        case .online: return "Online"
        case .offline: return "Offline"
        case .connecting: return "Connecting\u{2026}"
        case .reconnecting: return "Reconnecting\u{2026}"
        case .sessionActive: return "Session active"
        }
    }

    var tone: SkipperTone {
        switch self {
        case .online: return .positive
        case .offline: return .neutral
        case .connecting: return .attention
        case .reconnecting: return .attention
        case .sessionActive: return .accent
        }
    }
}

extension PresenceState {
    var tone: SkipperTone {
        switch self {
        case .online: return .positive
        case .offline: return .neutral
        case .unknown: return .attention
        }
    }
}

extension AppModel {
    var connectionStatus: ConnectionStatus {
        if isReconnecting { return .reconnecting }
        if sessionActive { return .sessionActive }
        switch selfPresence.state {
        case .online: return .online
        case .offline: return .offline
        case .unknown: return .connecting
        }
    }

    var missingPermissions: [PermissionKind] {
        permissions.missing
    }
}
