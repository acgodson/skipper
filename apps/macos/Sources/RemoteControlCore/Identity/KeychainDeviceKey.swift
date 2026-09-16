import Foundation
import CryptoKit

public final class KeychainDeviceKey: DeviceSigningKey {

    private let key: DeviceKey

    private init(key: DeviceKey) {
        self.key = key
    }

    public static func load(from store: DeviceKeyBlobStore) throws -> KeychainDeviceKey? {
        guard let blob = try store.load(.software) else { return nil }
        return KeychainDeviceKey(key: try DeviceKey(rawPrivateKey: blob))
    }

    public static func create(in store: DeviceKeyBlobStore) throws -> KeychainDeviceKey {
        try adopt(DeviceKey(), in: store)
    }

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
