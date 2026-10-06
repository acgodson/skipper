import Foundation

public enum DeviceKeyStorageError: Error, LocalizedError, Equatable {
    case notStoredSecurely(detail: String)

    public var errorDescription: String? {
        switch self {
        case .notStoredSecurely(let detail):
            let sentence = "SkipperDesk could not store this Mac\u{2019}s credentials safely, so it will not "
                + "create them at all. Restart this Mac and open SkipperDesk again."
            return RCLog.enabled ? sentence + " (\(detail))" : sentence
        }
    }
}

public enum DeviceKeyRefusal: Equatable {
    case unsigned
    case notStoredSecurely(detail: String)

    public var error: Error {
        switch self {
        case .unsigned: return KeychainError.unsigned
        case .notStoredSecurely(let detail): return DeviceKeyStorageError.notStoredSecurely(detail: detail)
        }
    }

    static func from(_ failure: Error) -> DeviceKeyRefusal {
        if (failure as? KeychainError) == .unsigned { return .unsigned }
        return .notStoredSecurely(detail: failure.localizedDescription)
    }
}

extension Result {
    var failure: Failure? {
        if case .failure(let error) = self { return error }
        return nil
    }
}

public enum DeviceKeyPolicy {

    public enum NewKey: Equatable {
        case secureEnclave
        case keychain(note: String?)
        case refuse(DeviceKeyRefusal)
    }

    public enum ExistingFileKey: Equatable {
        case moveToKeychain
        case useFileForThisLaunch(note: String)
        case refuse(DeviceKeyRefusal)
    }

    public static let keyNotMovedNote = "This Mac could not move its credentials to safer storage."

    public static func newKey(secureEnclaveFailure: Error?, keychainFailure: Error?) -> NewKey {
        guard let secureEnclaveFailure else { return .secureEnclave }
        guard let keychainFailure else {
            return .keychain(note: "The Secure Enclave is not usable in this build: "
                + secureEnclaveFailure.localizedDescription)
        }
        return .refuse(.from(keychainFailure))
    }

    public static func existingFileKey(migrationFailure: Error?) -> ExistingFileKey {
        guard let migrationFailure else { return .moveToKeychain }
        if case .unsigned = DeviceKeyRefusal.from(migrationFailure) { return .refuse(.unsigned) }
        RCLog.error("identity: the legacy file key could not be moved to the Keychain; "
            + "using it for this launch only: \(migrationFailure.localizedDescription)")
        return .useFileForThisLaunch(note: keyNotMovedNote)
    }
}
