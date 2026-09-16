import Foundation
import Security
import SkipperCore

/// The secrets this Mac holds that are not the device key, each in its own
/// Keychain slot under the same service.
///
/// They are kept apart because they have different lifetimes and different
/// owners: this Mac's own access code, the codes it has been told by other
/// Macs, the controllers that have proved a code to it, and how often each of
/// them has got it wrong.
public enum SecretAccount: String, CaseIterable {
    /// This Mac's access code, as a host. Plaintext, 12 Crockford symbols.
    case accessCode = "access-code"
    /// `[hostDeviceId: accessCode]` — codes remembered for other Macs.
    case peerCodes = "peer-codes"
    /// `[controllerPubkey: TrustedController]` — who has proved the code here.
    case trustedControllers = "trusted-controllers"
    /// `[controllerPubkey: GuessCounter]` — PROTOCOL.md §2.17's guess policy.
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

/// Persists one secret blob per account. The Keychain in production, a file
/// under the same dev conditions as the device key, memory in tests.
public protocol SecretBlobStore {
    func load(_ account: SecretAccount) throws -> Data?
    func save(_ blob: Data, for account: SecretAccount) throws
    func remove(_ account: SecretAccount) throws
}

/// Generic-password items beside the device key and the account token: service
/// `app.skipperdesk.desktop`, one account per `SecretAccount`,
/// `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` so an unattended host is
/// reachable again after a reboot with nobody present, and so no code ever
/// travels to another Mac in a backup or through iCloud.
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

/// The dev-only backend, reachable under exactly the conditions that put the
/// device key in a file: `SKIPPER_DEV_FILE_IDENTITY=1` or an overridden identity
/// directory, because the Keychain holds one slot per account and the
/// multi-instance scripts run several identities on one Mac. Owner-only
/// permissions, beside `identity.json`. Never a release path.
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

/// Test double, and the only backend the suite touches by default: the real
/// Keychain would prompt on an unsigned build and hang a headless run.
public final class InMemorySecretStore: SecretBlobStore {

    private var blobs: [SecretAccount: Data] = [:]
    /// Set to make every operation fail, standing in for a Keychain that refuses.
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

/// One controller that has completed the §2.17 exchange against this host.
///
/// PROTOCOL.md §4.5: this list does **not** gate the exchange — a controller
/// with the right code is allowed whether or not it is here. It exists so the
/// host can show who has connected, and so Refresh Code has something to revoke.
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

/// Reads and writes the four secrets through whichever blob store this build
/// may use. Every value is JSON, so a format that gains a field later does not
/// orphan the ones already stored.
public struct SecretStore {

    private let blobs: SecretBlobStore

    public init(blobs: SecretBlobStore) {
        self.blobs = blobs
    }

    /// Keychain, or the identity-directory file under the dev conditions of
    /// `IdentityStore.usesDevFileIdentity`.
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

    /// Records a completed exchange. `firstSeen` is kept from the existing entry,
    /// so the list says how long this controller has been known, not when it last
    /// connected.
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

    // MARK: Revocation

    /// What Refresh Code clears alongside the code itself (PROTOCOL.md §4.5):
    /// every controller this host trusted, and every failure it had counted.
    public func revokeControllers() throws {
        try blobs.remove(.trustedControllers)
        try blobs.remove(.guessCounters)
    }

    /// Part of a deliberate identity reset, and reachable from nowhere else.
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
