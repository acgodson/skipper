import Foundation

/// The on-disk shape of `identity.json`.
///
/// Field names are part of a persisted format, so they are spelled out
/// explicitly with CodingKeys rather than left to synthesis — renaming a Swift
/// property must never silently orphan a user's identity.
public struct IdentityRecord: Equatable {

    /// Bump only for a format change that older builds cannot read. A record
    /// carrying a higher version than this build understands is refused rather
    /// than misinterpreted.
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    public var deviceID: String
    public var accessCode: String
    /// Base64 of the 32-byte P-256 private scalar. Never logged, never displayed.
    public var privateKeyBase64: String
    public var createdAt: Date
    /// True once `rc-signal` has issued this device its permanent Device ID.
    ///
    /// The ID minted on first launch is a local placeholder (see
    /// `DeviceID.generateLocal`); the server is the authority. Without this flag
    /// the signaling client cannot tell "I have never registered" from "I have
    /// registered and this is my real ID", and would either re-register on every
    /// launch or fail `hello` forever. Optional on decode so an identity file
    /// written by Phase 2 still loads.
    public var serverRegistered: Bool

    public init(
        schemaVersion: Int = IdentityRecord.currentSchemaVersion,
        deviceID: String,
        accessCode: String,
        privateKeyBase64: String,
        createdAt: Date,
        serverRegistered: Bool = false
    ) {
        self.schemaVersion = schemaVersion
        self.deviceID = deviceID
        self.accessCode = accessCode
        self.privateKeyBase64 = privateKeyBase64
        self.createdAt = createdAt
        self.serverRegistered = serverRegistered
    }

    /// A timestamp at whole-second resolution.
    ///
    /// `createdAt` is serialised as ISO-8601, which carries no fractional part,
    /// so a `Date()` taken now would NOT compare equal to the one read back a
    /// moment later. Truncating at the source makes the in-memory value and the
    /// on-disk value the same thing, which is what lets the round-trip test be an
    /// exact equality rather than a fuzzy one. Sub-second precision on "when was
    /// this identity created" is meaningless anyway.
    public static func timestamp(_ date: Date = Date()) -> Date {
        Date(timeIntervalSince1970: date.timeIntervalSince1970.rounded(.down))
    }

    /// Builds a record around a live key, so callers never have to handle the
    /// raw private bytes themselves. `IdentityStore` and the tests both use this.
    public init(deviceID: String, accessCode: String, key: DeviceKey, createdAt: Date,
                serverRegistered: Bool = false) {
        self.init(
            deviceID: deviceID,
            accessCode: accessCode,
            privateKeyBase64: key.rawPrivateKey.base64EncodedString(),
            createdAt: createdAt,
            serverRegistered: serverRegistered
        )
    }
}

extension IdentityRecord: Codable {
    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schemaVersion"
        case deviceID = "deviceId"
        case accessCode = "accessCode"
        case privateKeyBase64 = "privateKey"
        case createdAt = "createdAt"
        case serverRegistered = "serverRegistered"
    }

    // Hand-written so that `serverRegistered` is *optional* on read. A Phase 2
    // identity file has no such key; refusing to load it would destroy a
    // working identity over an additive field.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try c.decode(Int.self, forKey: .schemaVersion)
        deviceID = try c.decode(String.self, forKey: .deviceID)
        accessCode = try c.decode(String.self, forKey: .accessCode)
        privateKeyBase64 = try c.decode(String.self, forKey: .privateKeyBase64)
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        serverRegistered = try c.decodeIfPresent(Bool.self, forKey: .serverRegistered) ?? false
    }
}

// MARK: - Errors

/// Failures the UI has to distinguish, because the right response differs.
///
/// `corrupt` and `unsupportedSchema` deliberately do NOT lead to "just make a
/// new identity": regenerating would silently change the user's Device ID and
/// access code, breaking the saved entry on their other Mac with no explanation.
/// The user is told exactly what is wrong and has to choose Reset Identity.
public enum IdentityFileError: Error, LocalizedError, Equatable {

