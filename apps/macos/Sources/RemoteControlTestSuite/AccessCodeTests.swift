import Foundation
import RCTestKit
import RemoteControlCore

public let accessCodeSuite = TestSuite("AccessCode", [

    TestCase("generated code is twelve Crockford symbols") {
        for _ in 0..<50 {
            let code = try AccessCode.generate()
            try expectEqual(code.count, 12)
            for character in code {
                try expect(
                    CrockfordBase32.alphabet.contains(character),
                    "\(character) is outside the Crockford alphabet"
                )
            }
        }
    },

    // A hardcoded or constant-returning implementation fails here.
    TestCase("generation is not repeatable") {
        var seen = Set<String>()
        for _ in 0..<500 { seen.insert(try AccessCode.generate()) }
        try expectEqual(seen.count, 500, "every generated code must be distinct")
    },

    // A generator stuck on a few symbols fails here.
    TestCase("generation exercises nearly the whole alphabet") {
        var symbols = Set<Character>()
        for _ in 0..<400 { symbols.formUnion(try AccessCode.generate()) }
        try expectGreaterThanOrEqual(symbols.count, 30, "saw only \(symbols.count) distinct symbols")
    },

    // A biased or low-entropy source skews this badly.
    TestCase("first symbol is broadly distributed") {
        var counts: [Character: Int] = [:]
        for _ in 0..<3200 { counts[try AccessCode.generate().first!, default: 0] += 1 }
        try expectGreaterThanOrEqual(counts.count, 28)
        let maximum = counts.values.max() ?? 0
        try expectLessThan(maximum, 400, "expected ~100 per symbol; \(maximum) suggests a skewed source")
    },

    TestCase("formatting groups in fours") {
        try expectEqual(AccessCode.formatted("K7FM3Q8PW2XY"), "K7FM-3Q8P-W2XY")
        let code = try AccessCode.generate()
        let formatted = AccessCode.formatted(code)
        try expectEqual(formatted.count, 14)
        try expectEqual(formatted.filter { $0 == "-" }.count, 2)
        try expectEqual(AccessCode.canonicalize(formatted), code)
    },

    TestCase("canonicalize accepts real typing and rejects wrong lengths") {
        try expectEqual(AccessCode.canonicalize("k7fm-3q8p-w2xy"), "K7FM3Q8PW2XY")
        try expectEqual(AccessCode.canonicalize("k7fm 3q8p w2xy"), "K7FM3Q8PW2XY")
        try expectEqual(AccessCode.canonicalize("K7FM-3Q8P-W2XO"), "K7FM3Q8PW2X0", "O aliases to zero")
        try expectNil(AccessCode.canonicalize("K7FM-3Q8P"), "eleven or fewer symbols is not a code")
        try expectNil(AccessCode.canonicalize("K7FM-3Q8P-W2XYZ"), "thirteen symbols is not a code")
        try expectNil(AccessCode.canonicalize("K7FM-3Q8P-W2XU"), "U is not a legal symbol")
    },

    TestCase("device ID is nine digits and varies") {
        var seen = Set<String>()
        for _ in 0..<300 {
            let id = try DeviceID.generateLocal()
            try expectEqual(id.count, 9)
            try expect(id.allSatisfy(\.isNumber))
            try expectNotEqual(id.first!, "0", "a leading zero would render as eight digits")
            seen.insert(id)
        }
        try expectGreaterThan(seen.count, 290, "Device IDs must not repeat in practice")
    },

    TestCase("device ID formatting and canonicalization") {
        try expectEqual(DeviceID.formatted("482719351"), "482 719 351")
        try expectEqual(DeviceID.canonicalize("482 719 351"), "482719351")
        try expectNil(DeviceID.canonicalize("48271935"))
        try expectNil(DeviceID.canonicalize("4827193510"))
    },

    TestCase("SecureRandom.uniform stays in range and covers it") {
        var seen = Set<UInt32>()
        for _ in 0..<2000 {
            let value = try SecureRandom.uniform(10)
            try expectLessThan(value, 10)
            seen.insert(value)
        }
        try expectEqual(seen.count, 10, "all ten values should appear over 2000 draws")
    },

    TestCase("SecureRandom.bytes are not constant") {
        let a = try SecureRandom.bytes(32)
        let b = try SecureRandom.bytes(32)
        try expectEqual(a.count, 32)
        try expectNotEqual(a, b)
        try expectFalse(a.allSatisfy { $0 == 0 })
    },
])
