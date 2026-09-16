import Foundation
import CryptoKit

/// A software P-256 key whose private scalar lives in the Keychain.
///
/// The fallback when the Secure Enclave cannot be used, and the destination of
/// every identity migrated off `identity.json`: a Secure Enclave key cannot be
/// imported, so an existing key can only be moved somewhere that accepts raw
/// bytes. Moving it preserves the Device ID, which is the whole point.
public final class KeychainDeviceKey: DeviceSigningKey {

    private let key: DeviceKey

    private init(key: DeviceKey) {
        self.key = key
    }

    /// Reads the existing key. Returns nil when there is nothing stored yet.
    public static func load(from store: DeviceKeyBlobStore) throws -> KeychainDeviceKey? {
        guard let blob = try store.load(.software) else { return nil }
        return KeychainDeviceKey(key: try DeviceKey(rawPrivateKey: blob))
    }

    /// Mints a key and stores it.
    public static func create(in store: DeviceKeyBlobStore) throws -> KeychainDeviceKey {
        try adopt(DeviceKey(), in: store)
    }

    /// Moves an existing software key into the Keychain, proving it can be read
    /// back before the caller is allowed to drop the copy it still holds.
    @discardableResult
    public static func adopt(_ key: DeviceKey, in store: DeviceKeyBlobStore) throws -> KeychainDeviceKey {
        try store.save(key.rawPrivateKey, for: .software)
        guard let reloaded = try load(from: store),
              reloaded.publicKeyDER == ((try? key.publicKeyDER()) ?? Data()) else {
            throw DeviceKeyError.malformedPrivateKey("the Keychain did not return the key that was just stored")
        }
        return reloaded
    }

    public var publicKeyDER: Data { (try? key.publicKeyDER()) ?? Data() }

    public func sign(_ data: Data) throws -> Data { try key.sign(data) }

    public var storage: DeviceKeyStorage { .keychain }
}