    case corrupt(path: String, reason: String)
    case unsupportedSchema(path: String, found: Int, supported: Int)
    case invalidContents(path: String, reason: String)
    case io(String)

    public var errorDescription: String? {
        switch self {
        case .corrupt(let path, let reason):
            return "The identity file at \(path) is damaged and could not be read (\(reason)). "
                + "It has NOT been replaced: doing so would change this Mac's Device ID and access "
                + "code, and any Mac that has saved them would stop connecting. "
                + "Restore the file from a backup, or choose Reset Identity to deliberately start over."
        case .unsupportedSchema(let path, let found, let supported):
            return "The identity file at \(path) was written by a newer version of RemoteControl "
                + "(format \(found); this build understands \(supported)). Update the app, or choose "
                + "Reset Identity to discard it and start over."
        case .invalidContents(let path, let reason):
            return "The identity file at \(path) parsed but its contents are not valid (\(reason)). "
                + "It has NOT been replaced. Restore it from a backup, or choose Reset Identity."
        case .io(let message):
            return message
        }
    }

    /// True when "Reset identity" is the sensible offer to put in front of the user.
    public var isResettable: Bool {
        switch self {
        case .corrupt, .unsupportedSchema, .invalidContents: return true
        case .io: return false
        }
    }
}

// MARK: - Store

/// Reads and writes `~/Library/Application Support/RemoteControl/identity.json`.
///
/// Directory 0700, file 0600, enforced on every write and repaired on every read.
/// Writes are atomic (temp file + fsync + rename), so an interrupted write leaves
/// the previous identity completely intact rather than a truncated one.
public struct IdentityFileStore {

    public static let fileName = "identity.json"
    public static let peerCodeFileName = "peer-code"

    public let directory: URL

    /// Test seam. Production leaves this nil. A test sets it to throw and then
    /// asserts that the file on disk is still the previous, valid identity.
    public var beforeRename: (() throws -> Void)?

    public init(directory: URL = IdentityFileStore.defaultDirectory, beforeRename: (() throws -> Void)? = nil) {
        self.directory = directory
        self.beforeRename = beforeRename
    }

    /// `~/Library/Application Support/RemoteControl`.
    ///
    /// Not the sandbox container: the app is deliberately unsandboxed (whole-desktop
    /// capture and system-wide event injection are incompatible with the sandbox),
    /// so this resolves to the real home directory.
    public static var defaultDirectory: URL {
        // TEST SEAM, and the only way two instances can run on one Mac with
        // separate identities — which is exactly what scripts/test-transport.sh
        // needs in order to be a real two-party test rather than a mock.
        if let override = ProcessInfo.processInfo.environment["RC_IDENTITY_DIR"],
           !override.isEmpty {
            return URL(fileURLWithPath: (override as NSString).expandingTildeInPath, isDirectory: true)
        }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("RemoteControl", isDirectory: true)
    }

    public var fileURL: URL { directory.appendingPathComponent(Self.fileName) }
    public var peerCodeURL: URL { directory.appendingPathComponent(Self.peerCodeFileName) }

    // MARK: Load

    public struct Loaded {
        public let record: IdentityRecord
        /// Non-nil when the file's permissions were too open and were tightened.
        public let permissionWarning: String?
    }

