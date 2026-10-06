import Foundation
import Security

/// Which keychain holds this Mac's secrets, decided once at startup.
public enum SecretStorageMode: String, Equatable, CaseIterable {

    case dataProtection
    case login

    public static let infoPlistKey = "SKIPPERSecretStorageMode"

    public static func decide(accessGroup: String?, dataProtectionUsable: Bool) -> SecretStorageMode {
        guard accessGroup != nil, dataProtectionUsable else { return .login }
        return .dataProtection
    }

    /// What the build says about itself, which `scripts/check-isolation.sh`
    /// checks against the profile and the entitlements at release time.
    public static func declared(in info: [String: Any]?) -> SecretStorageMode? {
        guard let raw = info?[infoPlistKey] as? String else { return nil }
        return SecretStorageMode(rawValue: raw.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    public static func declared(in bundle: Bundle = .main) -> SecretStorageMode? {
        declared(in: bundle.infoDictionary)
    }

    /// A build stamped for the data-protection keychain whose probe disagrees
    /// has either lost an entitlement or hit a transient failure. Writing to the
    /// login keychain instead would silently weaken every secret for that
    /// launch, so nothing is read or written at all.
    public static func refusesDowngrade(declared: SecretStorageMode?, decided: SecretStorageMode) -> Bool {
        declared == .dataProtection && decided != .dataProtection
    }

    public var other: SecretStorageMode {
        switch self {
        case .dataProtection: return .login
        case .login: return .dataProtection
        }
    }

    public var usesDataProtectionKeychain: Bool { self == .dataProtection }

    public var footerNote: String? {
        switch self {
        case .dataProtection:
            return nil
        case .login:
            return "Kept in this Mac's login keychain. Another app running as you could read it. "
                + "A signed SkipperDesk build keeps it out of reach."
        }
    }
}

public enum SecretStorage {

    public static let accessGroup: String? = KeychainAccessGroup.current

    public static let dataProtectionUsable: Bool = {
        guard let accessGroup else { return false }
        return probe(accessGroup: accessGroup)
    }()

    public static let declaredMode: SecretStorageMode? = SecretStorageMode.declared()

    public static let mode: SecretStorageMode = {
        let mode = SecretStorageMode.decide(accessGroup: accessGroup, dataProtectionUsable: dataProtectionUsable)
        RCLog.info("keychain: secrets use the \(mode.rawValue) keychain")
        return mode
    }()

    /// True when this launch would otherwise write a build's secrets to a
    /// weaker keychain than the build was made for; every item then fails
    /// closed instead.
    public static let downgradeRefused: Bool = {
        let refused = SecretStorageMode.refusesDowngrade(declared: declaredMode, decided: mode)
        if refused {
            RCLog.error("keychain: this build is stamped \(SecretStorageMode.dataProtection.rawValue) "
                + "but the probe could not reach that keychain; no secret is read or written this launch")
        }
        return refused
    }()

    /// The one answer that cannot be wrong: write, read back and delete a throwaway item
    /// in the data-protection keychain under the access group the app would really use.
    static func probe(accessGroup: String) -> Bool {
        let item = KeychainItem(
            account: "storage-probe-\(UUID().uuidString)",
            mode: .dataProtection,
            accessGroup: accessGroup
        )
        let written = Data([0x53])
        defer { try? item.remove() }
        do {
            try item.save(written)
            return try item.load() == written
        } catch {
            RCLog.info("keychain: the data-protection keychain is not available: \(error.localizedDescription)")
            return false
        }
    }
}
