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
    public let secretStorageMode: SecretStorageMode?
    @Published public private(set) var keyStorageNote: String?
    public let publicKeyHex: String
    public let publicKeyBase64: String
    public let createdAt: Date

    private let fileStore: IdentityFileStore
    private let key: DeviceSigningKey
    public let secrets: SecretStore
    public let hostKeyPins: HostKeyPins
    public weak var sink: AccessCodeSink?

    public var formattedDeviceID: String { DeviceID.formatted(deviceID) }
    public var formattedAccessCode: String { AccessCode.formatted(accessCode) }
    public var storagePath: String { fileStore.fileURL.path }
    public var storageDisplayPath: String { (storagePath as NSString).abbreviatingWithTildeInPath }
    public var keyStorageLabel: String { keyStorage.label }
    public var secretStorageNote: String? { secretStorageMode?.footerNote }

    nonisolated public static func usesDevFileIdentity(fileStore: IdentityFileStore) -> Bool {
#if DEBUG || SKIPPER_TEST_HOOKS
        DevelopmentHooks.isOn(.devFileIdentity)
            || !fileStore.isDefaultLocation
#else
        !fileStore.isDefaultLocation
#endif
    }

    public init(
        fileStore: IdentityFileStore = IdentityFileStore(),
        sink: AccessCodeSink? = nil,
        blobStore: DeviceKeyBlobStore = KeychainBlobs<DeviceKeyAccount>(),
        secrets: SecretStore? = nil,
        devFileIdentity: Bool? = nil
    ) throws {
        self.fileStore = fileStore
        self.sink = sink
        let secrets = secrets ?? SecretStore.forThisMac(fileStore: fileStore)
        self.secrets = secrets
        self.hostKeyPins = HostKeyPins(secrets: secrets)

        let loaded = try fileStore.load()
        let devFileIdentity = devFileIdentity ?? Self.usesDevFileIdentity(fileStore: fileStore)
        let keychain = devFileIdentity ? nil : blobStore as? KeychainBlobs<DeviceKeyAccount>
        self.secretStorageMode = keychain?.mode
        if let keychain {
            LegacyKeychainMigration.run(
                identityCreatedAt: loaded?.record.createdAt,
                mode: keychain.mode,
                accessGroup: keychain.accessGroup
            )
        }

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
            let moved = Result { try KeychainDeviceKey.adopt(existing, in: blobStore) }
            switch DeviceKeyPolicy.existingFileKey(migrationFailure: moved.failure) {
            case .moveToKeychain:
                return ResolvedKey(key: try moved.get(), rewriteRecord: true, note: nil)
            case .useFileForThisLaunch(let note):
                return ResolvedKey(
                    key: FileDeviceKey(key: existing, url: fileStore.fileURL),
                    rewriteRecord: false,
                    note: note
                )
            case .refuse(let refusal):
                throw refusal.error
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

        let enclave = Result<DeviceSigningKey, Error> { try SecureEnclaveDeviceKey.create(in: blobStore) }
        let keychain = enclave.failure == nil
            ? nil
            : Result<DeviceSigningKey, Error> { try KeychainDeviceKey.create(in: blobStore) }
        switch DeviceKeyPolicy.newKey(secureEnclaveFailure: enclave.failure, keychainFailure: keychain?.failure) {
        case .secureEnclave:
            return ResolvedKey(key: try enclave.get(), rewriteRecord: true, note: nil)
        case .keychain(let note):
            return ResolvedKey(key: try (keychain ?? enclave).get(), rewriteRecord: true, note: note)
        case .refuse(let refusal):
            throw refusal.error
        }
    }

    private static func filePrivateKey(_ key: DeviceSigningKey) -> String? {
        guard let fileKey = key as? FileDeviceKey else { return nil }
        return fileKey.rawPrivateKey.base64EncodedString()
    }

    // MARK: - Key operations

    public static func discardStoredKeys(blobStore: DeviceKeyBlobStore = KeychainBlobs<DeviceKeyAccount>()) {
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
        try secrets.resetControllerGuessCounters()
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

    private func adopt(deviceID assigned: String) throws {
        guard DeviceIDCertificates.isDeviceID(assigned) else {
            throw IdentityRegistrationError.malformedDeviceID
        }
        guard assigned != deviceID else { return }
        RCLog.info("identity: the server assigned device id \(deviceID) -> \(assigned)")
        try persist(deviceID: assigned, serverRegistered: isServerRegistered)
        deviceID = assigned
    }

    private var certificates: DeviceIDCertificates {
        do {
            return try secrets.deviceIDCertificates(currentDeviceID: deviceID)
        } catch {
            RCLog.error("identity: the stored Device ID certificates could not be read: \(error.localizedDescription)")
            return DeviceIDCertificates()
        }
    }

    public var deviceIDCertificate: String? { certificates.certificate(for: deviceID) }

    /// The (Device ID, certificate) a re-registration presents, if any.
    public var certificatePresentation: (deviceID: String, certificate: String)? {
        certificates.presentation(currentDeviceID: deviceID)
    }

    /// `register_ok`: the id is adopted only when it is 9 digits and the
    /// certificate only when it is well formed; `DeviceIDCertificates` says
    /// what is kept when the server answers with a different id.
    public func recordRegistration(deviceID assigned: String, certificate: String?,
                                   presentedDeviceID: String?) throws {
        if let certificate, !certificate.isEmpty, !DeviceIDCertificates.isWellFormed(certificate) {
            throw IdentityRegistrationError.malformedCertificate
        }
        try adopt(deviceID: assigned)
        var book = certificates
        book.registered(deviceID: assigned, certificate: certificate, presented: presentedDeviceID)
        save(book)
        markServerRegistered()
    }

    /// `hello_ok` for this Mac's own id.
    public func storeDeviceIDCertificate(_ certificate: String?, forDeviceID owner: String) {
        guard owner == deviceID, let certificate, !certificate.isEmpty,
              certificate != deviceIDCertificate else { return }
        guard DeviceIDCertificates.isWellFormed(certificate) else {
            RCLog.error("identity: ignored a malformed Device ID certificate")
            return
        }
        var book = certificates
        book.confirmed(deviceID: deviceID, certificate: certificate)
        save(book)
    }

    private func save(_ book: DeviceIDCertificates) {
        do {
            try secrets.saveDeviceIDCertificates(book)
        } catch {
            RCLog.error("identity: the Device ID certificates could not be stored: \(error.localizedDescription)")
        }
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
        blobStore: DeviceKeyBlobStore = KeychainBlobs<DeviceKeyAccount>(),
        secrets: SecretStore? = nil
    ) throws {
        if !usesDevFileIdentity(fileStore: fileStore) {
            discardStoredKeys(blobStore: blobStore)
        }
        (secrets ?? SecretStore.forThisMac(fileStore: fileStore)).discardEverything()
        try fileStore.reset()
    }
}

public enum IdentityRegistrationError: Error, LocalizedError, Equatable {
    case malformedDeviceID
    case malformedCertificate

    public var errorDescription: String? {
        switch self {
        case .malformedDeviceID: return "The server assigned a Device ID that is not 9 digits."
        case .malformedCertificate: return "The server sent a malformed Device ID certificate."
        }
    }
}

extension IdentityStore: DeviceMessageSigner {
    @_spi(DeviceSigning)
    public func sign(_ message: Data) throws -> Data {
        try key.sign(message)
    }
}
