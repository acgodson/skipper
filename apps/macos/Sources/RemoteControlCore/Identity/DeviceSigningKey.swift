import Foundation
import CryptoKit

public enum DeviceKeyStorage: Equatable, CustomStringConvertible {

    case secureEnclave
    case keychain
    case file(URL)

    public var label: String {
        switch self {
        case .secureEnclave: return "Secure Enclave"
        case .keychain: return "Keychain"
        case .file: return "file (dev)"
        }
    }

    public var description: String {
        switch self {
        case .secureEnclave: return "Hardware key in the Secure Enclave; the private half never leaves the chip"
        case .keychain: return "Software key in the Keychain, unlocked after first unlock, this device only"
        case .file: return "Software key in an owner-only file (0600)"
        }
    }

    public var recordValue: String {
        switch self {
        case .secureEnclave: return "secureEnclave"
        case .keychain: return "keychain"
        case .file: return "file"
        }
    }

    public var path: String? {
        switch self {
        case .file(let url): return url.path
        case .secureEnclave, .keychain: return nil
        }
    }

    public var displayPath: String? {
        guard let path else { return nil }
        return (path as NSString).abbreviatingWithTildeInPath
    }
}

public protocol DeviceSigningKey: AnyObject {
    var publicKeyDER: Data { get }
    func sign(_ data: Data) throws -> Data
    var storage: DeviceKeyStorage { get }
}

extension DeviceSigningKey {

    public var publicKeyBase64: String { publicKeyDER.base64EncodedString() }

    public var publicKeyX963: Data {
        (try? P256.Signing.PublicKey(derRepresentation: publicKeyDER).x963Representation) ?? Data()
    }

    public var publicKeyHex: String {
        publicKeyX963.map { String(format: "%02x", $0) }.joined()
    }

    public func verify(_ signature: Data, for message: Data) -> Bool {
        guard let publicKey = try? P256.Signing.PublicKey(derRepresentation: publicKeyDER),
              let parsed = try? P256.Signing.ECDSASignature(derRepresentation: signature) else { return false }
        return publicKey.isValidSignature(parsed, for: message)
    }
}

public final class FileDeviceKey: DeviceSigningKey {

    private let key: DeviceKey
    private let url: URL

    public init(key: DeviceKey, url: URL) {
        self.key = key
        self.url = url
    }

    public var publicKeyDER: Data { (try? key.publicKeyDER()) ?? Data() }
    public func sign(_ data: Data) throws -> Data { try key.sign(data) }
    public var storage: DeviceKeyStorage { .file(url) }

    var rawPrivateKey: Data { key.rawPrivateKey }
}
