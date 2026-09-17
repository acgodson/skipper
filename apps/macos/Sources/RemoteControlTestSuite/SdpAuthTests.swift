import CryptoKit
import Foundation
import RCTestKit
import RemoteControlCore
import SkipperCore

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
private let deviceID = "482719351"

extension KeychainDeviceKey: DeviceMessageSigner {}

private struct Exchange {
    let controller: PakeExchange
    let host: PakeExchange
}

private func completedExchange() throws -> Exchange {
    let code = try AccessCode.generate()
    let pubkey = P256.Signing.PrivateKey().publicKey.derRepresentation.base64EncodedString()
    let controller = try PakeExchange.controller(accessCode: code, deviceID: deviceID,
                                                 sessionID: sessionID, ownPublicKey: pubkey)
    let host = try PakeExchange.host(accessCode: code, deviceID: deviceID,
                                     sessionID: sessionID, ownPublicKey: pubkey)
    let step1 = try controller.step(nil)
    let step2 = try host.step(step1)
    let step3 = try controller.step(step2)
    _ = try host.step(step3)
    guard controller.isComplete, host.isComplete else {
        throw TestFailure(message: "the exchange did not complete")
    }
    return Exchange(controller: controller, host: host)
}

@MainActor
private func sign(_ key: KeychainDeviceKey, _ pake: PakeExchange,
                  sdpType: String, sdp: String) throws -> SdpSignature {
    try SdpAuth.sign(pake: pake, sessionID: sessionID, sdpType: sdpType, sdp: sdp,
                     with: key, pubkey: key.publicKeyBase64)
}

@MainActor
private func offer(from peer: PeerSession) async throws -> String {
    try peer.start()
    return try await peer.createOffer(restart: false).sdp
}

