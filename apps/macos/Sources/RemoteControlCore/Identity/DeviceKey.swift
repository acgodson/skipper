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

/// The device's P-256 identity keypair.
///
/// CryptoKit, not Security.framework: there are no Keychain calls anywhere in
/// this type, which is what stops macOS asking the user for permission on every
/// rebuild of an ad-hoc signed binary. The private half is persisted by
/// `IdentityFileStore` into an owner-only file.
///
/// The private half is never returned by any *public* API, never printed, never
/// logged and never rendered. The only public operations are "give me the public
/// key" and "sign this" — everything the Phase 3 handshake needs.
public final class DeviceKey {

    private let privateKey: P256.Signing.PrivateKey

    public init() {
        self.privateKey = P256.Signing.PrivateKey()
    }

    init(privateKey: P256.Signing.PrivateKey) {
        self.privateKey = privateKey
    }

    /// Restores a key from its 32-byte scalar — the inverse of persistence.
    ///
    /// Public because the identity-file loader and the tests both need it, and
    /// because reconstructing a key from bytes the caller already holds leaks
    /// nothing. The one-way direction is what stays sealed: `rawPrivateKey`
    /// below is module-internal, so no caller outside RemoteControlCore can get
    /// the private bytes *out* of a key.
    public init(rawPrivateKey: Data) throws {
        do {
            self.privateKey = try P256.Signing.PrivateKey(rawRepresentation: rawPrivateKey)
        } catch {
            throw DeviceKeyError.malformedPrivateKey(error.localizedDescription)
        }
    }

    /// Module-internal: the persistence layer needs these bytes to write the
    /// identity file, and nothing else in the app can reach them.
    var rawPrivateKey: Data { privateKey.rawRepresentation }

    // MARK: - Public half

    /// X9.63 uncompressed point, 65 bytes (`0x04 || X || Y`).
    ///
    /// This is the *local* representation, used for display and for comparing
    /// two keys. The wire format the signaling server expects is
    /// `publicKeyBase64()` — see the note on that method.
    public func publicKeyRepresentation() throws -> Data {
        privateKey.publicKey.x963Representation
    }

    /// Lowercase hex of the X9.63 point, 130 characters. Display only.
    public func publicKeyHex() throws -> String {
        try publicKeyRepresentation().map { String(format: "%02x", $0) }.joined()
    }

    /// DER SPKI (SubjectPublicKeyInfo) encoding of the public key.
    ///
    /// WIRE FORMAT — must match the Go server exactly. `auth.ParsePubkey` does
    /// `x509.ParsePKIXPublicKey(base64Decode(pubkey))`, i.e. DER SPKI, and
    /// PROTOCOL.md §Keys says "base64 (std, padded) of the DER SPKI encoding".
    /// The X9.63 raw point above would NOT parse there.
    public func publicKeyDER() throws -> Data {
        privateKey.publicKey.derRepresentation
    }

    /// Base64 (standard, padded) of the DER SPKI public key — the exact string
    /// that goes into the `pubkey` field of `hello` / `register`.
    public func publicKeyBase64() throws -> String {
        try publicKeyDER().base64EncodedString()
    }

    // MARK: - Signing

    /// ECDSA-SHA256 over `message`, returned in **ASN.1 DER**.
    ///
    /// WIRE FORMAT — must match the Go server exactly. `auth.VerifyDeviceSig`
    /// calls `ecdsa.VerifyASN1(pub, sha256(nonce), sig)`, which requires DER,
    /// not the raw `r || s` pair. CryptoKit's `signature(for:)` performs the
    /// SHA-256 itself, so `message` is the raw nonce bytes, exactly as
    /// PROTOCOL.md §7 specifies ("signs the raw nonce bytes, not the base64 text").
    public func sign(_ message: Data) throws -> Data {
        try privateKey.signature(for: message).derRepresentation
    }

    /// Base64 of the DER signature — the `sig` field on the wire.
    public func signatureBase64(for message: Data) throws -> String {
        try sign(message).base64EncodedString()
    }

    /// Local verification, used by the tests and by nothing in the app itself.
    public func verify(_ signature: Data, for message: Data) -> Bool {
        guard let parsed = try? P256.Signing.ECDSASignature(derRepresentation: signature) else { return false }
        return privateKey.publicKey.isValidSignature(parsed, for: message)
    }
}

/// Where the device private key physically lives.
///
/// There is exactly one case now. It stays an enum rather than becoming a bare
/// string so that adding hardware backing later (which needs a paid Apple
/// Developer account and a provisioning profile we do not have) is an additive
/// change rather than a refactor of every call site.
public enum DeviceKeyStorage: Equatable, CustomStringConvertible {

    /// A software key in an owner-only (0600) file inside the app's Application
    /// Support directory.
    case file(URL)

    /// Deliberately modest wording. This is file permissions plus FileVault at
    /// rest — it is not hardware-backed and the UI must not suggest it is.
    public var description: String {
        switch self {
        case .file: return "Software key in an owner-only file (0600)"
        }
    }

    public var path: String {
        switch self {
        case .file(let url): return url.path
        }
    }

    /// Path with `$HOME` abbreviated, for display in a narrow label.
    public var displayPath: String {
        (path as NSString).abbreviatingWithTildeInPath
    }
}
