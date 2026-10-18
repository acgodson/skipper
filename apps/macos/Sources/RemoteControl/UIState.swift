import Foundation
import RemoteControlCore
import SkipperCore
import SkipperDesign

struct TrustedControllerEntry: Identifiable {
    let pubkey: String
    let label: String
    let firstSeen: Date
    let lastSeen: Date

    /// The groups the consent prompt and the controller's own screen show,
    /// so an owner can compare them. The first bytes of the key cannot: for every
    /// P-256 key they are the same DER prefix.
    let fingerprint: String?

    var id: String { pubkey }

    init(pubkey: String, controller: TrustedController) {
        self.pubkey = pubkey
        self.label = controller.label
        self.firstSeen = controller.firstSeen
        self.lastSeen = controller.lastSeen
        self.fingerprint = try? DevicePublicKey.fingerprint(pubkey)
    }

    var displayName: String {
        label.isEmpty ? "Unnamed Mac" : label
    }

    var fingerprintLine: String? {
        fingerprint.map(DevicePublicKey.fingerprintLine)
    }

    var detailLines: [String] {
        [fingerprintLine].compactMap { $0 }
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

    var otherComputerLabel: String {
        let label = settings.savedPeerLabel
        if !label.isEmpty { return label }
        let id = settings.savedPeerDeviceID
        return id.isEmpty ? "the other computer" : DeviceID.formatted(id)
    }

    /// The ceiling this Mac's own account states (`API.md` §4.4). Greying the picker from
    /// it is courtesy: it is right in the shape this product is actually used in — both
    /// Macs on one account — and the host enforces the ceiling regardless.
    var qualityCeiling: QualityWireMode {
        QualityWireMode.ceiling(wire: account?.entitlement?.value.limits.maxQuality)
    }

    func qualityModeAvailable(_ mode: QualityMode) -> Bool {
        mode.wireMode.rank <= qualityCeiling.rank
    }

    var qualityCeilingNote: String? {
        EntitlementPresentation.qualityUnavailableNote(ceiling: qualityCeiling)
    }
}