public let sdpAuthSuite = TestSuite("SdpAuth", [

    TestCase("a Keychain-backed key signs an offer the core then verifies") {
        let key = try KeychainDeviceKey.create(in: InMemoryDeviceKeyStore())
        let exchange = try completedExchange()
        let signature = try sign(key, exchange.controller, sdpType: "offer", sdp: sdpOffer)

        try expectEqual(signature.fingerprints, try SdpAuth.fingerprints(in: sdpOffer))
        try expect(signature.fingerprints.hasPrefix("sha-256 7B:8C:"),
                   "the signed value is the fingerprint attribute itself")

        try SdpAuth.verify(pake: exchange.host, sessionID: sessionID, sdpType: "offer",
                           sdp: sdpOffer, signature: signature, expectedPubkey: key.publicKeyBase64)
    },

    TestCase("a fingerprint swapped in transit is refused") {
        let key = try KeychainDeviceKey.create(in: InMemoryDeviceKeyStore())
        let exchange = try completedExchange()
        let signature = try sign(key, exchange.controller, sdpType: "offer", sdp: sdpOffer)
        let tampered = sdpOffer.replacingOccurrences(of: "7B:8C", with: "7B:8D")

        try await expectThrows("the fingerprint check") {
            try SdpAuth.verify(pake: exchange.host, sessionID: sessionID, sdpType: "offer",
                               sdp: tampered, signature: signature,
                               expectedPubkey: key.publicKeyBase64)
        }
    },

    TestCase("a signature by any key but the expected peer's is refused") {
        let relay = try KeychainDeviceKey.create(in: InMemoryDeviceKeyStore())
        let peer = try KeychainDeviceKey.create(in: InMemoryDeviceKeyStore())
        let exchange = try completedExchange()
        let tampered = sdpOffer.replacingOccurrences(of: "7B:8C", with: "7B:8D")
        let signature = try sign(relay, exchange.controller, sdpType: "offer", sdp: tampered)

        try await expectThrows("the expected-peer check") {
            try SdpAuth.verify(pake: exchange.host, sessionID: sessionID, sdpType: "offer",
                               sdp: tampered, signature: signature,
                               expectedPubkey: peer.publicKeyBase64)
        }
    },

    TestCase("a genuine signature relayed into another exchange fails its MAC") {
        let key = try KeychainDeviceKey.create(in: InMemoryDeviceKeyStore())
        let ours = try completedExchange()
        let theirs = try completedExchange()
        let signature = try sign(key, ours.controller, sdpType: "offer", sdp: sdpOffer)

        try await expectThrows("the MAC check") {
            try SdpAuth.verify(pake: theirs.host, sessionID: sessionID, sdpType: "offer",
                               sdp: sdpOffer, signature: signature,
                               expectedPubkey: key.publicKeyBase64)
        }
    },

    TestCase("an SDP with a NUL or a lone CR is refused before it reaches the core") {
        let key = try KeychainDeviceKey.create(in: InMemoryDeviceKeyStore())
        let exchange = try completedExchange()
        let signature = try sign(key, exchange.controller, sdpType: "offer", sdp: sdpOffer)
        let padded = "v=0\r\n" + signature.fingerprints.split(separator: "\n")
            .map { "a=fingerprint:\($0)\r\n" }.joined() + "a=x-pad:\u{0}\r\n"
            + sdpOffer.dropFirst("v=0\r\n".count).replacingOccurrences(of: "7B:8C", with: "00:11")
        let loneCR = sdpOffer.replacingOccurrences(of: "a=mid:0\r\n", with: "a=mid:0\ra=fingerprint:sha-256 00:11\r\n")

        for hostile in [padded, loneCR] {
            try await expectThrows("the well-formedness check") {
                try SdpAuth.requireWellFormed(hostile)
            }
            try await expectThrows("verification of a malformed SDP") {
                try SdpAuth.verify(pake: exchange.host, sessionID: sessionID, sdpType: "offer",
                                   sdp: hostile, signature: signature,
                                   expectedPubkey: key.publicKeyBase64)
            }
        }
    },

    TestCase("a handshake nonce must be exactly 32 bytes") {
        let key = try KeychainDeviceKey.create(in: InMemoryDeviceKeyStore())
        _ = try key.signatureBase64(purpose: .hello, nonce: Data(repeating: 1, count: 32))
        let forged = Data("skipperdesk/sdp/v1|\(sessionID)|answer|sha-256 00:11".utf8)
        for nonce in [Data(repeating: 1, count: 31), Data(repeating: 1, count: 33), forged] {
            try await expectThrows("a \(nonce.count)-byte nonce") {
                _ = try key.signatureBase64(purpose: .register, nonce: nonce)
            }
        }
    },

    TestCase("libwebrtc's installed fingerprints must equal the verified ones") {
        let genuine = PeerSession(iceServers: [], isOfferer: true)
        let relay = PeerSession(iceServers: [], isOfferer: true)
        defer { genuine.close(); relay.close() }
        let genuineOffer = try await offer(from: genuine)
        let relayOffer = try await offer(from: relay)
        let verified = try SdpAuth.fingerprints(in: genuineOffer)
        try expectNotEqual(verified, try SdpAuth.fingerprints(in: relayOffer),
                           "two peer connections hold two DTLS certificates")

        let honest = PeerSession(iceServers: [], isOfferer: false)
        defer { honest.close() }
        try honest.start()
        try await honest.setRemoteDescription(type: "offer", sdp: genuineOffer,
                                              verifiedFingerprints: verified)
        try expectEqual(try SdpAuth.fingerprints(in: try expectNotNil(honest.installedRemoteSDP)),
                        verified, "libwebrtc re-serialises the fingerprint it verified unchanged")

        let fooled = PeerSession(iceServers: [], isOfferer: false)
        defer { fooled.close() }
        try fooled.start()
        do {
            try await fooled.setRemoteDescription(type: "offer", sdp: relayOffer,
                                                  verifiedFingerprints: verified)
            throw TestFailure(message: "an installed fingerprint that was never verified was accepted")
        } catch PeerSessionError.installedFingerprintsRejected {
            try expectNil(fooled.installedRemoteSDP, "the peer connection was closed at once")
        }
    },
])
