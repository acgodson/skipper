import Foundation
import Security

public enum LegacyKeychainDecision: Equatable {
    case nothing
    case dropLegacy
    case adopt
    case reject
}

public struct LegacyKeychainState: Equatable {
    public let present: Bool
    public let createdAt: Date?
    public let migratedCopyPresent: Bool

    public init(present: Bool, createdAt: Date? = nil, migratedCopyPresent: Bool = false) {
        self.present = present
        self.createdAt = createdAt
        self.migratedCopyPresent = migratedCopyPresent
    }
}

public enum LegacyKeychainMigration {

    public static let clockTolerance: TimeInterval = 5

    public static let deviceKeyAccounts: [String] = DeviceKeyAccount.allCases.map(\.rawValue)

    public static let accounts: [String] =
        deviceKeyAccounts + SecretAccount.allCases.map(\.rawValue) + [DeviceTokenStore.keychainAccount]

    public static let boundToAccessCode: Set<String> = [
        SecretAccount.trustedControllers.rawValue,
        SecretAccount.guessCounters.rawValue,
    ]

    public static let mustPostdateIdentity: Set<String> = [
        SecretAccount.accessCode.rawValue,
        SecretAccount.trustedControllers.rawValue,
        SecretAccount.guessCounters.rawValue,
        DeviceTokenStore.keychainAccount,
    ]

    public static func isSuspicious(account: String, createdAt: Date?, identityCreatedAt: Date) -> Bool {
        guard mustPostdateIdentity.contains(account) else { return false }
        guard let createdAt else { return true }
        return createdAt < identityCreatedAt.addingTimeInterval(-clockTolerance)
    }

    public static func decide(
        _ states: [String: LegacyKeychainState],
        identityCreatedAt: Date?
    ) -> [String: LegacyKeychainDecision] {
        var decisions: [String: LegacyKeychainDecision] = [:]
        for (account, state) in states {
            decisions[account] = decide(account: account, state: state, identityCreatedAt: identityCreatedAt)
        }
        if decisions[SecretAccount.accessCode.rawValue] == .reject {
            for account in boundToAccessCode where states[account]?.present == true {
                decisions[account] = .reject
            }
        }
        return decisions
    }

    private static func decide(
        account: String,
        state: LegacyKeychainState,
        identityCreatedAt: Date?
    ) -> LegacyKeychainDecision {
        guard state.present else { return .nothing }
        if state.migratedCopyPresent { return .dropLegacy }
        guard let identityCreatedAt else { return .reject }
        if isSuspicious(account: account, createdAt: state.createdAt, identityCreatedAt: identityCreatedAt) {
            return .reject
        }
        return .adopt
    }

    @discardableResult
    public static func run(
        identityCreatedAt: Date?,
        accessGroup: String? = KeychainAccessGroup.current
    ) -> [String: LegacyKeychainDecision] {
        guard accessGroup != nil else { return [:] }
        var states: [String: LegacyKeychainState] = [:]
        var blobs: [String: Data] = [:]
        for account in accounts {
            let legacy: (data: Data, createdAt: Date?)?
            let current: Data?
            do {
                legacy = try LegacyKeychainItem(account: account).read()
                current = try KeychainItem(account: account, accessGroup: accessGroup).load()
            } catch {
                RCLog.error("keychain: \(account) left in the login keychain: \(error.localizedDescription)")
                continue
            }
            guard let legacy else { continue }
            blobs[account] = legacy.data
            states[account] = LegacyKeychainState(
                present: true, createdAt: legacy.createdAt, migratedCopyPresent: current != nil)
        }
        let decisions = decide(states, identityCreatedAt: identityCreatedAt)
        for (account, decision) in decisions {
            apply(decision, account: account, blob: blobs[account], accessGroup: accessGroup)
        }
        return decisions
    }

    private static func apply(_ decision: LegacyKeychainDecision, account: String, blob: Data?, accessGroup: String?) {
        let legacy = LegacyKeychainItem(account: account)
        do {
            switch decision {
            case .nothing:
                return
            case .adopt:
                guard let blob else { return }
                let item = KeychainItem(account: account, accessGroup: accessGroup)
                try item.save(blob)
                guard try item.load() == blob else { throw KeychainError.readBackMismatch }
                try legacy.remove()
                RCLog.info("keychain: moved \(account) to the data-protection keychain")
            case .dropLegacy:
                try legacy.remove()
                RCLog.info("keychain: removed the already-migrated login-keychain copy of \(account)")
            case .reject:
                try legacy.remove()
                RCLog.error("keychain: \(account) in the login keychain predates this identity and was not adopted"
                    + (account == SecretAccount.accessCode.rawValue ? "; a new access code is generated" : ""))
            }
        } catch {
            RCLog.error("keychain: migrating \(account) failed: \(error.localizedDescription)")
        }
    }
}

struct LegacyKeychainItem {

    let account: String

    private var query: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: KeychainItem.service,
            kSecAttrAccount as String: account,
            kSecUseDataProtectionKeychain as String: false,
        ]
    }

    func read() throws -> (data: Data, createdAt: Date?)? {
        var request = query
        request[kSecReturnData as String] = true
        request[kSecReturnAttributes as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess,
              let attributes = item as? [String: Any],
              let data = attributes[kSecValueData as String] as? Data else {
            throw KeychainError.status(status)
        }
        return (data, attributes[kSecAttrCreationDate as String] as? Date)
    }

    func remove() throws {
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw KeychainError.status(status) }
    }
}
