import Foundation
import Security

/// The device token of API.md §1.4, with the little the client is allowed to
/// know about it: which device and account it names, and when it expires.
/// The token itself is opaque and is never logged or displayed.
public struct DeviceToken: Codable, Equatable {

    public let token: String
    public let deviceId: String
    public let accountId: String
    /// Unix milliseconds, as everything absolute on this surface is.
    public let expiresAt: Int64

    public init(token: String, deviceId: String, accountId: String, expiresAt: Int64) {
        self.token = token
        self.deviceId = deviceId
        self.accountId = accountId
        self.expiresAt = expiresAt
    }

    public init(grant: DeviceTokenGrant) {
        self.init(
            token: grant.deviceToken,
            deviceId: grant.deviceId,
            accountId: grant.accountId,
            expiresAt: grant.expiresAt
        )
    }

    public var expiry: Date { Date(timeIntervalSince1970: Double(expiresAt) / 1000) }

    /// API.md §1.5: refresh once the remaining TTL drops below seven days.
    public var needsRefresh: Bool { expiry.timeIntervalSinceNow < 7 * 24 * 60 * 60 }
}

public enum DeviceTokenStoreError: Error, LocalizedError {
    case keychainUnavailable(OSStatus)
    case unreadable(String)

    public var errorDescription: String? {
        switch self {
        case .keychainUnavailable(let status):
            let detail = SecCopyErrorMessageString(status, nil) as String? ?? "OSStatus \(status)"
            return "The Keychain could not hold this Mac's account token (\(detail))."
        case .unreadable(let reason):
            return "This Mac's stored account token could not be read (\(reason))."
        }
    }
}

/// Persists the token blob. The Keychain in production, a file only under the
/// same dev conditions `IdentityStore` allows for the device key, memory in
/// tests.
public protocol DeviceTokenBlobStore {
    func load() throws -> Data?
    func save(_ blob: Data) throws
    func remove() throws
}

/// A generic-password item beside the device key: service
/// `app.skipperdesk.desktop`, account `device-token`,
/// `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` so an unattended host is
/// linked again after a reboot with nobody present, and so the token never
/// travels to another Mac in a backup or through iCloud.
public struct DeviceTokenKeychain: DeviceTokenBlobStore {

    public static let service = DeviceKeyKeychain.service
    public static let account = "device-token"

    public init() {}

    private var query: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: Self.account,
        ]
    }

    public func load() throws -> Data? {
        var request = query
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data else {
            throw DeviceTokenStoreError.keychainUnavailable(status)
        }
        return data
    }

    public func save(_ blob: Data) throws {
        let attributes: [String: Any] = [
            kSecValueData as String: blob,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        let update = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if update == errSecSuccess { return }
        guard update == errSecItemNotFound else {
            throw DeviceTokenStoreError.keychainUnavailable(update)
        }

        var insert = query
        insert.merge(attributes) { _, new in new }
        let status = SecItemAdd(insert as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw DeviceTokenStoreError.keychainUnavailable(status)
        }
    }

    public func remove() throws {
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw DeviceTokenStoreError.keychainUnavailable(status)
        }
    }
}

/// The dev-only backend, reachable under exactly the conditions that put the
/// device key in a file: `SKIPPER_DEV_FILE_IDENTITY=1` or an overridden
/// identity directory, because the Keychain holds one slot and the
/// multi-instance scripts run several identities on one Mac. Owner-only
/// permissions, beside `identity.json`. Never a release path.
public struct DeviceTokenFile: DeviceTokenBlobStore {

    public static let fileName = "device-token.json"

    private let url: URL

    public init(directory: URL) {
        self.url = directory.appendingPathComponent(Self.fileName)
    }

    public var fileURL: URL { url }

    public func load() throws -> Data? {
        try SecureFile.read(url)?.data
    }

    public func save(_ blob: Data) throws {
        _ = try SecureFile.ensureDirectory(url.deletingLastPathComponent())
        try SecureFile.writeAtomically(blob, to: url)
    }

    public func remove() throws {
        _ = try SecureFile.remove(url)
    }
}

/// Test double, and the only blob store the suite ever touches by default: the
/// real Keychain would prompt on an unsigned build and hang a headless run.
public final class InMemoryDeviceTokenStore: DeviceTokenBlobStore {

    private var blob: Data?
    public var isSealed = false

    public init() {}

    public func load() throws -> Data? {
        if isSealed { throw DeviceTokenStoreError.keychainUnavailable(errSecNotAvailable) }
        return blob
    }

    public func save(_ blob: Data) throws {
        if isSealed { throw DeviceTokenStoreError.keychainUnavailable(errSecNotAvailable) }
        self.blob = blob
    }

    public func remove() throws {
        if isSealed { throw DeviceTokenStoreError.keychainUnavailable(errSecNotAvailable) }
        blob = nil
    }
}

/// Reads and writes the token through whichever blob store this build may use.
public struct DeviceTokenStore {

    private let blobs: DeviceTokenBlobStore

    public init(blobs: DeviceTokenBlobStore) {
        self.blobs = blobs
    }

    /// Keychain, or the identity-directory file under the dev conditions of
    /// `IdentityStore.usesDevFileIdentity`.
    public static func forThisMac(fileStore: IdentityFileStore = IdentityFileStore()) -> DeviceTokenStore {
        if IdentityStore.usesDevFileIdentity(fileStore: fileStore) {
            return DeviceTokenStore(blobs: DeviceTokenFile(directory: fileStore.fileURL.deletingLastPathComponent()))
        }
        return DeviceTokenStore(blobs: DeviceTokenKeychain())
    }

    public func load() throws -> DeviceToken? {
        guard let blob = try blobs.load() else { return nil }
        do {
            return try JSONDecoder().decode(DeviceToken.self, from: blob)
        } catch {
            throw DeviceTokenStoreError.unreadable("it is not in the expected format")
        }
    }

    public func save(_ token: DeviceToken) throws {
        try blobs.save(try JSONEncoder().encode(token))
    }

    public func remove() throws {
        try blobs.remove()
    }
}
