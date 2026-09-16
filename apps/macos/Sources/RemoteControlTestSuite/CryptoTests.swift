import Foundation
import RCTestKit
import RemoteControlCore

private func hex(_ bytes: [UInt8]) -> String {
    bytes.map { String(format: "%02x", $0) }.joined()
}

private func unhex(_ s: String) -> [UInt8] {
    var out = [UInt8]()
    var i = s.startIndex
    while i < s.endIndex {
        let j = s.index(i, offsetBy: 2)
        out.append(UInt8(s[i..<j], radix: 16)!)
        i = j
    }
    return out
}

public let cryptoSuite = TestSuite("Crypto (BLAKE2b + Argon2id)", [

    // RFC 7693 Appendix A: the only published BLAKE2b-512 test vector.
    TestCase("blake2b-512 matches the RFC 7693 vector for \"abc\"") {
        let digest = Blake2b.hash([UInt8]("abc".utf8), digestLength: 64)
        try expectEqual(hex(digest),
            "ba80a53f981c4d0d6a2797b69f12f6e94c212f14685ac4b74b12bb6fdbffa2d1"
            + "7d87c5392aab792dc252d5de4533cc9518d38aa8dbf1925ab92386edd4009923")
    },

    TestCase("blake2b of the empty string, 512-bit") {
        let digest = Blake2b.hash([], digestLength: 64)
        try expectEqual(hex(digest),
            "786a02f742015903c6c6fd852552d272912f4740e15847618a86e217f71f5419"
            + "d25e1031afee585313896444934eb04b903a685b1448b755d56f701afe9be2ce")
    },

    // A truncated digest must not simply be a prefix of the 512-bit one: the
    // output length is mixed into the parameter block. This catches an
    // implementation that ignores `digestLength` during initialisation.
    TestCase("blake2b digest length is domain-separating, not a truncation") {
        let short = Blake2b.hash([UInt8]("abc".utf8), digestLength: 32)
        let long = Blake2b.hash([UInt8]("abc".utf8), digestLength: 64)
        try expectEqual(short.count, 32)
        try expectNotEqual(hex(short), hex(Array(long.prefix(32))))
    },

    // Streaming and one-shot must agree, and the block boundary at 128 bytes is
    // where a naive implementation breaks.
    TestCase("blake2b streaming across the 128-byte block boundary agrees with one-shot") {
        let message = (0..<300).map { UInt8($0 % 251) }
        var streamed = Blake2b(digestLength: 64)
        streamed.update(Array(message[0..<7]))
        streamed.update(Array(message[7..<128]))
        streamed.update(Array(message[128..<129]))
        streamed.update(Array(message[129..<300]))
        try expectEqual(hex(streamed.finalize()), hex(Blake2b.hash(message, digestLength: 64)))
    },

    // RFC 9106 §5.3 — the normative Argon2id vector, with a secret and
    // associated data. Nothing but a correct implementation produces this.
    TestCase("argon2id matches the RFC 9106 test vector") {
        let tag = try Argon2id.hash(
            password: [UInt8](repeating: 0x01, count: 32),
            salt: [UInt8](repeating: 0x02, count: 16),
            iterations: 3, memoryKiB: 32, parallelism: 4, length: 32,
            secret: [UInt8](repeating: 0x03, count: 8),
            associatedData: [UInt8](repeating: 0x04, count: 12)
        )
        try expectEqual(hex(tag),
            "0d640df58d78766c08c037a34a8b53c9d01ef0452d75b65eb52520e96b01e659")
    },

    // The parameter set the protocol actually uses (time 3, 64 MiB, 1 lane).
    // Cross-checked against Go by scripts/test-transport.sh: the live server
    // recomputes this hash from the plaintext code on every connect_req.
    TestCase("argon2id is deterministic and parameter-sensitive at the protocol's settings") {
        let salt = Data(repeating: 0x5a, count: 16)
        let a = try Argon2id.hash(password: "SW7K2M9Q", salt: salt,
                                  iterations: 3, memoryKiB: 65536, parallelism: 1, length: 32)
        let b = try Argon2id.hash(password: "SW7K2M9Q", salt: salt,
                                  iterations: 3, memoryKiB: 65536, parallelism: 1, length: 32)
        try expectEqual(a, b)
        try expectEqual(a.count, 32)

        let differentCode = try Argon2id.hash(password: "SW7K2M9R", salt: salt,
                                              iterations: 3, memoryKiB: 65536, parallelism: 1, length: 32)
        try expectNotEqual(a, differentCode)

        let differentSalt = try Argon2id.hash(password: "SW7K2M9Q", salt: Data(repeating: 0x5b, count: 16),
                                              iterations: 3, memoryKiB: 65536, parallelism: 1, length: 32)
        try expectNotEqual(a, differentSalt)

        let differentTime = try Argon2id.hash(password: "SW7K2M9Q", salt: salt,
                                              iterations: 4, memoryKiB: 65536, parallelism: 1, length: 32)
        try expectNotEqual(a, differentTime)
    },

    TestCase("the verifier we put on the wire round-trips through its own checker") {
        let verifier = try CodeVerifier.make(for: "K7FM3Q8PW2XY")
        try expectEqual(verifier.alg, "argon2id")
        try expectEqual(verifier.time, 3)
        try expectEqual(verifier.memKiB, 65536)
        try expectEqual(verifier.par, 1)
        try expectEqual(verifier.len, 32)
        try expect(Data(base64Encoded: verifier.salt)!.count >= 16, "salt must be >= 16 bytes")
        try expect(verifier.verify("K7FM3Q8PW2XY"), "the code it was made from must verify")
        try expectFalse(verifier.verify("K7FM3Q8PW2XZ"), "a different code must not verify")
    },

    TestCase("two verifiers for the same code differ, because the salt is random") {
        let a = try CodeVerifier.make(for: "K7FM3Q8PW2XY")
        let b = try CodeVerifier.make(for: "K7FM3Q8PW2XY")
        try expectNotEqual(a.salt, b.salt)
        try expectNotEqual(a.hash, b.hash)
        try expect(b.verify("K7FM3Q8PW2XY"))
    },
])
