import Foundation
import RCTestKit
import RemoteControlCore
import SkipperCore

/// Signed DTLS fingerprints (PROTOCOL.md §2.12), driven the way the coordinator
/// drives them: the core builds the bytes, a real `DeviceSigningKey` signs them,
/// the core verifies.
///
/// The rules are proven in `core/crates/rc-identity`; these cases exist to prove
/// the FFI path carries them, and that a Keychain-backed key — which may be a
/// Secure Enclave key in a signed build — produces a signature the core accepts.

private let sdpOffer = """
v=0\r
o=- 8175905011317297321 2 IN IP4 127.0.0.1\r
s=-\r
t=0 0\r
m=application 9 UDP/DTLS/SCTP webrtc-datachannel\r
a=ice-ufrag:4ZcD\r
a=fingerprint:sha-256 7B:8C:1D:4F:2A:90:33:AE:BB:01:5C:6D:77:E8:99:0A:1B:2C:3D:4E:5F:60:71:82:93:A4:B5:C6:D7:E8:F9:0A\r
a=setup:actpass\r
a=mid:0\r

"""

private let sessionID = "8c7f1a2b3c4d5e6f708192a3b4c5d6e7"

@MainActor
private func sign(_ key: DeviceSigningKey, sdpType: String, sdp: String) throws -> SdpSignature {
    let signable = try SdpAuth.signable(sessionID: sessionID, sdpType: sdpType, sdp: sdp)
    return SdpSignature(fingerprints: signable.fingerprints,
                        pubkey: key.publicKeyBase64,
                        signature: try key.signatureBase64(for: signable.message))
}

public let sdpAuthSuite = TestSuite("SdpAuth", [

    TestCase("a Keychain-backed key signs an offer the core then verifies") {
        let key = try KeychainDeviceKey.create(in: InMemoryDeviceKeyStore())
        let signature = try sign(key, sdpType: "offer", sdp: sdpOffer)

        try expectEqual(signature.fingerprints, try SdpAuth.fingerprints(in: sdpOffer))
        try expect(signature.fingerprints.hasPrefix("sha-256 7B:8C:"),
                   "the signed value is the fingerprint attribute itself")

        try SdpAuth.verify(sessionID: sessionID, sdpType: "offer", sdp: sdpOffer,
                           signature: signature, expectedPubkey: key.publicKeyBase64)
    },

    TestCase("a fingerprint swapped in transit is refused") {
        let key = try KeychainDeviceKey.create(in: InMemoryDeviceKeyStore())
        let signature = try sign(key, sdpType: "offer", sdp: sdpOffer)
        let tampered = sdpOffer.replacingOccurrences(of: "7B:8C", with: "7B:8D")

        try await expectThrows("the fingerprint check") {
            try SdpAuth.verify(sessionID: sessionID, sdpType: "offer", sdp: tampered,
                               signature: signature, expectedPubkey: key.publicKeyBase64)
        }
    },

    TestCase("a signature by any key but the expected peer's is refused") {
        let relay = try KeychainDeviceKey.create(in: InMemoryDeviceKeyStore())
        let peer = try KeychainDeviceKey.create(in: InMemoryDeviceKeyStore())
        let tampered = sdpOffer.replacingOccurrences(of: "7B:8C", with: "7B:8D")
        let signature = try sign(relay, sdpType: "offer", sdp: tampered)

        try await expectThrows("the expected-peer check") {
            try SdpAuth.verify(sessionID: sessionID, sdpType: "offer", sdp: tampered,
                               signature: signature, expectedPubkey: peer.publicKeyBase64)
        }
    },
])
