import Foundation

public enum QualityMode: String, CaseIterable, Identifiable, Codable {
    case best
    case balanced
    case lowBandwidth

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .best: return "Best Quality"
        case .balanced: return "Balanced"
        case .lowBandwidth: return "Low Bandwidth"
        }
    }

    public var detail: String {
        switch self {
        case .best: return "Sharpest image, highest bitrate."
        case .balanced: return "Biased toward bandwidth efficiency. Recommended."
        case .lowBandwidth: return "Lowest bitrate; text stays readable, motion softens."
        }
    }
}

public enum AppRole: String, CaseIterable, Identifiable, Codable {
    case host
    case controller

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .host: return "This Mac (Host)"
        case .controller: return "Control Another Mac"
        }
    }
}

/// Non-secret preferences. Secrets live in the owner-only identity file
/// (see `IdentityFileStore`), never here.
@MainActor
public final class AppSettings: ObservableObject {

    public enum Key {
        public static let role = "rc.role"
        public static let unattendedAccess = "rc.unattendedAccess"
        public static let clipboardSync = "rc.clipboardSync"
        public static let qualityMode = "rc.qualityMode"
        public static let savedPeerLabel = "rc.savedPeer.label"
        public static let savedPeerDeviceID = "rc.savedPeer.deviceID"
        public static let rememberPeerCode = "rc.savedPeer.rememberCode"
    }

    private let defaults: UserDefaults

    @Published public var role: AppRole { didSet { defaults.set(role.rawValue, forKey: Key.role) } }
    @Published public var unattendedAccess: Bool { didSet { defaults.set(unattendedAccess, forKey: Key.unattendedAccess) } }
    @Published public var clipboardSync: Bool { didSet { defaults.set(clipboardSync, forKey: Key.clipboardSync) } }
    @Published public var qualityMode: QualityMode { didSet { defaults.set(qualityMode.rawValue, forKey: Key.qualityMode) } }
    @Published public var savedPeerLabel: String { didSet { defaults.set(savedPeerLabel, forKey: Key.savedPeerLabel) } }
    @Published public var savedPeerDeviceID: String { didSet { defaults.set(savedPeerDeviceID, forKey: Key.savedPeerDeviceID) } }
    @Published public var rememberPeerCode: Bool { didSet { defaults.set(rememberPeerCode, forKey: Key.rememberPeerCode) } }

    /// `RC_SETTINGS_SUITE`, when set, isolates preferences into a distinct
    /// UserDefaults suite instead of the shared bundle-ID domain. Same purpose
    /// as `RC_IDENTITY_DIR` for the identity file: it lets two copies of this
    /// app run on one Mac (for local testing) without silently sharing role,
    /// saved-peer and quality settings through `UserDefaults.standard`. Real
    /// installs on separate Macs never need this — separate machines already
    /// have separate preference domains.
    public init(defaults: UserDefaults? = nil) {
        let resolved: UserDefaults
        if let defaults {
            resolved = defaults
        } else if let suite = ProcessInfo.processInfo.environment["RC_SETTINGS_SUITE"],
                  let suiteDefaults = UserDefaults(suiteName: suite) {
            resolved = suiteDefaults
        } else {
            resolved = .standard
        }
        self.defaults = resolved
        // Defaults chosen per AGENT.md: unattended and clipboard sync on, quality
        // Balanced. Unattended access remains an explicit, visible local setting.
        resolved.register(defaults: [
            Key.role: AppRole.host.rawValue,
            Key.unattendedAccess: true,
            Key.clipboardSync: true,
            Key.qualityMode: QualityMode.balanced.rawValue,
            Key.savedPeerLabel: "",
            Key.savedPeerDeviceID: "",
            Key.rememberPeerCode: false,
        ])
        self.role = AppRole(rawValue: resolved.string(forKey: Key.role) ?? "") ?? .host
        self.unattendedAccess = resolved.bool(forKey: Key.unattendedAccess)
        self.clipboardSync = resolved.bool(forKey: Key.clipboardSync)
        self.qualityMode = QualityMode(rawValue: resolved.string(forKey: Key.qualityMode) ?? "") ?? .balanced
        self.savedPeerLabel = resolved.string(forKey: Key.savedPeerLabel) ?? ""
        self.savedPeerDeviceID = resolved.string(forKey: Key.savedPeerDeviceID) ?? ""
        self.rememberPeerCode = resolved.bool(forKey: Key.rememberPeerCode)
    }

    public var hasSavedPeer: Bool { DeviceID.canonicalize(savedPeerDeviceID) != nil }

    public func savePeer(label: String, deviceID: String) {
        savedPeerLabel = label.trimmingCharacters(in: .whitespacesAndNewlines)
        savedPeerDeviceID = DeviceID.canonicalize(deviceID) ?? ""
    }

    public func forgetPeer() {
        savedPeerLabel = ""
        savedPeerDeviceID = ""
        rememberPeerCode = false
    }
}
