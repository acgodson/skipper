import Foundation

public enum CrockfordBase32 {

    public static let alphabet = Array("0123456789ABCDEFGHJKMNPQRSTVWXYZ")

    /// Big-endian, five bits per symbol; the final symbol is zero-padded on the right, no `=` padding.
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

    public static func decodeSymbols(_ input: String) -> [UInt8]? {
        var values: [UInt8] = []
        for character in normalize(input) {
            guard let index = alphabet.firstIndex(of: character) else { return nil }
            values.append(UInt8(index))
        }
        return values
    }

    public static func isValid(_ input: String) -> Bool {
        decodeSymbols(input) != nil
    }
}
