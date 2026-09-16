import CSkipperCore
import Foundation

/// The three fields a `sdp` message carries besides the SDP itself
/// (PROTOCOL.md §2.12): the fingerprints that were signed, the device key that
/// signed them, and the signature.
public struct SdpSignature: Equatable, Sendable {
    public let fingerprints: String
    public let pubkey: String
    public let signature: String

    public init(fingerprints: String, pubkey: String, signature: String) {
        self.fingerprints = fingerprints
        self.pubkey = pubkey
        self.signature = signature
    }
}

/// Signed DTLS fingerprints, over the shared core.
///
/// The server relays `sdp`, so a compromised one could swap the fingerprint and
/// sit inside the DTLS handshake. Signing the fingerprint with the device key
/// closes that; this type is the Swift half of it.
///
/// The signing itself is **not** here, and cannot be: the device key may live in
/// the Secure Enclave, where only the platform can reach it. The core hands out
/// the bytes to sign (`signable`) and does every check on the way back in
/// (`verify`).
public enum SdpAuth {

    /// What one outgoing `sdp` needs before it can be sent.
    public struct Signable: Equatable, Sendable {
        /// The wire `fp` field.
        public let fingerprints: String
        /// The bytes the device key signs.
        public let message: Data
    }

    private struct FingerprintResult: Decodable {
        let fp: String
    }

    private struct SigningResult: Decodable {
        let fp: String
        let message: String
    }

    private struct VerifyResult: Decodable {
        let verified: Bool
    }

    /// Every `a=fingerprint` value in `sdp`, de-duplicated, sorted and joined
    /// with a newline.
    public static func fingerprints(in sdp: String) throws -> String {
        let result: FingerprintResult = try CoreBoundary.call { skipper_sdp_fingerprints(sdp) }
        return result.fp
    }

    public static func signable(sessionID: String, sdpType: String, sdp: String) throws -> Signable {
        let result: SigningResult = try CoreBoundary.call {
            skipper_sdp_signing_message(sessionID, sdpType, sdp)
        }
        guard let message = Data(base64Encoded: result.message) else {
            throw SkipperCoreError("the shared core returned an undecodable signing message")
        }
        return Signable(fingerprints: result.fp, message: message)
    }

    /// Throws unless the signature verifies, the fingerprints are the ones in
    /// `sdp`, and `pubkey` is `expectedPubkey`. A nil or empty `expectedPubkey`
    /// means this side has not learned the peer's key yet, and only the first
    /// two checks are made.
    public static func verify(
        sessionID: String,
        sdpType: String,
        sdp: String,
        signature: SdpSignature,
        expectedPubkey: String?
    ) throws {
        let result: VerifyResult = try CoreBoundary.call {
            skipper_sdp_verify(sessionID, sdpType, sdp, signature.fingerprints,
                               signature.pubkey, signature.signature, expectedPubkey)
        }
        guard result.verified else {
            throw SkipperCoreError("the shared core did not verify the SDP signature")
        }
    }
}
