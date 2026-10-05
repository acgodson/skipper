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

public struct DeviceTokenStore {

    public static let keychainAccount = "device-token"

    private let blobs: DeviceTokenBlobStore

    public init(blobs: DeviceTokenBlobStore) {
        self.blobs = blobs
    }

    public static func forThisMac(fileStore: IdentityFileStore = IdentityFileStore()) -> DeviceTokenStore {
        if IdentityStore.usesDevFileIdentity(fileStore: fileStore) {
            return DeviceTokenStore(blobs: DeviceTokenFile(directory: fileStore.fileURL.deletingLastPathComponent()))
        }
        return DeviceTokenStore(blobs: KeychainItem(account: keychainAccount))
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
