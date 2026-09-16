import Foundation
import CryptoKit

public enum SecureRandomError: Error, LocalizedError {
    case failed(String)
    public var errorDescription: String? {
        if case .failed(let reason) = self {
            return "The system secure random number generator failed (\(reason))."
        }
        return "The system secure random number generator failed."
    }
}

public enum SecureRandom {

    public static func bytes(_ count: Int) throws -> [UInt8] {
        precondition(count > 0)
        let key = SymmetricKey(size: SymmetricKeySize(bitCount: count * 8))
        let out = key.withUnsafeBytes { Array($0) }
        guard out.count == count else {
            throw SecureRandomError.failed("expected \(count) bytes, got \(out.count)")
        }
        return out
    }

    public static func data(_ count: Int) throws -> Data {
        Data(try bytes(count))
    }

    public static func uniform(_ upperBound: UInt32) throws -> UInt32 {
        precondition(upperBound > 0)
        let limit = UInt32.max - (UInt32.max % upperBound) - (upperBound - 1)
        while true {
            let raw = try bytes(4).withUnsafeBytes { $0.load(as: UInt32.self) }
            if raw <= limit { return raw % upperBound }
        }
    }
}
