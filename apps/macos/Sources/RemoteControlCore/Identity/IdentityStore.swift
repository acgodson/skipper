import Foundation

/// Owns this machine's durable identity: the Device ID, the access code and the
/// device keypair.
///
/// The Device ID, the access code and the registration flag live in one
/// owner-only file (`IdentityFileStore`). The private key lives in the strongest
/// backend this build can reach: the Secure Enclave, else the Keychain, else —
/// only for the dev flag or an overridden identity directory — the file itself.
/// Nothing here rotates on a timer and nothing here is ever silently regenerated.
@MainActor
public final class IdentityStore: ObservableObject {

    @Published public private(set) var deviceID: String
    @Published public private(set) var accessCode: String
    @Published public private(set) var lastRefreshError: String?
    /// Set when the identity file's permissions had to be repaired on load.
    @Published public private(set) var permissionWarning: String?
    /// False until `rc-signal` has assigned this device its permanent ID. The
    /// signaling client uses it to choose `register` over `hello` exactly once.
    @Published public private(set) var isServerRegistered: Bool

    /// Where the private key physically lives.
    public let keyStorage: DeviceKeyStorage
    /// Non-nil when a stronger backend was wanted but could not be used, so the
    /// UI can say what actually happened rather than overclaim.
    @Published public private(set) var keyStorageNote: String?
    /// Hex of the public half (X9.63). The private half is never exposed here.
    public let publicKeyHex: String
    /// Base64 DER SPKI — the exact `pubkey` string the signaling server expects.
    public let publicKeyBase64: String
    public let createdAt: Date

    private let fileStore: IdentityFileStore
    private let key: DeviceSigningKey
    public weak var sink: AccessCodeSink?

    public var formattedDeviceID: String { DeviceID.formatted(deviceID) }
    public var formattedAccessCode: String { AccessCode.formatted(accessCode) }
    /// Path of the identity file, for the UI to state plainly.
    public var storagePath: String { fileStore.fileURL.path }
    public var storageDisplayPath: String { (storagePath as NSString).abbreviatingWithTildeInPath }
    /// "Secure Enclave" / "Keychain" / "file (dev)".
    public var keyStorageLabel: String { keyStorage.label }

    /// True when several instances share this Mac and the key therefore has to
    /// stay in the identity file: the Keychain and the Secure Enclave each hold
    /// exactly one device key, so `rc-node` and the multi-instance scripts would
    /// otherwise fight over the same slot. Never true for a shipped app, whose
    /// identity directory is always the default one.
    nonisolated public static func usesDevFileIdentity(fileStore: IdentityFileStore) -> Bool {
        ProcessInfo.processInfo.environment["SKIPPER_DEV_FILE_IDENTITY"] == "1"
            || !fileStore.isDefaultLocation
    }

