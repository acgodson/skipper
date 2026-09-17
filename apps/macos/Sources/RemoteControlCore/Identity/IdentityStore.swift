import Foundation
import SkipperCore

@MainActor
public final class IdentityStore: ObservableObject {

    @Published public private(set) var deviceID: String
    @Published public private(set) var accessCode: String
    @Published public private(set) var lastRefreshError: String?
    @Published public private(set) var permissionWarning: String?
    @Published public private(set) var isServerRegistered: Bool

    public let keyStorage: DeviceKeyStorage
    @Published public private(set) var keyStorageNote: String?
    public let publicKeyHex: String
    public let publicKeyBase64: String
    public let createdAt: Date

    private let fileStore: IdentityFileStore
    private let key: DeviceSigningKey
    public let secrets: SecretStore
    public weak var sink: AccessCodeSink?

    public var formattedDeviceID: String { DeviceID.formatted(deviceID) }
    public var formattedAccessCode: String { AccessCode.formatted(accessCode) }
    public var storagePath: String { fileStore.fileURL.path }
    public var storageDisplayPath: String { (storagePath as NSString).abbreviatingWithTildeInPath }
    public var keyStorageLabel: String { keyStorage.label }

    nonisolated public static func usesDevFileIdentity(fileStore: IdentityFileStore) -> Bool {
#if DEBUG || SKIPPER_TEST_HOOKS
        ProcessInfo.processInfo.environment["SKIPPER_DEV_FILE_IDENTITY"] == "1"
            || !fileStore.isDefaultLocation
#else
        !fileStore.isDefaultLocation
#endif
    }

    public init(
        fileStore: IdentityFileStore = IdentityFileStore(),
        sink: AccessCodeSink? = nil,
        blobStore: DeviceKeyBlobStore = DeviceKeyKeychain(),
        secrets: SecretStore? = nil,
        devFileIdentity: Bool? = nil
    ) throws {
        self.fileStore = fileStore
        self.sink = sink
        let secrets = secrets ?? SecretStore.forThisMac(fileStore: fileStore)
        self.secrets = secrets

        let loaded = try fileStore.load()
        let devFileIdentity = devFileIdentity ?? Self.usesDevFileIdentity(fileStore: fileStore)

        let storedCode = try secrets.accessCode()
        let migratedCode = storedCode == nil ? loaded?.record.accessCode : nil
        let resolvedCode = try storedCode ?? migratedCode ?? AccessCode.generate()
        if storedCode == nil { try secrets.saveAccessCode(resolvedCode) }
        self.accessCode = resolvedCode

        if let loaded {
            self.deviceID = loaded.record.deviceID
            self.createdAt = loaded.record.createdAt
            self.permissionWarning = loaded.permissionWarning
            self.isServerRegistered = loaded.record.serverRegistered
        } else {
            self.deviceID = try DeviceID.generateLocal()
            self.createdAt = IdentityRecord.timestamp()
            self.permissionWarning = nil
            self.isServerRegistered = false
        }

        let resolved = try Self.resolveKey(
            record: loaded?.record,
            fileStore: fileStore,
            blobStore: blobStore,
            devFileIdentity: devFileIdentity
        )
        self.key = resolved.key
        self.keyStorage = resolved.key.storage
        self.keyStorageNote = resolved.note
        self.publicKeyHex = resolved.key.publicKeyHex
        self.publicKeyBase64 = resolved.key.publicKeyBase64

        if loaded == nil || resolved.rewriteRecord || migratedCode != nil {
            try fileStore.save(IdentityRecord(
                deviceID: deviceID,
                privateKeyBase64: Self.filePrivateKey(resolved.key),
                createdAt: createdAt,
                serverRegistered: isServerRegistered,
                keyStorage: resolved.key.storage.recordValue
            ))
        }
    }

    // MARK: - Key selection

    private struct ResolvedKey {
        let key: DeviceSigningKey
        let rewriteRecord: Bool
        let note: String?
    }

