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
