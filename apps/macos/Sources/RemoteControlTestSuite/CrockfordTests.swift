import Foundation
import RCTestKit
import RemoteControlCore
import SkipperCore

public let crockfordSuite = TestSuite("CrockfordBase32", [

    TestCase("alphabet is exactly Crockford's") {
        try expectEqual(String(CrockfordBase32.alphabet), "0123456789ABCDEFGHJKMNPQRSTVWXYZ")
        try expectEqual(CrockfordBase32.alphabet.count, 32)
        try expectEqual(Set(CrockfordBase32.alphabet).count, 32, "no duplicate symbols")
        for excluded: Character in ["I", "L", "O", "U"] {
            try expectFalse(CrockfordBase32.alphabet.contains(excluded), "\(excluded) must be excluded")
        }
    },

    // Hand-computed vectors. A wrong bit order or pad direction fails these.
    TestCase("known encoding vectors") {
        try expectEqual(CrockfordBase32.encode([0x00]), "00")
        // 0b11111000 -> 11111 | 000+00pad -> Z, 0
        try expectEqual(CrockfordBase32.encode([0xF8]), "Z0")
        // 0b00000111 -> 00000 | 111+00pad = 0b11100 = 28 -> "0", "W"
        try expectEqual(CrockfordBase32.encode([0x07]), "0W")
        try expectEqual(CrockfordBase32.encode([0xFF, 0xFF, 0xFF, 0xFF, 0xFF]), "ZZZZZZZZ")
        try expectEqual(CrockfordBase32.encode([0x00, 0x00, 0x00, 0x00, 0x00]), "00000000")
        // 0x48 0x65 = 0100100001100101 -> 01001 00001 10010 1+0000pad -> 9,1,18,16
        try expectEqual(CrockfordBase32.encode([0x48, 0x65]), "91JG")
    },

    TestCase("encoded length is ceil(bits / 5)") {
        for byteCount in 1...16 {
            let bytes = [UInt8](repeating: 0xA5, count: byteCount)
            try expectEqual(CrockfordBase32.encode(bytes).count, (byteCount * 8 + 4) / 5)
        }
    },

    TestCase("normalize applies Crockford aliases") {
        try expectEqual(CrockfordBase32.normalize("iIlL"), "1111")
        try expectEqual(CrockfordBase32.normalize("oO"), "00")
        try expectEqual(CrockfordBase32.normalize("k7fm-3q8p-w2xy"), "K7FM3Q8PW2XY")
        try expectEqual(CrockfordBase32.normalize("K7FM 3Q8P W2XY"), "K7FM3Q8PW2XY")
    },

    TestCase("decode rejects illegal characters") {
        try expectNil(CrockfordBase32.decodeSymbols("U"), "U is not in the alphabet")
        try expectNil(CrockfordBase32.decodeSymbols("!"))
        try expectEqual(CrockfordBase32.decodeSymbols("0Z") ?? [], [0, 31])
        try expectEqual(CrockfordBase32.decodeSymbols("IO") ?? [], [1, 0], "aliases decode, not reject")
    },

    TestCase("every symbol maps back to its index") {
        for (index, character) in CrockfordBase32.alphabet.enumerated() {
            try expectEqual(CrockfordBase32.decodeSymbols(String(character)) ?? [], [UInt8(index)])
        }
    },
])
