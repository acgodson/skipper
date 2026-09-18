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

    /// The suspicion rules exist because anything can write the login keychain. An item
    /// coming the other way was written under a kernel-enforced app identity, so it is
    /// adopted on sight.
    public static func decide(
        _ states: [String: LegacyKeychainState],
        identityCreatedAt: Date?,
        source: SecretStorageMode = .login
    ) -> [String: LegacyKeychainDecision] {
        var decisions: [String: LegacyKeychainDecision] = [:]
        for (account, state) in states {
            decisions[account] = decide(
                account: account,
                state: state,
                identityCreatedAt: source == .login ? identityCreatedAt : nil,
                trusted: source == .dataProtection
            )
        }
        guard source == .login else { return decisions }
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
        identityCreatedAt: Date?,
        trusted: Bool
    ) -> LegacyKeychainDecision {
        guard state.present else { return .nothing }
        if state.migratedCopyPresent { return .dropLegacy }
        if trusted { return .adopt }
        guard let identityCreatedAt else { return .reject }
        if isSuspicious(account: account, createdAt: state.createdAt, identityCreatedAt: identityCreatedAt) {
            return .reject
        }
        return .adopt
    }

    /// Whichever keychain is not in use is read too, and anything found only there is
    /// moved across. Both directions need the data-protection keychain to be reachable:
    /// without the entitlement it is the unreadable side either way, so there is nothing
    /// to move and nothing to compare against.
    @discardableResult
    public static func run(
        identityCreatedAt: Date?,
        mode: SecretStorageMode = SecretStorage.mode,
        accessGroup: String? = SecretStorage.accessGroup,
        dataProtectionUsable: Bool = SecretStorage.dataProtectionUsable
    ) -> [String: LegacyKeychainDecision] {
        guard accessGroup != nil, dataProtectionUsable else { return [:] }
        let source = mode.other
        var states: [String: LegacyKeychainState] = [:]
        var blobs: [String: Data] = [:]
        for account in accounts {
            let item = KeychainItem(account: account, mode: mode, accessGroup: accessGroup)
            let found: (data: Data, createdAt: Date?)?
            let current: Data?
            do {
                found = try item.counterpart.read()
                current = try item.load()
            } catch {
                RCLog.error("keychain: \(account) left in the \(source.rawValue) keychain: "
                    + error.localizedDescription)
                continue
            }
            guard let found else { continue }
            blobs[account] = found.data
            states[account] = LegacyKeychainState(
                present: true, createdAt: found.createdAt, migratedCopyPresent: current != nil)
        }
        let decisions = decide(states, identityCreatedAt: identityCreatedAt, source: source)
        for (account, decision) in decisions {
            apply(decision, item: KeychainItem(account: account, mode: mode, accessGroup: accessGroup),
                  blob: blobs[account])
        }
        return decisions
    }

    private static func apply(_ decision: LegacyKeychainDecision, item: KeychainItem, blob: Data?) {
        let account = item.account
        let source = item.mode.other
        do {
            switch decision {
            case .nothing:
                return
            case .adopt:
                guard let blob else { return }
                try item.save(blob)
                guard try item.load() == blob else { throw KeychainError.readBackMismatch }
                try item.counterpart.remove()
                RCLog.info("keychain: moved \(account) to the \(item.mode.rawValue) keychain")
            case .dropLegacy:
                try item.counterpart.remove()
                RCLog.info("keychain: removed the already-migrated \(source.rawValue)-keychain copy of \(account)")
            case .reject:
                try item.counterpart.remove()
                RCLog.error("keychain: \(account) in the \(source.rawValue) keychain predates this identity "
                    + "and was not adopted"
                    + (account == SecretAccount.accessCode.rawValue ? "; a new access code is generated" : ""))
            }
        } catch {
            RCLog.error("keychain: migrating \(account) failed: \(error.localizedDescription)")
        }
    }
}
