import Foundation
import SkipperCore

public struct IdentityRecord: Equatable {

    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    public var deviceID: String
    public var accessCode: String?
    public var privateKeyBase64: String?
    public var keyStorage: String?
    public var createdAt: Date
    public var serverRegistered: Bool

    public init(
        schemaVersion: Int = IdentityRecord.currentSchemaVersion,
        deviceID: String,
        accessCode: String? = nil,
        privateKeyBase64: String?,
        createdAt: Date,
        serverRegistered: Bool = false,
        keyStorage: String? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.deviceID = deviceID
        self.accessCode = accessCode
        self.privateKeyBase64 = privateKeyBase64
        self.keyStorage = keyStorage
        self.createdAt = createdAt
        self.serverRegistered = serverRegistered
    }

    public static func timestamp(_ date: Date = Date()) -> Date {
        Date(timeIntervalSince1970: date.timeIntervalSince1970.rounded(.down))
    }

    public init(deviceID: String, accessCode: String? = nil, key: DeviceKey, createdAt: Date,
                serverRegistered: Bool = false) {
        self.init(
            deviceID: deviceID,
            accessCode: accessCode,
            privateKeyBase64: key.rawPrivateKey.base64EncodedString(),
            createdAt: createdAt,
            serverRegistered: serverRegistered,
            keyStorage: "file"
        )
    }
}

extension IdentityRecord: Codable {
    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schemaVersion"
        case deviceID = "deviceId"
        case accessCode = "accessCode"
        case privateKeyBase64 = "privateKey"
        case keyStorage = "keyStorage"
        case createdAt = "createdAt"
        case serverRegistered = "serverRegistered"
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(schemaVersion, forKey: .schemaVersion)
        try c.encode(deviceID, forKey: .deviceID)
        try c.encodeIfPresent(accessCode, forKey: .accessCode)
        try c.encodeIfPresent(privateKeyBase64, forKey: .privateKeyBase64)
        try c.encodeIfPresent(keyStorage, forKey: .keyStorage)
        try c.encode(createdAt, forKey: .createdAt)
        try c.encode(serverRegistered, forKey: .serverRegistered)
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try c.decode(Int.self, forKey: .schemaVersion)
        deviceID = try c.decode(String.self, forKey: .deviceID)
        accessCode = try c.decodeIfPresent(String.self, forKey: .accessCode)
        privateKeyBase64 = try c.decodeIfPresent(String.self, forKey: .privateKeyBase64)
        keyStorage = try c.decodeIfPresent(String.self, forKey: .keyStorage)
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        serverRegistered = try c.decodeIfPresent(Bool.self, forKey: .serverRegistered) ?? false
    }
}

// MARK: - Errors

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

    public var isResettable: Bool {
        switch self {
        case .corrupt, .unsupportedSchema, .invalidContents: return true
        case .io: return false
        }
    }
}

// MARK: - Store

public struct IdentityFileStore {

    public static let fileName = "identity.json"

    public let directory: URL

    public var beforeRename: (() throws -> Void)?

    public init(directory: URL = IdentityFileStore.defaultDirectory, beforeRename: (() throws -> Void)? = nil) {
        self.directory = directory
        self.beforeRename = beforeRename
    }

    public static var defaultDirectory: URL {
        if let override = ProcessInfo.processInfo.environment["RC_IDENTITY_DIR"],
           !override.isEmpty {
            return URL(fileURLWithPath: (override as NSString).expandingTildeInPath, isDirectory: true)
        }
        return systemDefaultDirectory
    }

    public static var systemDefaultDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("RemoteControl", isDirectory: true)
    }

    public var isDefaultLocation: Bool {
        directory.standardizedFileURL == Self.systemDefaultDirectory.standardizedFileURL
    }

    public var fileURL: URL { directory.appendingPathComponent(Self.fileName) }

    // MARK: Load

    public struct Loaded {
        public let record: IdentityRecord
        public let permissionWarning: String?
    }

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
        if let accessCode = record.accessCode, AccessCode.canonicalize(accessCode) == nil {
            throw IdentityFileError.invalidContents(path: fileURL.path, reason: "the access code is not a valid 12-symbol code")
        }
        if let privateKeyBase64 = record.privateKeyBase64 {
            guard let keyBytes = Data(base64Encoded: privateKeyBase64), keyBytes.count == 32 else {
                throw IdentityFileError.invalidContents(path: fileURL.path, reason: "the private key is not 32 base64-encoded bytes")
            }
            guard (try? DeviceKey(rawPrivateKey: keyBytes)) != nil else {
                throw IdentityFileError.invalidContents(path: fileURL.path, reason: "the private key is not a valid P-256 scalar")
            }
        } else {
            guard let keyStorage = record.keyStorage, keyStorage != "file" else {
                throw IdentityFileError.invalidContents(path: fileURL.path, reason: "the private key is missing")
            }
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

    @discardableResult
    public func reset() throws -> Bool {
        do {
            return try SecureFile.remove(fileURL)
        } catch {
            throw IdentityFileError.io(error.localizedDescription)
        }
    }

    // MARK: Helpers

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
