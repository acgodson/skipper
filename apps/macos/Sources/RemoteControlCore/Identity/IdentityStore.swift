import Foundation
import SkipperCore

/// Owns this machine's durable identity: the Device ID, the access code and the
/// device keypair.
///
/// Backed by one owner-only file (`IdentityFileStore`), so it survives app
/// restart, app upgrade and machine reboot. Nothing here rotates on a timer, and
/// nothing here touches the macOS Keychain — see `SecureFile` for why.
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

    /// Where the private key physically lives. Exactly one case today: a file.
    public let keyStorage: DeviceKeyStorage
    /// Hex of the public half (X9.63). The private half is never exposed here.
    public let publicKeyHex: String
    /// Base64 DER SPKI — the exact `pubkey` string the signaling server expects.
    public let publicKeyBase64: String
    public let createdAt: Date

    private let fileStore: IdentityFileStore
    private let key: DeviceKey
    public weak var sink: AccessCodeSink?

    public var formattedDeviceID: String { DeviceID.formatted(deviceID) }
    public var formattedAccessCode: String { AccessCode.formatted(accessCode) }
    /// Path of the identity file, for the UI to state plainly.
    public var storagePath: String { fileStore.fileURL.path }
    public var storageDisplayPath: String { (storagePath as NSString).abbreviatingWithTildeInPath }

    public init(
        fileStore: IdentityFileStore = IdentityFileStore(),
        sink: AccessCodeSink? = nil
    ) throws {
        self.fileStore = fileStore
        self.sink = sink
        self.keyStorage = .file(fileStore.fileURL)

        if let loaded = try fileStore.load() {
            // Existing identity. Every field is used as found; nothing is re-minted.
            self.deviceID = loaded.record.deviceID
            self.accessCode = loaded.record.accessCode
            self.createdAt = loaded.record.createdAt
            self.permissionWarning = loaded.permissionWarning
            self.isServerRegistered = loaded.record.serverRegistered
            // load() already proved these decode; the force here cannot fire.
            self.key = try DeviceKey(rawPrivateKey: Data(base64Encoded: loaded.record.privateKeyBase64) ?? Data())
        } else {
            // First launch: mint everything once, then write it exactly once.
            let key = DeviceKey()
            let record = IdentityRecord(
                deviceID: try DeviceID.generateLocal(),
                accessCode: try AccessCode.generate(),
                privateKeyBase64: key.rawPrivateKey.base64EncodedString(),
                createdAt: IdentityRecord.timestamp()
            )
            try fileStore.save(record)
            self.key = key
            self.deviceID = record.deviceID
            self.accessCode = record.accessCode
            self.createdAt = record.createdAt
            self.permissionWarning = nil
            self.isServerRegistered = false
        }

        self.publicKeyHex = (try? key.publicKeyHex()) ?? ""
        self.publicKeyBase64 = (try? key.publicKeyBase64()) ?? ""
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
            privateKeyBase64: key.rawPrivateKey.base64EncodedString(),
            createdAt: createdAt,
            serverRegistered: serverRegistered ?? isServerRegistered
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
    public static func resetIdentity(fileStore: IdentityFileStore = IdentityFileStore()) throws {
        try fileStore.reset()
    }
}
