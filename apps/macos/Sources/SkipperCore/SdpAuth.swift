import CSkipperCore
import Foundation

/// The fingerprints that were signed, the device key that signed them, and the resulting signature.
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

public enum SdpAuth {

    public struct Signable: Equatable, Sendable {
        public let fingerprints: String
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
