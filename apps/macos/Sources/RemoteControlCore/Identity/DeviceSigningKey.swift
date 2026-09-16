import Foundation
import CryptoKit

/// Where the device private key physically lives.
///
/// Ordered by how well the key is protected: the Secure Enclave never lets the
/// private half leave the chip, the Keychain keeps it encrypted at rest under
/// the app's own ACL, and a file is owner-only permissions plus FileVault.
public enum DeviceKeyStorage: Equatable, CustomStringConvertible {

    case secureEnclave
    case keychain
    case file(URL)

    /// The user-facing footer text. State only, no jargon.
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
        case .keychain: return "Software key in the login Keychain, unlocked after first unlock, this device only"
        case .file: return "Software key in an owner-only file (0600)"
        }
    }

    /// The value written to `identity.json` so the next launch knows where to
    /// look without probing every backend.
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

/// The only thing the rest of the app is allowed to do with the device key.
///
/// Both halves of the wire contract live here and are identical for every
/// backend: the public key is DER SPKI (what `auth.ParsePubkey` feeds to
/// `x509.ParsePKIXPublicKey`) and a signature is ASN.1 DER ECDSA P-256 over
/// SHA-256 of the raw message (what `auth.VerifyDeviceSig` feeds to
/// `ecdsa.VerifyASN1`). A Secure Enclave key and a software key are therefore
/// interchangeable on the wire.
public protocol DeviceSigningKey: AnyObject {
    var publicKeyDER: Data { get }
    func sign(_ data: Data) throws -> Data
    var storage: DeviceKeyStorage { get }
}

extension DeviceSigningKey {

    /// Base64 (standard, padded) of the DER SPKI public key — the `pubkey` field.
    public var publicKeyBase64: String { publicKeyDER.base64EncodedString() }

    /// X9.63 uncompressed point, 65 bytes. Display and comparison only.
    public var publicKeyX963: Data {
        (try? P256.Signing.PublicKey(derRepresentation: publicKeyDER).x963Representation) ?? Data()
    }

    public var publicKeyHex: String {
        publicKeyX963.map { String(format: "%02x", $0) }.joined()
    }

    public func signatureBase64(for message: Data) throws -> String {
        try sign(message).base64EncodedString()
    }

    /// Local verification. Used by the tests; the app never checks its own work.
    public func verify(_ signature: Data, for message: Data) -> Bool {
        guard let publicKey = try? P256.Signing.PublicKey(derRepresentation: publicKeyDER),
              let parsed = try? P256.Signing.ECDSASignature(derRepresentation: signature) else { return false }
        return publicKey.isValidSignature(parsed, for: message)
    }
}

/// The dev-only backend: the software key persisted inside `identity.json`.
///
/// Reachable only through `SKIPPER_DEV_FILE_IDENTITY=1` or an overridden
/// identity directory (`RC_IDENTITY_DIR`), because several instances on one Mac
/// cannot share the single Keychain slot. Never selected in a release path.
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
