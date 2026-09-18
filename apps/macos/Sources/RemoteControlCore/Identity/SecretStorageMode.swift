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

    public static let mode: SecretStorageMode = {
        let mode = SecretStorageMode.decide(accessGroup: accessGroup, dataProtectionUsable: dataProtectionUsable)
        RCLog.info("keychain: secrets use the \(mode.rawValue) keychain")
        return mode
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
