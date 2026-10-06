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
        case .best: return "The sharpest picture. Best on a fast connection."
        case .balanced: return "A clear picture that works on most connections. Recommended."
        case .lowBandwidth: return "For a slow connection. Text stays readable, movement looks softer."
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

@MainActor
public final class AppSettings: ObservableObject {

    public enum Key {
        public static let role = "rc.role"
        public static let legacyUnattendedAccess = "rc.unattendedAccess"
        public static let clipboardSync = "rc.clipboardSync"
        public static let qualityMode = "rc.qualityMode"
        public static let savedPeerLabel = "rc.savedPeer.label"
        public static let savedPeerDeviceID = "rc.savedPeer.deviceID"
        public static let rememberPeerCode = "rc.savedPeer.rememberCode"
        public static let installUpdatesAutomatically = "rc.installUpdatesAutomatically"
    }

    private let defaults: UserDefaults
    private let secrets: SecretStore

    @Published public var role: AppRole { didSet { defaults.set(role.rawValue, forKey: Key.role) } }
    @Published public var unattendedAccess: Bool {
        didSet { Self.store(unattendedAccess: unattendedAccess, in: secrets) }
    }
    @Published public var clipboardSync: Bool { didSet { defaults.set(clipboardSync, forKey: Key.clipboardSync) } }
    @Published public var qualityMode: QualityMode { didSet { defaults.set(qualityMode.rawValue, forKey: Key.qualityMode) } }
    @Published public var savedPeerLabel: String { didSet { defaults.set(savedPeerLabel, forKey: Key.savedPeerLabel) } }
    @Published public var savedPeerDeviceID: String { didSet { defaults.set(savedPeerDeviceID, forKey: Key.savedPeerDeviceID) } }
    @Published public var rememberPeerCode: Bool { didSet { defaults.set(rememberPeerCode, forKey: Key.rememberPeerCode) } }
    @Published public var installUpdatesAutomatically: Bool {
        didSet { defaults.set(installUpdatesAutomatically, forKey: Key.installUpdatesAutomatically) }
    }

    public init(defaults: UserDefaults? = nil, isExistingInstall: Bool = false, secrets: SecretStore? = nil) {
        let resolved: UserDefaults
        if let defaults {
            resolved = defaults
        } else if let suite = DevelopmentHooks.value(.settingsSuite),
                  let suiteDefaults = UserDefaults(suiteName: suite) {
            resolved = suiteDefaults
        } else {
            resolved = .standard
        }
        self.defaults = resolved
        let secrets = secrets ?? SecretStore.forThisMac()
        self.secrets = secrets
        resolved.register(defaults: [
            Key.role: AppRole.host.rawValue,
            Key.clipboardSync: true,
            Key.qualityMode: QualityMode.balanced.rawValue,
            Key.savedPeerLabel: "",
            Key.savedPeerDeviceID: "",
            Key.rememberPeerCode: false,
            Key.installUpdatesAutomatically: true,
        ])
        self.role = AppRole(rawValue: resolved.string(forKey: Key.role) ?? "") ?? .host
        self.unattendedAccess = Self.unattendedAccess(in: secrets, legacy: resolved,
                                                      isExistingInstall: isExistingInstall)
        self.clipboardSync = resolved.bool(forKey: Key.clipboardSync)
        self.qualityMode = QualityMode(rawValue: resolved.string(forKey: Key.qualityMode) ?? "") ?? .balanced
        self.savedPeerLabel = resolved.string(forKey: Key.savedPeerLabel) ?? ""
        self.savedPeerDeviceID = resolved.string(forKey: Key.savedPeerDeviceID) ?? ""
        self.rememberPeerCode = resolved.bool(forKey: Key.rememberPeerCode)
        self.installUpdatesAutomatically = resolved.bool(forKey: Key.installUpdatesAutomatically)
    }

    private static func unattendedAccess(in secrets: SecretStore, legacy: UserDefaults,
                                         isExistingInstall: Bool) -> Bool {
        do {
            if let stored = try secrets.hostSettings() { return stored.unattendedAccess }
        } catch {
            RCLog.error("settings: host settings unreadable, asking before each connection: \(error.localizedDescription)")
            return false
        }
        let migrated = legacy.object(forKey: Key.legacyUnattendedAccess) as? Bool ?? isExistingInstall
        guard store(unattendedAccess: migrated, in: secrets) else { return false }
        legacy.removeObject(forKey: Key.legacyUnattendedAccess)
        RCLog.info("settings: moved unattended access into secure storage")
        return migrated
    }

    @discardableResult
    private static func store(unattendedAccess: Bool, in secrets: SecretStore) -> Bool {
        do {
            try secrets.saveHostSettings(HostSettings(unattendedAccess: unattendedAccess))
            return true
        } catch {
            RCLog.error("settings: host settings could not be saved: \(error.localizedDescription)")
            return false
        }
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
