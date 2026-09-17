import Foundation
import CryptoKit
import RCTestKit
@_spi(DeviceSigning) import RemoteControlCore
import SkipperCore

public let deviceKeySuite = TestSuite("DeviceKey", [

    TestCase("a fresh key has a well-formed public half") {
        let key = DeviceKey()
        let x963 = try key.publicKeyRepresentation()
        try expectEqual(x963.count, 65)
        try expectEqual(x963.first, 0x04)

        let hex = try key.publicKeyHex()
        try expectEqual(hex.count, 130)
        try expect(hex.allSatisfy { $0.isHexDigit && !$0.isUppercase })
    },

    TestCase("two keys are different") {
        try expectNotEqual(
            try DeviceKey().publicKeyRepresentation(),
            try DeviceKey().publicKeyRepresentation()
        )
    },

    TestCase("a signature verifies, and a signature over different data does not") {
        let key = DeviceKey()
        let message = Data("nonce-from-the-signaling-server".utf8)
        let other = Data("a different nonce".utf8)

        let signature = try key.sign(message)
        try expectFalse(signature.isEmpty)
        try expect(key.verify(signature, for: message),
                   "a signature must verify against the message it was made over")
        try expectFalse(key.verify(signature, for: other),
                        "a signature must NOT verify against different data")

        try expectFalse(key.verify(try key.sign(other), for: message),
                        "signatures must be bound to their message")

        try expectFalse(key.verify(try DeviceKey().sign(message), for: message),
                        "a signature from another key must be rejected")

        var tampered = signature
        tampered[tampered.count - 1] ^= 0x01
        try expectFalse(key.verify(tampered, for: message), "a tampered signature must be rejected")
    },

    TestCase("ECDSA is randomised: the same message signs differently each time") {
        let key = DeviceKey()
        let message = Data("same-nonce".utf8)
        let a = try key.sign(message)
        let b = try key.sign(message)
        try expectNotEqual(a, b, "a constant signature would mean a broken or stubbed signer")
        try expect(key.verify(a, for: message))
        try expect(key.verify(b, for: message))
    },

    // MARK: - Wire format, verified structurally against what Go parses.

    TestCase("the public key is DER SPKI and re-parses as a P-256 key") {
        let key = DeviceKey()
        let der = try key.publicKeyDER()

        try expectEqual(der.count, 91)
        try expectEqual(der.first, 0x30)
        let prime256v1 = Data([0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x03, 0x01, 0x07])
        try expect(der.range(of: prime256v1) != nil, "the SPKI must name the prime256v1 curve")

        let reparsed = try P256.Signing.PublicKey(derRepresentation: der)
        try expectEqual(reparsed.x963Representation, try key.publicKeyRepresentation())

        let b64 = try key.publicKeyBase64()
        try expectEqual(Data(base64Encoded: b64), der)
        try expect(b64.hasSuffix("="), "P-256 SPKI is 91 bytes, so std base64 is padded")
    },

    TestCase("the signature is ASN.1 DER, not raw r||s") {
        let key = DeviceKey()
        let message = Data("nonce".utf8)
        for _ in 0..<50 {
            let sig = try key.sign(message)
            try expectEqual(sig.first, 0x30, "DER SEQUENCE tag")
            try expectEqual(Int(sig[1]), sig.count - 2, "the DER length must match the payload")
            try expectEqual(sig[2], 0x02, "the first element must be an INTEGER (r)")
            try expectNotEqual(sig.count, 64, "64 bytes would mean raw r||s, which Go would reject")
            try expect(sig.count >= 68 && sig.count <= 72, "unexpected DER length \(sig.count)")

            _ = try P256.Signing.ECDSASignature(derRepresentation: sig)
        }
    },

    TestCase("sign() hashes with SHA-256 over the raw message bytes") {
        let key = DeviceKey()
        let nonce = try SecureRandom.data(32)
        let signature = try key.sign(nonce)
        let parsed = try P256.Signing.ECDSASignature(derRepresentation: signature)

        let publicKey = try P256.Signing.PublicKey(derRepresentation: try key.publicKeyDER())
        try expect(publicKey.isValidSignature(parsed, for: nonce),
                   "must verify over the raw nonce bytes")
        try expectFalse(
            publicKey.isValidSignature(parsed, for: Data(nonce.base64EncodedString().utf8)),
            "must NOT be a signature over the base64 text of the nonce"
        )
    },

    TestCase("a key restored from its stored bytes is the same key") {
        let original = DeviceKey()
        let record = IdentityRecord(
            deviceID: "482719351",
            accessCode: try AccessCode.generate(),
            key: original,
            createdAt: Date()
        )
        let stored = try expectNotNil(record.privateKeyBase64)
        let raw = try expectNotNil(Data(base64Encoded: stored))
        try expectEqual(raw.count, 32, "a P-256 scalar is 32 bytes")

        let restored = try DeviceKey(rawPrivateKey: raw)
        try expectEqual(try restored.publicKeyRepresentation(), try original.publicKeyRepresentation())
        try expect(original.verify(try restored.sign(Data("x".utf8)), for: Data("x".utf8)))
    },
])
