import Foundation
import Security

public enum KeychainError: Error, LocalizedError, Equatable {
    case unsigned
    case status(OSStatus)
    case readBackMismatch

    public var errorDescription: String? {
        switch self {
        case .unsigned:
            return "This build is not signed by SkipperDesk and cannot store keys."
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

// TODO: verify on a Developer-ID-signed build; data-protection Keychain writes need the keychain-access-groups entitlement.
public struct KeychainItem {

    public static let service = KeychainAccessGroup.appIdentifier

    public let account: String
    public let accessGroup: String?

    public init(account: String, accessGroup: String? = KeychainAccessGroup.current) {
        self.account = account
        self.accessGroup = accessGroup
    }

    public static func query(account: String, accessGroup: String?) throws -> [String: Any] {
        guard let accessGroup else { throw KeychainError.unsigned }
        return [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecUseDataProtectionKeychain as String: true,
            kSecAttrAccessGroup as String: accessGroup,
            kSecAttrSynchronizable as String: false,
        ]
    }

    public static func attributes(storing blob: Data) -> [String: Any] {
        [
            kSecValueData as String: blob,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
    }

    private func query() throws -> [String: Any] {
        try Self.query(account: account, accessGroup: accessGroup)
    }

    public func load() throws -> Data? {
        var request = try query()
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data else { throw KeychainError.status(status) }
        return data
    }

    public func save(_ blob: Data) throws {
        let match = try query()
        let attributes = Self.attributes(storing: blob)
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

    public let accessGroup: String?

    public init(accessGroup: String? = KeychainAccessGroup.current) {
        self.accessGroup = accessGroup
    }

    public func item(_ account: Account) -> KeychainItem {
        KeychainItem(account: account.rawValue, accessGroup: accessGroup)
    }

    public func load(_ account: Account) throws -> Data? { try item(account).load() }

    public func save(_ blob: Data, for account: Account) throws { try item(account).save(blob) }

    public func remove(_ account: Account) throws { try item(account).remove() }
}

extension KeychainBlobs: DeviceKeyBlobStore where Account == DeviceKeyAccount {}

extension KeychainBlobs: SecretBlobStore where Account == SecretAccount {}

extension KeychainItem: DeviceTokenBlobStore {}
