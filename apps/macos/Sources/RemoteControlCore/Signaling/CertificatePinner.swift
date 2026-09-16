import Foundation
import CryptoKit
import Security

/// TLS certificate pinning for the signaling socket.
///
/// `rc-signal` presents a **self-signed** certificate (no domain, no CA — see
/// PLAN.md §3), so CA validation is meaningless and is deliberately not
/// performed. What replaces it is an exact match on the SHA-256 of the leaf
/// certificate's DER encoding. That is strictly stronger than a public CA here:
/// there is no issuer that can be tricked into minting a second valid
/// certificate for this endpoint.
///
/// A mismatch **rejects the connection**. `scripts/test-transport.sh` runs one
/// instance with a deliberately wrong pin and requires it to fail to connect —
/// otherwise this whole file would be decoration.
public final class CertificatePinner: NSObject, URLSessionDelegate {

    public enum Outcome: Equatable {
        case accepted
        case rejectedNoCertificate
        case rejectedFingerprintMismatch(presented: String, expected: String)
        /// Pinning is switched off (plain `ws://`, or `RC_CERT_PIN=off`).
        case notPinned
    }

    /// Base64 SHA-256 of the DER certificate, or nil to disable pinning.
    public let expectedPinBase64: String?
    /// Set on every evaluation so a failure can be reported precisely.
    public private(set) var lastOutcome: Outcome = .notPinned
    /// Called on the URLSession delegate queue the moment a chain is judged.
    /// The client uses it to drop the socket immediately on a rejection instead
    /// of waiting out the handshake timeout — a bad pin should fail in
    /// milliseconds, not in twenty seconds.
    public var onDecision: (@Sendable (Outcome) -> Void)?

    public init(expectedPinBase64: String?) {
        self.expectedPinBase64 = expectedPinBase64
    }

    // MARK: - Pure, testable core

    /// The pin for a DER-encoded certificate: base64(SHA-256(DER)).
    public static func fingerprint(ofDER der: Data) -> String {
        Data(SHA256.hash(data: der)).base64EncodedString()
    }

    /// Constant-time-ish comparison of two base64 pins. The pin is not a secret,
    /// but comparing without early exit costs nothing and removes the question.
    public static func pinsMatch(_ a: String, _ b: String) -> Bool {
        let x = Array(a.utf8), y = Array(b.utf8)
        guard x.count == y.count else { return false }
        var diff: UInt8 = 0
        for i in 0..<x.count { diff |= x[i] ^ y[i] }
        return diff == 0
    }

    /// Decides on a certificate chain given as DER blobs, leaf first.
    /// Separated from `SecTrust` so it can be unit-tested with real certificate
    /// bytes and no network.
    public func evaluate(derChain: [Data]) -> Outcome {
        guard let expected = expectedPinBase64 else { return .notPinned }
        guard let leaf = derChain.first else { return .rejectedNoCertificate }
        let presented = Self.fingerprint(ofDER: leaf)
        if Self.pinsMatch(presented, expected) { return .accepted }
        return .rejectedFingerprintMismatch(presented: presented, expected: expected)
    }

    // MARK: - URLSessionDelegate

    public func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust else {
            completionHandler(.performDefaultHandling, nil)
            return
        }

        guard expectedPinBase64 != nil else {
            lastOutcome = .notPinned
            completionHandler(.performDefaultHandling, nil)
            return
        }

        let outcome = evaluate(derChain: Self.derChain(from: trust))
        lastOutcome = outcome
        onDecision?(outcome)
        switch outcome {
        case .accepted:
            // The chain does not validate against any CA and never will; the pin
            // IS the validation, so the credential is accepted explicitly.
            completionHandler(.useCredential, URLCredential(trust: trust))
        case .notPinned:
            completionHandler(.performDefaultHandling, nil)
        case .rejectedNoCertificate, .rejectedFingerprintMismatch:
            completionHandler(.cancelAuthenticationChallenge, nil)
        }
    }

    /// Leaf-first DER chain out of a `SecTrust`.
    public static func derChain(from trust: SecTrust) -> [Data] {
        if #available(macOS 12.0, *) {
            guard let certs = SecTrustCopyCertificateChain(trust) as? [SecCertificate] else { return [] }
            return certs.map { SecCertificateCopyData($0) as Data }
        } else {
            var out: [Data] = []
            for index in 0..<SecTrustGetCertificateCount(trust) {
                if let cert = SecTrustGetCertificateAtIndex(trust, index) {
                    out.append(SecCertificateCopyData(cert) as Data)
                }
            }
            return out
        }
    }
}

extension CertificatePinner.Outcome {
    public var isAcceptable: Bool {
        switch self {
        case .accepted, .notPinned: return true
        case .rejectedNoCertificate, .rejectedFingerprintMismatch: return false
        }
    }

    public var explanation: String {
        switch self {
        case .accepted: return "The server's certificate matches the pinned fingerprint."
        case .notPinned: return "Certificate pinning is disabled for this endpoint."
        case .rejectedNoCertificate: return "The server presented no certificate."
        case .rejectedFingerprintMismatch(let presented, let expected):
            return "Certificate fingerprint mismatch. Presented \(presented), expected \(expected). "
                + "Refusing to connect: this is either the wrong server or an interception attempt."
        }
    }
}
