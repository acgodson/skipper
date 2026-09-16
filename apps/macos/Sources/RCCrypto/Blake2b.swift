import Foundation

/// BLAKE2b (RFC 7693), unkeyed and keyed, with an arbitrary digest length 1...64.
///
/// WHY THIS IS HERE: `register` and `refresh_code` carry an **Argon2id** verifier
/// (PROTOCOL.md §2.3) and Argon2 is built on BLAKE2b. Neither CryptoKit nor
/// CommonCrypto ships BLAKE2b or Argon2, and the project takes exactly one
/// third-party dependency (libwebrtc), so the primitive is implemented here.
///
/// It is checked against the RFC 7693 Appendix A vector *and*, transitively,
/// against Go's `golang.org/x/crypto/argon2` every time the live server accepts
/// a `connect_req` for a code we registered — which is the assertion that
/// actually matters.
public struct Blake2b {

    public static let maxDigestLength = 64
    private static let blockBytes = 128

    private static let iv: [UInt64] = [
        0x6a09e667f3bcc908, 0xbb67ae8584caa73b, 0x3c6ef372fe94f82b, 0xa54ff53a5f1d36f1,
        0x510e527fade682d1, 0x9b05688c2b3e6c1f, 0x1f83d9abfb41bd6b, 0x5be0cd19137e2179,
    ]

    private static let sigma: [[Int]] = [
        [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15],
        [14, 10, 4, 8, 9, 15, 13, 6, 1, 12, 0, 2, 11, 7, 5, 3],
        [11, 8, 12, 0, 5, 2, 15, 13, 10, 14, 3, 6, 7, 1, 9, 4],
        [7, 9, 3, 1, 13, 12, 11, 14, 2, 6, 5, 10, 4, 0, 15, 8],
        [9, 0, 5, 7, 2, 4, 10, 15, 14, 1, 11, 12, 6, 8, 3, 13],
        [2, 12, 6, 10, 0, 11, 8, 3, 4, 13, 7, 5, 15, 14, 1, 9],
        [12, 5, 1, 15, 14, 13, 4, 10, 0, 7, 6, 3, 9, 2, 8, 11],
        [13, 11, 7, 14, 12, 1, 3, 9, 5, 0, 15, 4, 8, 6, 2, 10],
        [6, 15, 14, 9, 11, 3, 0, 8, 12, 2, 13, 7, 1, 4, 10, 5],
        [10, 2, 8, 4, 7, 6, 1, 5, 15, 11, 9, 14, 3, 12, 13, 0],
        [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15],
        [14, 10, 4, 8, 9, 15, 13, 6, 1, 12, 0, 2, 11, 7, 5, 3],
    ]

    private var h: [UInt64]
    private var buffer = [UInt8](repeating: 0, count: Blake2b.blockBytes)
    private var bufferLength = 0
    private var counter: (low: UInt64, high: UInt64) = (0, 0)
    private let digestLength: Int

    public init(digestLength: Int = 64, key: [UInt8] = []) {
        precondition(digestLength >= 1 && digestLength <= Blake2b.maxDigestLength)
        precondition(key.count <= 64)
        self.digestLength = digestLength
        self.h = Blake2b.iv
        h[0] ^= 0x0101_0000 ^ (UInt64(key.count) << 8) ^ UInt64(digestLength)
        if !key.isEmpty {
            var block = key
            block.append(contentsOf: [UInt8](repeating: 0, count: Blake2b.blockBytes - key.count))
            update(block)
        }
    }

    public mutating func update(_ bytes: [UInt8]) {
        var offset = 0
        while offset < bytes.count {
            if bufferLength == Blake2b.blockBytes {
                // Never compress the final block here: BLAKE2b needs to know which
                // block is last so it can set the finalisation flag.
                increment(by: UInt64(Blake2b.blockBytes))
                compress(buffer, last: false)
                bufferLength = 0
            }
            let take = min(Blake2b.blockBytes - bufferLength, bytes.count - offset)
            for i in 0..<take { buffer[bufferLength + i] = bytes[offset + i] }
            bufferLength += take
            offset += take
        }
    }

    public mutating func update(_ data: Data) { update([UInt8](data)) }

    public mutating func finalize() -> [UInt8] {
        increment(by: UInt64(bufferLength))
        for i in bufferLength..<Blake2b.blockBytes { buffer[i] = 0 }
        compress(buffer, last: true)
        var out = [UInt8]()
        out.reserveCapacity(digestLength)
        for word in h {
            for shift in stride(from: 0, to: 64, by: 8) {
                out.append(UInt8truncating(word >> UInt64(shift)))
                if out.count == digestLength { return out }
            }
        }
        return out
    }

    private func UInt8truncating(_ v: UInt64) -> UInt8 { UInt8(v & 0xff) }

    private mutating func increment(by n: UInt64) {
        let (sum, overflow) = counter.low.addingReportingOverflow(n)
        counter.low = sum
        if overflow { counter.high &+= 1 }
    }

    private mutating func compress(_ block: [UInt8], last: Bool) {
        var m = [UInt64](repeating: 0, count: 16)
        for i in 0..<16 {
            var word: UInt64 = 0
            for b in 0..<8 { word |= UInt64(block[i * 8 + b]) << UInt64(b * 8) }
            m[i] = word
        }
        var v = [UInt64](repeating: 0, count: 16)
        for i in 0..<8 { v[i] = h[i] }
        for i in 0..<8 { v[8 + i] = Blake2b.iv[i] }
        v[12] ^= counter.low
        v[13] ^= counter.high
        if last { v[14] = ~v[14] }

        @inline(__always)
        func mix(_ a: Int, _ b: Int, _ c: Int, _ d: Int, _ x: UInt64, _ y: UInt64) {
            v[a] = v[a] &+ v[b] &+ x
            v[d] = (v[d] ^ v[a]).rotatedRight(32)
            v[c] = v[c] &+ v[d]
            v[b] = (v[b] ^ v[c]).rotatedRight(24)
            v[a] = v[a] &+ v[b] &+ y
            v[d] = (v[d] ^ v[a]).rotatedRight(16)
            v[c] = v[c] &+ v[d]
            v[b] = (v[b] ^ v[c]).rotatedRight(63)
        }

        for round in 0..<12 {
            let s = Blake2b.sigma[round]
            mix(0, 4, 8, 12, m[s[0]], m[s[1]])
            mix(1, 5, 9, 13, m[s[2]], m[s[3]])
            mix(2, 6, 10, 14, m[s[4]], m[s[5]])
            mix(3, 7, 11, 15, m[s[6]], m[s[7]])
            mix(0, 5, 10, 15, m[s[8]], m[s[9]])
            mix(1, 6, 11, 12, m[s[10]], m[s[11]])
            mix(2, 7, 8, 13, m[s[12]], m[s[13]])
            mix(3, 4, 9, 14, m[s[14]], m[s[15]])
        }
        for i in 0..<8 { h[i] = h[i] ^ v[i] ^ v[8 + i] }
    }

    // MARK: - One-shot

    public static func hash(_ message: [UInt8], digestLength: Int = 64, key: [UInt8] = []) -> [UInt8] {
        var state = Blake2b(digestLength: digestLength, key: key)
        state.update(message)
        return state.finalize()
    }
}

extension UInt64 {
    @inline(__always)
    func rotatedRight(_ n: UInt64) -> UInt64 { (self >> n) | (self << (64 - n)) }
}
