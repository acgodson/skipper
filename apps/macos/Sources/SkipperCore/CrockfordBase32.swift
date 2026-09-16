import Foundation

/// Crockford base32: 32 symbols, deliberately excluding I, L, O and U so that a
/// human reading an access code off a screen and typing it on another machine
/// cannot confuse 1/I/L or 0/O, and cannot accidentally spell anything obscene.
public enum CrockfordBase32 {

    /// 0-9 then A-Z minus I, L, O, U.
    public static let alphabet = Array("0123456789ABCDEFGHJKMNPQRSTVWXYZ")

    /// Encodes a byte buffer as a big-endian bit stream, five bits per symbol.
    /// The final symbol is zero-padded on the right when the bit count is not a
    /// multiple of five. No `=` padding is emitted.
    public static func encode(_ bytes: [UInt8]) -> String {
        guard !bytes.isEmpty else { return "" }
        var out = String()
        out.reserveCapacity((bytes.count * 8 + 4) / 5)
        var accumulator: UInt32 = 0
        var bitsHeld = 0
        for byte in bytes {
            accumulator = (accumulator << 8) | UInt32(byte)
            bitsHeld += 8
            while bitsHeld >= 5 {
                let index = Int((accumulator >> UInt32(bitsHeld - 5)) & 0x1F)
                out.append(alphabet[index])
                bitsHeld -= 5
            }
        }
        if bitsHeld > 0 {
            let index = Int((accumulator << UInt32(5 - bitsHeld)) & 0x1F)
            out.append(alphabet[index])
        }
        return out
    }

    /// Canonicalises user input: uppercases, drops separators, and applies
    /// Crockford's forgiving aliases (I/i/L/l -> 1, O/o -> 0).
    public static func normalize(_ input: String) -> String {
        var out = String()
        out.reserveCapacity(input.count)
        for scalar in input.uppercased() {
            switch scalar {
            case "-", " ", "\t", "\n": continue
            case "I", "L": out.append("1")
            case "O": out.append("0")
            default: out.append(scalar)
            }
        }
        return out
    }

    /// Decodes to the 5-bit symbol values. Returns nil if any symbol is outside
    /// the alphabet after normalisation. Padding bits are not validated.
    public static func decodeSymbols(_ input: String) -> [UInt8]? {
        var values: [UInt8] = []
        for character in normalize(input) {
            guard let index = alphabet.firstIndex(of: character) else { return nil }
            values.append(UInt8(index))
        }
        return values
    }

    /// True when every character is a legal Crockford symbol (post-normalisation).
    public static func isValid(_ input: String) -> Bool {
        decodeSymbols(input) != nil
    }
}
