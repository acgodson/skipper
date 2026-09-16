import Foundation
import Security

/// Which Keychain slot a device key blob occupies.
///
/// Two accounts under one service, because the two blobs are not interchangeable:
/// the Secure Enclave one is an opaque key reference that only this Mac's chip
/// can use, the software one is a raw P-256 scalar. Storing them apart means a
/// fallback never has to guess what it just read.
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

/// Persists a device key blob. The Keychain in production, memory in tests.
public protocol DeviceKeyBlobStore {
    func load(_ account: DeviceKeyAccount) throws -> Data?
    func save(_ blob: Data, for account: DeviceKeyAccount) throws
    func remove(_ account: DeviceKeyAccount) throws
}

/// A generic-password item in the login Keychain.
///
/// `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`: an unattended host has to
/// come back after a reboot without anybody typing a password, and the item must
/// never travel to another Mac in a backup or through iCloud.
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

/// Test double. Keeps the suite off the real Keychain, which on an unsigned
/// build would prompt the user and hang a headless run.
public final class InMemoryDeviceKeyStore: DeviceKeyBlobStore {

    private var blobs: [DeviceKeyAccount: Data] = [:]
    /// Set to make every operation fail, standing in for a Keychain that refuses.
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
