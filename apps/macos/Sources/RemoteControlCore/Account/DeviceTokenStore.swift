import Foundation
import Security

public struct DeviceToken: Codable, Equatable {

    public let token: String
    public let deviceId: String
    public let accountId: String
    public let accountEmail: String?
    public let expiresAt: Int64

    public init(token: String, deviceId: String, accountId: String,
                accountEmail: String? = nil, expiresAt: Int64) {
        self.token = token
        self.deviceId = deviceId
        self.accountId = accountId
        self.accountEmail = accountEmail
        self.expiresAt = expiresAt
    }

    public init(grant: DeviceTokenGrant) {
        self.init(
            token: grant.deviceToken,
            deviceId: grant.deviceId,
            accountId: grant.accountId,
            accountEmail: grant.accountEmail,
            expiresAt: grant.expiresAt
        )
    }

    public var expiry: Date { Date(timeIntervalSince1970: Double(expiresAt) / 1000) }

    public var needsRefresh: Bool { expiry.timeIntervalSinceNow < 7 * 24 * 60 * 60 }
}

public enum DeviceTokenStoreError: Error, LocalizedError {
    case unreadable(String)

    public var errorDescription: String? {
        switch self {
        case .unreadable(let reason):
            return "This Mac's stored account token could not be read (\(reason))."
        }
    }
}

public protocol DeviceTokenBlobStore {
    func load() throws -> Data?
    func save(_ blob: Data) throws
    func remove() throws
}

public struct DeviceTokenFile: DeviceTokenBlobStore {

    public static let fileName = "device-token.json"

    private let url: URL

    public init(directory: URL, name: String = DeviceTokenFile.fileName) {
        self.url = directory.appendingPathComponent(name)
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

public final class InMemoryDeviceTokenStore: DeviceTokenBlobStore {

    private var blob: Data?
    public var isSealed = false

    public init() {}

    public func load() throws -> Data? {
        if isSealed { throw KeychainError.status(errSecNotAvailable) }
        return blob
    }

    public func save(_ blob: Data) throws {
        if isSealed { throw KeychainError.status(errSecNotAvailable) }
        self.blob = blob
    }

    public func remove() throws {
        if isSealed { throw KeychainError.status(errSecNotAvailable) }
        blob = nil
    }
}

/// One JSON value in whichever store holds this Mac's secrets.
public struct SecretValueStore<Value: Codable> {

    private let blobs: DeviceTokenBlobStore

    public init(blobs: DeviceTokenBlobStore) {
        self.blobs = blobs
    }

    public func load() throws -> Value? {
        guard let blob = try blobs.load() else { return nil }
        do {
            return try JSONDecoder().decode(Value.self, from: blob)
        } catch {
            throw DeviceTokenStoreError.unreadable("it is not in the expected format")
        }
    }

    public func save(_ value: Value) throws {
        try blobs.save(try JSONEncoder().encode(value))
    }

    public func remove() throws {
        try blobs.remove()
    }
}

public struct DeviceTokenStore {

    public static let keychainAccount = "device-token"

    private let values: SecretValueStore<DeviceToken>

    public init(blobs: DeviceTokenBlobStore) {
        self.values = SecretValueStore(blobs: blobs)
    }

    public static func forThisMac(fileStore: IdentityFileStore = IdentityFileStore()) -> DeviceTokenStore {
        DeviceTokenStore(blobs: blobStore(
            keychainAccount: keychainAccount, fileName: DeviceTokenFile.fileName, fileStore: fileStore))
    }

    public func load() throws -> DeviceToken? {
        try values.load()
    }

    public func save(_ token: DeviceToken) throws {
        try values.save(token)
    }

    public func remove() throws {
        try values.remove()
    }
}

/// A sign-out the server has not confirmed. Until it does, this Mac is still
/// linked and entitled server-side and its token still works, so the marker
/// keeps what the retry needs (API.md §3.6).
public struct PendingUnlink: Codable, Equatable {

    public let deviceId: String
    public let token: String

    public init(deviceId: String, token: String) {
        self.deviceId = deviceId
        self.token = token
    }
}

public struct PendingUnlinkStore {

    public static let keychainAccount = "pending-unlink"
    public static let fileName = "pending-unlink.json"

    private let values: SecretValueStore<PendingUnlink>

    public init(blobs: DeviceTokenBlobStore) {
        self.values = SecretValueStore(blobs: blobs)
    }

    public static func forThisMac(fileStore: IdentityFileStore = IdentityFileStore()) -> PendingUnlinkStore {
        PendingUnlinkStore(blobs: blobStore(
            keychainAccount: keychainAccount, fileName: fileName, fileStore: fileStore))
    }

    public func load() throws -> PendingUnlink? {
        try values.load()
    }

    public func save(_ pending: PendingUnlink) throws {
        try values.save(pending)
    }

    public func remove() throws {
        try values.remove()
    }
}

func blobStore(keychainAccount: String, fileName: String, fileStore: IdentityFileStore) -> DeviceTokenBlobStore {
    if IdentityStore.usesDevFileIdentity(fileStore: fileStore) {
        return DeviceTokenFile(directory: fileStore.fileURL.deletingLastPathComponent(), name: fileName)
    }
    return KeychainItem(account: keychainAccount)
}
