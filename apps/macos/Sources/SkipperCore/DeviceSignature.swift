import CSkipperCore
import Foundation

/// What a device-key signature is for (PROTOCOL.md §3.1). The sdp purpose is
/// not here: its message is built only by `SdpAuth.signable`.
public enum SigningPurpose: Sendable {
    case hello
    case register
    case apiChallenge

    var code: Int32 {
        switch self {
        case .hello: return Int32(SKIPPER_SIGN_HELLO)
        case .register: return Int32(SKIPPER_SIGN_REGISTER)
        case .apiChallenge: return Int32(SKIPPER_SIGN_API_CHALLENGE)
        }
    }
}

/// The one spelling of a device key: base64 of the DER SPKI of a P-256 point.
/// Counters are stored under it, and a key that arrives spelled any other way
/// is refused.
public enum DevicePublicKey {

    private struct Result: Decodable {
        let key: String
        let canonical: Bool
    }

    public static func canonical(_ pubkey: String) throws -> String {
        try parse(pubkey).key
    }

    public static func isCanonical(_ pubkey: String) -> Bool {
        (try? parse(pubkey))?.canonical == true
    }

    /// Whether two spellings name the same device key; a value that is not a
    /// device key matches nothing.
    public static func same(_ first: String?, _ second: String?) -> Bool {
        guard let first, let second, let key = try? canonical(first) else { return false }
        return (try? canonical(second)) == key
    }

    /// Four groups of four hex digits of SHA-256 over the key, for a person
    /// to compare between two Macs.
    public static func fingerprint(_ pubkey: String) throws -> String {
        let result: FingerprintResult = try CoreBoundary.withText([pubkey]) { text in
            Swift.Result { try CoreBoundary.call { skipper_pubkey_fingerprint(text[0].base, text[0].count) } }
        }.get()
        return result.fingerprint
    }

    /// The one spelling of a fingerprint the app shows about *another* Mac, so
    /// the consent prompt and the trusted-controllers row always read alike.
    public static func fingerprintLine(_ fingerprint: String) -> String {
        "Fingerprint \(fingerprint)"
    }

    private struct FingerprintResult: Decodable {
        let fingerprint: String
    }

    private static func parse(_ pubkey: String) throws -> Result {
        try CoreBoundary.withText([pubkey]) { text in
            Swift.Result { try CoreBoundary.call { skipper_pubkey_canonical(text[0].base, text[0].count) } }
        }.get()
    }
}

/// Bytes the shared core built for a device key to sign. Only the core can
/// produce one, so no caller can have arbitrary bytes signed.
public struct SigningMessage: Equatable, Sendable {
    let bytes: Data

    init(bytes: Data) {
        self.bytes = bytes
    }

    public static func nonce(_ purpose: SigningPurpose, _ nonce: Data) throws -> SigningMessage {
        let result: MessageResult = try CoreBoundary.withBytes([nonce]) { payload in
            Result {
                try CoreBoundary.call {
                    skipper_signing_message(purpose.code, payload[0].base, payload[0].count)
                }
            }
        }.get()
        guard let bytes = Data(base64Encoded: result.message) else {
            throw SkipperCoreError("the shared core returned an undecodable signing message")
        }
        return SigningMessage(bytes: bytes)
    }

    private struct MessageResult: Decodable {
        let message: String
    }
}

/// The platform's device key: whatever signs raw bytes with ECDSA-P256/SHA-256
/// and returns ASN.1 DER. Callers go through `signatureBase64(for:)`.
@MainActor
public protocol DeviceMessageSigner {
    func sign(_ message: Data) throws -> Data
}

extension DeviceMessageSigner {
    public func signatureBase64(for message: SigningMessage) throws -> String {
        try sign(message.bytes).base64EncodedString()
    }

    /// `nonce` is the challenge's raw bytes; anything but 32 bytes is refused.
    public func signatureBase64(purpose: SigningPurpose, nonce: Data) throws -> String {
        try signatureBase64(for: SigningMessage.nonce(purpose, nonce))
    }
}
