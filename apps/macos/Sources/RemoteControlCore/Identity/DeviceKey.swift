import Foundation
import CryptoKit

public enum DeviceKeyError: Error, LocalizedError {
    case malformedPrivateKey(String)

    public var errorDescription: String? {
        switch self {
        case .malformedPrivateKey(let reason):
            return "The stored device private key could not be decoded: \(reason)"
        }
    }
}

public final class DeviceKey {

    private let privateKey: P256.Signing.PrivateKey

    public init() {
        self.privateKey = P256.Signing.PrivateKey()
    }

    init(privateKey: P256.Signing.PrivateKey) {
        self.privateKey = privateKey
    }

    public init(rawPrivateKey: Data) throws {
        do {
            self.privateKey = try P256.Signing.PrivateKey(rawRepresentation: rawPrivateKey)
        } catch {
            throw DeviceKeyError.malformedPrivateKey(error.localizedDescription)
        }
    }

    var rawPrivateKey: Data { privateKey.rawRepresentation }

    // MARK: - Public half

    public func publicKeyRepresentation() throws -> Data {
        privateKey.publicKey.x963Representation
    }

    public func publicKeyHex() throws -> String {
        try publicKeyRepresentation().map { String(format: "%02x", $0) }.joined()
    }

    public func publicKeyDER() throws -> Data {
        privateKey.publicKey.derRepresentation
    }

    public func publicKeyBase64() throws -> String {
        try publicKeyDER().base64EncodedString()
    }

    // MARK: - Signing

    @_spi(DeviceSigning)
    public func sign(_ message: Data) throws -> Data {
        try privateKey.signature(for: message).derRepresentation
    }

    public func verify(_ signature: Data, for message: Data) -> Bool {
        guard let parsed = try? P256.Signing.ECDSASignature(derRepresentation: signature) else { return false }
        return privateKey.publicKey.isValidSignature(parsed, for: message)
    }
}
