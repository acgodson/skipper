import Foundation
import Security

public enum KeychainError: Error, LocalizedError, Equatable {
    case unsigned
    case status(OSStatus)
    case readBackMismatch

    public var errorDescription: String? {
        switch self {
        case .unsigned:
            return "This build cannot reach the data-protection Keychain and has no access group."
        case .status(let status):
            let detail = SecCopyErrorMessageString(status, nil) as String? ?? "OSStatus \(status)"
            return "The Keychain could not hold this Mac's secrets (\(detail))."
        case .readBackMismatch:
            return "The Keychain did not return what was just stored."
        }
    }
}

public enum KeychainAccessGroup {

    public static let appIdentifier = "app.skipperdesk.desktop"

    public static func named(teamID: String?) -> String? {
        guard let teamID = teamID?.trimmingCharacters(in: .whitespaces), !teamID.isEmpty else { return nil }
        return "\(teamID).\(appIdentifier)"
    }

    public static let current: String? = named(teamID: teamIdentifierOfRunningCode())

    public static func teamIdentifierOfRunningCode() -> String? {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return nil }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return nil }
        var info: CFDictionary?
        let flags = SecCSFlags(rawValue: kSecCSSigningInformation)
        guard SecCodeCopySigningInformation(staticCode, flags, &info) == errSecSuccess,
              let details = info as? [String: Any] else { return nil }
        return details[kSecCodeInfoTeamIdentifier as String] as? String
    }
}

public struct KeychainItem {

    public static let service = KeychainAccessGroup.appIdentifier

    public let account: String
    public let mode: SecretStorageMode
    public let accessGroup: String?

    public init(
        account: String,
        mode: SecretStorageMode = SecretStorage.mode,
        accessGroup: String? = SecretStorage.accessGroup
    ) {
        self.account = account
        self.mode = mode
        self.accessGroup = accessGroup
    }

    public var counterpart: KeychainItem {
        KeychainItem(account: account, mode: mode.other, accessGroup: accessGroup)
    }

    public static func query(account: String, mode: SecretStorageMode, accessGroup: String?) throws -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecUseDataProtectionKeychain as String: mode.usesDataProtectionKeychain,
        ]
        guard mode.usesDataProtectionKeychain else { return query }
        guard let accessGroup else { throw KeychainError.unsigned }
        query[kSecAttrAccessGroup as String] = accessGroup
        query[kSecAttrSynchronizable as String] = false
        return query
    }

    public static func attributes(storing blob: Data, mode: SecretStorageMode) -> [String: Any] {
        var attributes: [String: Any] = [kSecValueData as String: blob]
        if mode.usesDataProtectionKeychain {
            attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        }
        return attributes
    }

    private func query() throws -> [String: Any] {
        try Self.query(account: account, mode: mode, accessGroup: accessGroup)
    }

    public func load() throws -> Data? {
        try read()?.data
    }

    public func read() throws -> (data: Data, createdAt: Date?)? {
        var request = try query()
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

    public func save(_ blob: Data) throws {
        let match = try query()
        let attributes = Self.attributes(storing: blob, mode: mode)
        let update = SecItemUpdate(match as CFDictionary, attributes as CFDictionary)
        if update == errSecSuccess { return }
        guard update == errSecItemNotFound else { throw KeychainError.status(update) }
        let status = SecItemAdd(match.merging(attributes) { _, new in new } as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeychainError.status(status) }
    }

    public func remove() throws {
        let status = SecItemDelete(try query() as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw KeychainError.status(status) }
    }
}

public struct KeychainBlobs<Account: RawRepresentable> where Account.RawValue == String {

    public let mode: SecretStorageMode
    public let accessGroup: String?

    public init(mode: SecretStorageMode = SecretStorage.mode, accessGroup: String? = SecretStorage.accessGroup) {
        self.mode = mode
        self.accessGroup = accessGroup
    }

    public func item(_ account: Account) -> KeychainItem {
        KeychainItem(account: account.rawValue, mode: mode, accessGroup: accessGroup)
    }

    public func load(_ account: Account) throws -> Data? { try item(account).load() }

    public func save(_ blob: Data, for account: Account) throws { try item(account).save(blob) }

    public func remove(_ account: Account) throws { try item(account).remove() }
}

extension KeychainBlobs: DeviceKeyBlobStore where Account == DeviceKeyAccount {}

extension KeychainBlobs: SecretBlobStore where Account == SecretAccount {}

extension KeychainItem: DeviceTokenBlobStore {}
