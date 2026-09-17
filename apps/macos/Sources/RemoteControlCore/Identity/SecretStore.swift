import Foundation
import Security
import SkipperCore

public enum SecretAccount: String, CaseIterable {
    case accessCode = "access-code"
    case peerCodes = "peer-codes"
    case trustedControllers = "trusted-controllers"
    case guessCounters = "guess-counters"
}

public enum SecretStoreError: Error, LocalizedError {
    case keychainUnavailable(SecretAccount, OSStatus)
    case unreadable(SecretAccount)

    public var errorDescription: String? {
        switch self {
        case .keychainUnavailable(let account, let status):
            let detail = SecCopyErrorMessageString(status, nil) as String? ?? "OSStatus \(status)"
            return "The Keychain could not hold this Mac's \(account.rawValue) (\(detail))."
        case .unreadable(let account):
            return "This Mac's stored \(account.rawValue) could not be read."
        }
    }
}

public protocol SecretBlobStore {
    func load(_ account: SecretAccount) throws -> Data?
    func save(_ blob: Data, for account: SecretAccount) throws
    func remove(_ account: SecretAccount) throws
}

public struct SecretKeychain: SecretBlobStore {

    public static let service = DeviceKeyKeychain.service

    public init() {}

    private func query(_ account: SecretAccount) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: account.rawValue,
        ]
    }

    public func load(_ account: SecretAccount) throws -> Data? {
        var request = query(account)
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data else {
            throw SecretStoreError.keychainUnavailable(account, status)
        }
        return data
    }

    public func save(_ blob: Data, for account: SecretAccount) throws {
        let attributes: [String: Any] = [
            kSecValueData as String: blob,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        let update = SecItemUpdate(query(account) as CFDictionary, attributes as CFDictionary)
        if update == errSecSuccess { return }
        guard update == errSecItemNotFound else {
            throw SecretStoreError.keychainUnavailable(account, update)
        }

        var insert = query(account)
        insert.merge(attributes) { _, new in new }
        let status = SecItemAdd(insert as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw SecretStoreError.keychainUnavailable(account, status)
        }
    }

    public func remove(_ account: SecretAccount) throws {
        let status = SecItemDelete(query(account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw SecretStoreError.keychainUnavailable(account, status)
        }
    }
}

public struct SecretFileStore: SecretBlobStore {

    private let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    public func fileURL(for account: SecretAccount) -> URL {
        directory.appendingPathComponent("\(account.rawValue).json")
    }

    public func load(_ account: SecretAccount) throws -> Data? {
        try SecureFile.read(fileURL(for: account))?.data
    }

    public func save(_ blob: Data, for account: SecretAccount) throws {
        _ = try SecureFile.ensureDirectory(directory)
        try SecureFile.writeAtomically(blob, to: fileURL(for: account))
    }

    public func remove(_ account: SecretAccount) throws {
        _ = try SecureFile.remove(fileURL(for: account))
    }
}

public final class InMemorySecretStore: SecretBlobStore {

    private var blobs: [SecretAccount: Data] = [:]
    public var isSealed = false

    public init() {}

    public func load(_ account: SecretAccount) throws -> Data? {
        if isSealed { throw SecretStoreError.keychainUnavailable(account, errSecNotAvailable) }
        return blobs[account]
    }

    public func save(_ blob: Data, for account: SecretAccount) throws {
        if isSealed { throw SecretStoreError.keychainUnavailable(account, errSecNotAvailable) }
        blobs[account] = blob
    }

    public func remove(_ account: SecretAccount) throws {
        if isSealed { throw SecretStoreError.keychainUnavailable(account, errSecNotAvailable) }
        blobs[account] = nil
    }
}

public struct TrustedController: Codable, Equatable {
    public var label: String
    public var firstSeen: Date
    public var lastSeen: Date

    public init(label: String, firstSeen: Date, lastSeen: Date) {
        self.label = label
        self.firstSeen = firstSeen
        self.lastSeen = lastSeen
    }
}

public struct SecretStore {

    private let blobs: SecretBlobStore

    public init(blobs: SecretBlobStore) {
        self.blobs = blobs
    }

    public static func forThisMac(fileStore: IdentityFileStore = IdentityFileStore()) -> SecretStore {
        if IdentityStore.usesDevFileIdentity(fileStore: fileStore) {
            return SecretStore(blobs: SecretFileStore(directory: fileStore.directory))
        }
        return SecretStore(blobs: SecretKeychain())
    }

    // MARK: This Mac's own access code

    public func accessCode() throws -> String? {
        guard let text: String = try read(.accessCode) else { return nil }
        return AccessCode.canonicalize(text)
    }

    public func saveAccessCode(_ code: String) throws {
        guard let canonical = AccessCode.canonicalize(code) else { return }
        try write(canonical, to: .accessCode)
    }

    // MARK: Codes remembered for other Macs (controller side)

    public func peerCode(forHost deviceID: String) throws -> String? {
        guard let code: String = try map(.peerCodes)[deviceID] else { return nil }
        return AccessCode.canonicalize(code)
    }

    public func rememberPeerCode(_ code: String, forHost deviceID: String) throws {
        guard let canonical = AccessCode.canonicalize(code) else { return }
        var codes: [String: String] = try map(.peerCodes)
        codes[deviceID] = canonical
        try write(codes, to: .peerCodes)
    }

    public func forgetPeerCode(forHost deviceID: String) throws {
        var codes: [String: String] = try map(.peerCodes)
        guard codes.removeValue(forKey: deviceID) != nil else { return }
        try write(codes, to: .peerCodes)
    }

    // MARK: Controllers that have proved the code (host side)

    public func trustedControllers() throws -> [String: TrustedController] {
        try map(.trustedControllers)
    }

    public func recordTrustedController(pubkey: String, label: String, now: Date = Date()) throws {
        guard !pubkey.isEmpty else { return }
        var trusted: [String: TrustedController] = try map(.trustedControllers)
        let firstSeen = trusted[pubkey]?.firstSeen ?? now
        let keptLabel = label.isEmpty ? (trusted[pubkey]?.label ?? "") : label
        trusted[pubkey] = TrustedController(label: keptLabel, firstSeen: firstSeen, lastSeen: now)
        try write(trusted, to: .trustedControllers)
    }

    // MARK: The guess policy's counters (host side)

    public func guessCounter(forController pubkey: String) throws -> GuessCounter? {
        try map(.guessCounters)[pubkey]
    }

    public func saveGuessCounter(_ counter: GuessCounter, forController pubkey: String) throws {
        guard !pubkey.isEmpty else { return }
        var counters: [String: GuessCounter] = try map(.guessCounters)
        counters[pubkey] = counter
        try write(counters, to: .guessCounters)
    }

    public func remove(pubkey: String) throws {
        var trusted: [String: TrustedController] = try map(.trustedControllers)
        guard trusted.removeValue(forKey: pubkey) != nil else { return }
        try write(trusted, to: .trustedControllers)
    }

    // MARK: Revocation

    public func revokeControllers() throws {
        try blobs.remove(.trustedControllers)
        try blobs.remove(.guessCounters)
    }

    public func discardEverything() {
        for account in SecretAccount.allCases { try? blobs.remove(account) }
    }

    // MARK: Boundary

    private func map<Value: Codable>(_ account: SecretAccount) throws -> [String: Value] {
        try read(account) ?? [:]
    }

    private func read<Value: Decodable>(_ account: SecretAccount) throws -> Value? {
        guard let blob = try blobs.load(account) else { return nil }
        guard let value = try? Self.decoder.decode(Value.self, from: blob) else {
            throw SecretStoreError.unreadable(account)
        }
        return value
    }

    private func write<Value: Encodable>(_ value: Value, to account: SecretAccount) throws {
        try blobs.save(try Self.encoder.encode(value), for: account)
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}