    /// `devFileIdentity` is derived from the environment unless a caller states
    /// it. Only the test suite ever states it: its identity directories are all
    /// overridden, so without this the real selection path would be unreachable.
    public init(
        fileStore: IdentityFileStore = IdentityFileStore(),
        sink: AccessCodeSink? = nil,
        blobStore: DeviceKeyBlobStore = DeviceKeyKeychain(),
        devFileIdentity: Bool? = nil
    ) throws {
        self.fileStore = fileStore
        self.sink = sink

        let loaded = try fileStore.load()
        let devFileIdentity = devFileIdentity ?? Self.usesDevFileIdentity(fileStore: fileStore)

        if let loaded {
            self.deviceID = loaded.record.deviceID
            self.accessCode = loaded.record.accessCode
            self.createdAt = loaded.record.createdAt
            self.permissionWarning = loaded.permissionWarning
            self.isServerRegistered = loaded.record.serverRegistered
        } else {
            self.deviceID = try DeviceID.generateLocal()
            self.accessCode = try AccessCode.generate()
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

        if loaded == nil || resolved.rewriteRecord {
            try fileStore.save(IdentityRecord(
                deviceID: deviceID,
                accessCode: accessCode,
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

    /// Secure Enclave, else Keychain, else — dev flag only — the identity file.
    ///
    /// MIGRATION: a Secure Enclave key cannot be imported, so an identity that
    /// already has a software key can never become a hardware one without
    /// changing the Device ID. It must not. Such a key is therefore *moved* into
    /// the Keychain and the file copy is dropped; only a brand-new identity gets
    /// a Secure Enclave key.
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

    /// The private half goes in the file only when the file *is* the backend.
    private static func filePrivateKey(_ key: DeviceSigningKey) -> String? {
        guard let fileKey = key as? FileDeviceKey else { return nil }
        return fileKey.rawPrivateKey.base64EncodedString()
    }

    // MARK: - Key operations

    /// Signs a challenge with the device key, returning an ASN.1 DER signature.
    /// The only key operation the rest of the app is allowed to perform.
    public func sign(_ message: Data) throws -> Data {
        try key.sign(message)
    }

    /// Base64 DER signature — the `sig` field on the wire.
    public func signatureBase64(for message: Data) throws -> String {
        try key.signatureBase64(for: message)
    }

    /// Frees the Keychain slot this Mac's key occupies. Part of a deliberate
    /// identity reset and reachable from nowhere else.
    public static func discardStoredKeys(blobStore: DeviceKeyBlobStore = DeviceKeyKeychain()) {
        try? blobStore.remove(.secureEnclave)
        try? blobStore.remove(.software)
    }

    /// Local verification. Used by tests; the app never verifies its own signature.
    public func verify(_ signature: Data, for message: Data) -> Bool {
        key.verify(signature, for: message)
    }

    // MARK: - Mutations

    /// Mints a new access code, writes it through to disk, then tells the sink so
    /// the old one can be revoked server-side.
    ///
    /// Storage happens *before* propagation: if the network is down the user still
    /// ends up with exactly one code that both the UI and the file agree on.
    @discardableResult
    public func refreshAccessCode() async throws -> String {
        let previous = accessCode
        var fresh = try AccessCode.generate()
        // Vanishingly unlikely at 60 bits, but a refresh that returns the same
        // code would silently break the user's expectation, so rule it out.
        while fresh == previous { fresh = try AccessCode.generate() }

        try persist(accessCode: fresh, deviceID: deviceID)
        accessCode = fresh
        lastRefreshError = nil

        do {
            try await sink?.accessCodeDidChange(deviceID: deviceID, newCode: fresh)
        } catch {
            // Surfaced in the UI: the local code changed but the server may still
            // honour the old one until we can reach it.
            lastRefreshError = "New code saved on this Mac, but it could not be "
                + "sent to the signaling server yet: \(error.localizedDescription)"
            throw error
        }
        return fresh
    }

    /// SEAM FOR PHASE 3. The server is the authority on Device IDs; when the
    /// signaling client completes its first `hello` it calls this with the
    /// assigned ID, replacing the locally minted placeholder.
    public func adoptServerAssignedDeviceID(_ assigned: String) throws {
        guard let canonical = DeviceID.canonicalize(assigned) else { return }
        guard canonical != deviceID else { return }
        try persist(accessCode: accessCode, deviceID: canonical, serverRegistered: isServerRegistered)
        deviceID = canonical
    }

    /// Records that the server has registered this pubkey and that `deviceID` is
    /// now the server's ID, not a local placeholder. Persisted, because a
    /// re-`register` on the next launch would be answered idempotently but a
    /// failure to `hello` would not.
    public func markServerRegistered() {
        guard !isServerRegistered else { return }
        try? persist(accessCode: accessCode, deviceID: deviceID, serverRegistered: true)
        isServerRegistered = true
    }

    /// Rewrites the whole record. The key and createdAt are carried through
    /// untouched — only the caller's two mutable fields ever change.
    private func persist(accessCode: String, deviceID: String, serverRegistered: Bool? = nil) throws {
        try fileStore.save(IdentityRecord(
            deviceID: deviceID,
            accessCode: accessCode,
            privateKeyBase64: Self.filePrivateKey(key),
            createdAt: createdAt,
            serverRegistered: serverRegistered ?? isServerRegistered,
            keyStorage: keyStorage.recordValue
        ))
    }

    // MARK: - Deliberate reset

    /// Discards the identity file so the next `IdentityStore(...)` mints a fresh
    /// Device ID, access code and keypair.
    ///
    /// This is the ONLY way an identity is ever destroyed, and it is reachable
    /// only from an explicit user action in the UI. A corrupt file must never
    /// trigger it automatically: silently changing the Device ID would break the
    /// peer Mac's saved entry with no explanation.
    public static func resetIdentity(
        fileStore: IdentityFileStore = IdentityFileStore(),
        blobStore: DeviceKeyBlobStore = DeviceKeyKeychain()
    ) throws {
        if !usesDevFileIdentity(fileStore: fileStore) {
            discardStoredKeys(blobStore: blobStore)
        }
        try fileStore.reset()
    }
}
