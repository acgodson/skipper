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

/// The single source of randomness for anything security relevant.
///
/// Deliberately CryptoKit and nothing else. `arc4random_uniform`,
/// `Int.random(in:)` and `SystemRandomNumberGenerator` are not contractually
/// CSPRNGs on every platform and must never be used to mint an access code.
///
/// This used to call `SecRandomCopyBytes`. It does not any more, so that the
/// whole app can be free of Security.framework — see `SecureFile` for the
/// reasoning. `SymmetricKey(size:)` is CryptoKit's documented key-generation
/// entry point and draws from the same kernel CSPRNG.
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

    /// Uniform integer in `0..<upperBound`, rejection-sampled so the modulo bias
    /// that a naive `% upperBound` introduces cannot skew the digits.
    public static func uniform(_ upperBound: UInt32) throws -> UInt32 {
        precondition(upperBound > 0)
        let limit = UInt32.max - (UInt32.max % upperBound) - (upperBound - 1)
        while true {
            let raw = try bytes(4).withUnsafeBytes { $0.load(as: UInt32.self) }
            if raw <= limit { return raw % upperBound }
        }
    }
}
