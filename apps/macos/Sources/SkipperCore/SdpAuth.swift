import CSkipperCore
import Foundation

/// The fingerprints that were signed, the device key that signed them, the
/// signature, and the MAC under the session's access-code exchange.
public struct SdpSignature: Equatable, Sendable {
    public let fingerprints: String
    public let pubkey: String
    public let signature: String
    public let mac: String

    public init(fingerprints: String, pubkey: String, signature: String, mac: String) {
        self.fingerprints = fingerprints
        self.pubkey = pubkey
        self.signature = signature
        self.mac = mac
    }
}

public enum SdpAuth {

    public struct Signable: Equatable, Sendable {
        public let fingerprints: String
        public let message: SigningMessage
        public let mac: String
    }

    private struct FingerprintResult: Decodable {
        let fp: String
    }

    private struct SigningResult: Decodable {
        let fp: String
        let message: String
        let mac: String
    }

    private struct VerifyResult: Decodable {
        let verified: Bool
    }

    /// A NUL, or a CR that does not start CRLF, is where SDP parsers disagree.
    public static func requireWellFormed(_ sdp: String) throws {
        let bytes = Array(sdp.utf8)
        for (index, byte) in bytes.enumerated() {
            let loneCarriageReturn = byte == 0x0D && (index + 1 == bytes.count || bytes[index + 1] != 0x0A)
            if byte == 0 || loneCarriageReturn {
                throw SkipperCoreError("the SDP contains a NUL byte or a carriage return that does not end a line")
            }
        }
    }

    public static func fingerprints(in sdp: String) throws -> String {
        try requireWellFormed(sdp)
        let result: FingerprintResult = try CoreBoundary.withText([sdp]) { text in
            Result { try CoreBoundary.call { skipper_sdp_fingerprints(text[0].base, text[0].count) } }
        }.get()
        return result.fp
    }

    public static func signable(pake: PakeExchange, sessionID: String, sdpType: String,
                                sdp: String) throws -> Signable {
        try requireWellFormed(sdp)
        let result: SigningResult = try CoreBoundary.withText([sessionID, sdpType, sdp]) { text in
            Result {
                try CoreBoundary.call {
                    skipper_sdp_signing_message(pake.handle, text[0].base, text[0].count,
                                                text[1].base, text[1].count,
                                                text[2].base, text[2].count)
                }
            }
        }.get()
        guard let message = Data(base64Encoded: result.message) else {
            throw SkipperCoreError("the shared core returned an undecodable signing message")
        }
        return Signable(fingerprints: result.fp, message: SigningMessage(bytes: message), mac: result.mac)
    }

    @MainActor
    public static func sign(pake: PakeExchange, sessionID: String, sdpType: String, sdp: String,
                            with key: DeviceMessageSigner, pubkey: String) throws -> SdpSignature {
        let signable = try signable(pake: pake, sessionID: sessionID, sdpType: sdpType, sdp: sdp)
        return SdpSignature(fingerprints: signable.fingerprints, pubkey: pubkey,
                            signature: try key.signatureBase64(for: signable.message),
                            mac: signable.mac)
    }

    public static func verify(
        pake: PakeExchange,
        sessionID: String,
        sdpType: String,
        sdp: String,
        signature: SdpSignature,
        expectedPubkey: String?
    ) throws {
        try requireWellFormed(sdp)
        let arguments = [sessionID, sdpType, sdp, signature.fingerprints, signature.pubkey,
                         signature.signature, signature.mac, expectedPubkey]
        let result: VerifyResult = try CoreBoundary.withText(arguments) { t in
            Result {
                try CoreBoundary.call {
                    skipper_sdp_verify(pake.handle, t[0].base, t[0].count, t[1].base, t[1].count,
                                       t[2].base, t[2].count, t[3].base, t[3].count,
                                       t[4].base, t[4].count, t[5].base, t[5].count,
                                       t[6].base, t[6].count, t[7].base, t[7].count)
                }
            }
        }.get()
        guard result.verified else {
            throw SkipperCoreError("the shared core did not verify the SDP signature")
        }
    }

    /// After `setRemoteDescription`: the fingerprints libwebrtc actually
    /// installed must be exactly the ones that were verified.
    public static func requireInstalled(verified fingerprints: String, installedSDP: String?) throws {
        guard let installedSDP else {
            throw SkipperCoreError("the peer connection reports no remote description")
        }
        let installed = try SdpAuth.fingerprints(in: installedSDP)
        guard installed == fingerprints else {
            throw SkipperCoreError("the fingerprints the peer connection installed are not the ones that were verified")
        }
    }
}
