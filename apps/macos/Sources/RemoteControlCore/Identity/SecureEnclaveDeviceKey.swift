import Foundation
import CryptoKit
import Security

public enum SecureEnclaveError: Error, LocalizedError {
    case notAvailable
    case accessControl(String)
    case creationFailed(String)
    case restoreFailed(String)

    public var errorDescription: String? {
        switch self {
        case .notAvailable:
            return "This Mac has no Secure Enclave, or this build is not signed with a Developer ID."
        case .accessControl(let reason):
            return "The Secure Enclave access policy could not be created (\(reason))."
        case .creationFailed(let reason):
            return "A Secure Enclave key could not be created (\(reason))."
        case .restoreFailed(let reason):
            return "The stored Secure Enclave key could not be reopened (\(reason))."
        }
    }
}

public final class SecureEnclaveDeviceKey: DeviceSigningKey {

    private let key: SecureEnclave.P256.Signing.PrivateKey

    private init(key: SecureEnclave.P256.Signing.PrivateKey) {
        self.key = key
    }

    public static var isSupported: Bool { SecureEnclave.isAvailable }

    public static func load(from store: DeviceKeyBlobStore) throws -> SecureEnclaveDeviceKey? {
        guard let blob = try store.load(.secureEnclave) else { return nil }
        do {
            return SecureEnclaveDeviceKey(
                key: try SecureEnclave.P256.Signing.PrivateKey(dataRepresentation: blob)
            )
        } catch {
            throw SecureEnclaveError.restoreFailed(error.localizedDescription)
        }
    }

    public static func create(in store: DeviceKeyBlobStore) throws -> SecureEnclaveDeviceKey {
        guard isSupported else { throw SecureEnclaveError.notAvailable }
        let created: SecureEnclave.P256.Signing.PrivateKey
        do {
            created = try SecureEnclave.P256.Signing.PrivateKey(accessControl: try accessControl())
        } catch let error as SecureEnclaveError {
            throw error
        } catch {
            throw SecureEnclaveError.creationFailed(error.localizedDescription)
        }
        try store.save(created.dataRepresentation, for: .secureEnclave)
        return SecureEnclaveDeviceKey(key: created)
    }

    private static func accessControl() throws -> SecAccessControl {
        var error: Unmanaged<CFError>?
        guard let control = SecAccessControlCreateWithFlags(
            nil,
            kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            [.privateKeyUsage],
            &error
        ) else {
            let reason = (error?.takeRetainedValue() as Error?)?.localizedDescription ?? "unknown"
            throw SecureEnclaveError.accessControl(reason)
        }
        return control
    }

    public var publicKeyDER: Data { key.publicKey.derRepresentation }

    public func sign(_ data: Data) throws -> Data {
        try key.signature(for: data).derRepresentation
    }

    public var storage: DeviceKeyStorage { .secureEnclave }
}