    /// Returns nil on first launch (no file yet). Throws — and never regenerates —
    /// when a file exists but cannot be trusted.
    public func load() throws -> Loaded? {
        let read: (data: Data, warning: String?)?
        do {
            read = try SecureFile.read(fileURL)
        } catch {
            throw IdentityFileError.io(error.localizedDescription)
        }
        guard let read else { return nil }

        if read.data.isEmpty {
            throw IdentityFileError.corrupt(path: fileURL.path, reason: "the file is empty")
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let record: IdentityRecord
        do {
            record = try decoder.decode(IdentityRecord.self, from: read.data)
        } catch {
            // The message is about structure only. The file's contents are secret
            // and must not end up in an error string or a log line.
            throw IdentityFileError.corrupt(path: fileURL.path, reason: Self.describeDecodingFailure(error))
        }

        guard record.schemaVersion <= IdentityRecord.currentSchemaVersion else {
            throw IdentityFileError.unsupportedSchema(
                path: fileURL.path,
                found: record.schemaVersion,
                supported: IdentityRecord.currentSchemaVersion
            )
        }
        guard record.schemaVersion >= 1 else {
            throw IdentityFileError.invalidContents(path: fileURL.path, reason: "schemaVersion \(record.schemaVersion) is not a real version")
        }
        guard DeviceID.canonicalize(record.deviceID) != nil else {
            throw IdentityFileError.invalidContents(path: fileURL.path, reason: "deviceId is not nine digits")
        }
        guard AccessCode.canonicalize(record.accessCode) != nil else {
            throw IdentityFileError.invalidContents(path: fileURL.path, reason: "the access code is not a valid 12-symbol code")
        }
        guard let keyBytes = Data(base64Encoded: record.privateKeyBase64), keyBytes.count == 32 else {
            throw IdentityFileError.invalidContents(path: fileURL.path, reason: "the private key is not 32 base64-encoded bytes")
        }
        // Prove the scalar is actually a usable P-256 key before we report success.
        guard (try? DeviceKey(rawPrivateKey: keyBytes)) != nil else {
            throw IdentityFileError.invalidContents(path: fileURL.path, reason: "the private key is not a valid P-256 scalar")
        }

        return Loaded(record: record, permissionWarning: read.warning)
    }

    // MARK: Save

    public func save(_ record: IdentityRecord) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data: Data
        do {
            data = try encoder.encode(record)
        } catch {
            throw IdentityFileError.io("Could not encode the identity: \(error.localizedDescription)")
        }
        do {
            try SecureFile.writeAtomically(data, to: fileURL, beforeRename: beforeRename)
        } catch {
            throw IdentityFileError.io(error.localizedDescription)
        }
    }

    /// Deletes the identity file. The ONLY path that discards an identity, and it
    /// is reached only from an explicit user action.
    @discardableResult
    public func reset() throws -> Bool {
        do {
            return try SecureFile.remove(fileURL)
        } catch {
            throw IdentityFileError.io(error.localizedDescription)
        }
    }

    // MARK: Saved peer access code (controller side, "Remember this code")

    /// Kept in its own file rather than inside `identity.json`: it belongs to the
    /// *peer*, has a different lifetime, and forgetting it must not risk touching
    /// this Mac's own identity.
    public func loadPeerAccessCode() throws -> String? {
        do {
            guard let read = try SecureFile.read(peerCodeURL) else { return nil }
            guard let text = String(data: read.data, encoding: .utf8) else { return nil }
            return AccessCode.canonicalize(text)
        } catch {
            throw IdentityFileError.io(error.localizedDescription)
        }
    }

    public func savePeerAccessCode(_ code: String) throws {
        guard let canonical = AccessCode.canonicalize(code) else { return }
        do {
            try SecureFile.writeAtomically(Data(canonical.utf8), to: peerCodeURL)
        } catch {
            throw IdentityFileError.io(error.localizedDescription)
        }
    }

    @discardableResult
    public func forgetPeerAccessCode() throws -> Bool {
        do {
            return try SecureFile.remove(peerCodeURL)
        } catch {
            throw IdentityFileError.io(error.localizedDescription)
        }
    }

    // MARK: Helpers

    /// Turns a `DecodingError` into a short structural description. Deliberately
    /// never includes the decoded value — that would leak key material.
    private static func describeDecodingFailure(_ error: Swift.Error) -> String {
        guard let decoding = error as? DecodingError else { return "not valid JSON" }
        switch decoding {
        case .dataCorrupted: return "not valid JSON"
        case .keyNotFound(let key, _): return "the field '\(key.stringValue)' is missing"
        case .typeMismatch(_, let context):
            return "the field '\(context.codingPath.map(\.stringValue).joined(separator: "."))' has the wrong type"
        case .valueNotFound(_, let context):
            return "the field '\(context.codingPath.map(\.stringValue).joined(separator: "."))' is null"
        @unknown default: return "not valid JSON"
        }
    }
}
