import Foundation
import Security

public enum DeviceKeyAccount: String {
    case secureEnclave = "device-key"
    case software = "device-key-software"
}

public enum DeviceKeyKeychainError: Error, LocalizedError {
    case unavailable(OSStatus)

    public var errorDescription: String? {
        switch self {
        case .unavailable(let status):
            let detail = SecCopyErrorMessageString(status, nil) as String? ?? "OSStatus \(status)"
            return "The Keychain could not store this Mac's device key (\(detail))."
        }
    }
}

public protocol DeviceKeyBlobStore {
    func load(_ account: DeviceKeyAccount) throws -> Data?
    func save(_ blob: Data, for account: DeviceKeyAccount) throws
    func remove(_ account: DeviceKeyAccount) throws
}

public struct DeviceKeyKeychain: DeviceKeyBlobStore {

    public static let service = "app.skipperdesk.desktop"

    public init() {}

    private func query(_ account: DeviceKeyAccount) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: account.rawValue,
        ]
    }

    public func load(_ account: DeviceKeyAccount) throws -> Data? {
        var request = query(account)
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data else {
            throw DeviceKeyKeychainError.unavailable(status)
        }
        return data
    }

    public func save(_ blob: Data, for account: DeviceKeyAccount) throws {
        let attributes: [String: Any] = [
            kSecValueData as String: blob,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        let update = SecItemUpdate(query(account) as CFDictionary, attributes as CFDictionary)
        if update == errSecSuccess { return }
        guard update == errSecItemNotFound else {
            throw DeviceKeyKeychainError.unavailable(update)
        }

        var insert = query(account)
        insert.merge(attributes) { _, new in new }
        let status = SecItemAdd(insert as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw DeviceKeyKeychainError.unavailable(status)
        }
    }

    public func remove(_ account: DeviceKeyAccount) throws {
        let status = SecItemDelete(query(account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw DeviceKeyKeychainError.unavailable(status)
        }
    }
}

public final class InMemoryDeviceKeyStore: DeviceKeyBlobStore {

    private var blobs: [DeviceKeyAccount: Data] = [:]
    public var isSealed = false

    public init() {}

    public func load(_ account: DeviceKeyAccount) throws -> Data? {
        if isSealed { throw DeviceKeyKeychainError.unavailable(errSecNotAvailable) }
        return blobs[account]
    }

    public func save(_ blob: Data, for account: DeviceKeyAccount) throws {
        if isSealed { throw DeviceKeyKeychainError.unavailable(errSecNotAvailable) }
        blobs[account] = blob
    }

    public func remove(_ account: DeviceKeyAccount) throws {
        if isSealed { throw DeviceKeyKeychainError.unavailable(errSecNotAvailable) }
        blobs[account] = nil
    }
}