    private static func resolveKey(
        record: IdentityRecord?,
        fileStore: IdentityFileStore,
        blobStore: DeviceKeyBlobStore,
        devFileIdentity: Bool
    ) throws -> ResolvedKey {

        if devFileIdentity {
            if let stored = record?.privateKeyBase64, let bytes = Data(base64Encoded: stored) {
                return ResolvedKey(
                    key: FileDeviceKey(key: try DeviceKey(rawPrivateKey: bytes), url: fileStore.fileURL),
                    rewriteRecord: false,
                    note: nil
                )
            }
            if record != nil {
                throw IdentityFileError.invalidContents(
                    path: fileStore.fileURL.path,
                    reason: "this identity's key lives in the Keychain, and SKIPPER_DEV_FILE_IDENTITY cannot reach it"
                )
            }
            return ResolvedKey(
                key: FileDeviceKey(key: DeviceKey(), url: fileStore.fileURL),
                rewriteRecord: true,
                note: nil
            )
        }

        if let stored = record?.privateKeyBase64, let bytes = Data(base64Encoded: stored) {
            let existing = try DeviceKey(rawPrivateKey: bytes)
            do {
                return ResolvedKey(
                    key: try KeychainDeviceKey.adopt(existing, in: blobStore),
                    rewriteRecord: true,
                    note: nil
                )
            } catch {
                return ResolvedKey(
                    key: FileDeviceKey(key: existing, url: fileStore.fileURL),
                    rewriteRecord: false,
                    note: "This Mac's key could not be moved into the Keychain, so it stays in the identity file: "
                        + error.localizedDescription
                )
            }
        }

        if record?.keyStorage == DeviceKeyStorage.secureEnclave.recordValue {
            guard let key = try SecureEnclaveDeviceKey.load(from: blobStore) else {
                throw IdentityFileError.invalidContents(
                    path: fileStore.fileURL.path,
                    reason: "this identity's Secure Enclave key is no longer in the Keychain"
                )
            }
            return ResolvedKey(key: key, rewriteRecord: false, note: nil)
        }

        if record != nil {
            guard let key = try KeychainDeviceKey.load(from: blobStore) else {
                throw IdentityFileError.invalidContents(
                    path: fileStore.fileURL.path,
                    reason: "this identity's key is no longer in the Keychain"
                )
            }
            return ResolvedKey(key: key, rewriteRecord: false, note: nil)
        }

        var firstFailure: String?
        do {
            return ResolvedKey(key: try SecureEnclaveDeviceKey.create(in: blobStore), rewriteRecord: true, note: nil)
        } catch {
            firstFailure = error.localizedDescription
        }
        do {
            return ResolvedKey(
                key: try KeychainDeviceKey.create(in: blobStore),
                rewriteRecord: true,
                note: firstFailure.map { "The Secure Enclave is not usable in this build: \($0)" }
            )
        } catch {
            return ResolvedKey(
                key: FileDeviceKey(key: DeviceKey(), url: fileStore.fileURL),
                rewriteRecord: true,
                note: "Neither the Secure Enclave nor the Keychain could hold this Mac's key, so it is in the "
                    + "identity file: \(error.localizedDescription)"
            )
        }
    }

    private static func filePrivateKey(_ key: DeviceSigningKey) -> String? {
        guard let fileKey = key as? FileDeviceKey else { return nil }
        return fileKey.rawPrivateKey.base64EncodedString()
    }

    // MARK: - Key operations

    public func sign(_ message: Data) throws -> Data {
        try key.sign(message)
    }

    public func signatureBase64(for message: Data) throws -> String {
        try key.signatureBase64(for: message)
    }

    public static func discardStoredKeys(blobStore: DeviceKeyBlobStore = DeviceKeyKeychain()) {
        try? blobStore.remove(.secureEnclave)
        try? blobStore.remove(.software)
    }

    public func verify(_ signature: Data, for message: Data) -> Bool {
        key.verify(signature, for: message)
    }

    // MARK: - Mutations

    @discardableResult
    public func refreshAccessCode() async throws -> String {
        let previous = accessCode
        var fresh = try AccessCode.generate()
        while fresh == previous { fresh = try AccessCode.generate() }

        try secrets.saveAccessCode(fresh)
        try secrets.revokeControllers()
        accessCode = fresh
        lastRefreshError = nil

        do {
            try await sink?.accessCodeDidChange(deviceID: deviceID)
        } catch {
            lastRefreshError = "New code saved on this Mac, but it could not be "
                + "sent to the signaling server yet: \(error.localizedDescription)"
            throw error
        }
        return fresh
    }

    public func adoptServerAssignedDeviceID(_ assigned: String) throws {
        guard let canonical = DeviceID.canonicalize(assigned) else { return }
        guard canonical != deviceID else { return }
        try persist(deviceID: canonical, serverRegistered: isServerRegistered)
        deviceID = canonical
    }

    public func markServerRegistered() {
        guard !isServerRegistered else { return }
        try? persist(deviceID: deviceID, serverRegistered: true)
        isServerRegistered = true
    }

    private func persist(deviceID: String, serverRegistered: Bool? = nil) throws {
        try fileStore.save(IdentityRecord(
            deviceID: deviceID,
            privateKeyBase64: Self.filePrivateKey(key),
            createdAt: createdAt,
            serverRegistered: serverRegistered ?? isServerRegistered,
            keyStorage: keyStorage.recordValue
        ))
    }

    // MARK: - Deliberate reset

    public static func resetIdentity(
        fileStore: IdentityFileStore = IdentityFileStore(),
        blobStore: DeviceKeyBlobStore = DeviceKeyKeychain(),
        secrets: SecretStore? = nil
    ) throws {
        if !usesDevFileIdentity(fileStore: fileStore) {
            discardStoredKeys(blobStore: blobStore)
        }
        (secrets ?? SecretStore.forThisMac(fileStore: fileStore)).discardEverything()
        try fileStore.reset()
    }
}
