import Foundation

public enum Argon2id {

    public enum Error: Swift.Error, LocalizedError {
        case badParameters(String)

        public var errorDescription: String? {
            switch self {
            case .badParameters(let why): return "Argon2id parameters are invalid: \(why)"
            }
        }
    }

    private static let blockBytes = 1024
    private static let qwords = 128
    private static let syncPoints = 4
    private static let versionNumber: UInt32 = 0x13
    private static let typeArgon2id: UInt32 = 2

    public static let recommendedTime: UInt32 = 3
    public static let recommendedMemoryKiB: UInt32 = 65536
    public static let recommendedParallelism: UInt32 = 1
    public static let recommendedLength: UInt32 = 32

    public static func hash(
        password: [UInt8],
        salt: [UInt8],
        iterations: UInt32,
        memoryKiB: UInt32,
        parallelism: UInt32,
        length: UInt32,
        secret: [UInt8] = [],
        associatedData: [UInt8] = []
    ) throws -> [UInt8] {
        guard parallelism >= 1 else { throw Error.badParameters("parallelism must be >= 1") }
        guard iterations >= 1 else { throw Error.badParameters("iterations must be >= 1") }
        guard length >= 4 else { throw Error.badParameters("length must be >= 4") }
        guard salt.count >= 8 else { throw Error.badParameters("salt must be >= 8 bytes") }
        guard memoryKiB >= 8 * parallelism else {
            throw Error.badParameters("memory must be >= 8 * parallelism KiB")
        }

        let lanes = Int(parallelism)
        let memoryBlocks = (Int(memoryKiB) / (syncPoints * lanes)) * (syncPoints * lanes)
        let laneLength = memoryBlocks / lanes
        let segmentLength = laneLength / syncPoints

        var pre = Blake2b(digestLength: 64)
        pre.update(le32(parallelism))
        pre.update(le32(length))
        pre.update(le32(memoryKiB))
        pre.update(le32(iterations))
        pre.update(le32(versionNumber))
        pre.update(le32(typeArgon2id))
        pre.update(le32(UInt32(password.count))); pre.update(password)
        pre.update(le32(UInt32(salt.count))); pre.update(salt)
        pre.update(le32(UInt32(secret.count))); pre.update(secret)
        pre.update(le32(UInt32(associatedData.count))); pre.update(associatedData)
        let h0 = pre.finalize()

        let memory = UnsafeMutablePointer<UInt64>.allocate(capacity: memoryBlocks * qwords)
        memory.initialize(repeating: 0, count: memoryBlocks * qwords)
        let scratchR = UnsafeMutablePointer<UInt64>.allocate(capacity: qwords)
        let scratchZ = UnsafeMutablePointer<UInt64>.allocate(capacity: qwords)
        let addresses = UnsafeMutablePointer<UInt64>.allocate(capacity: qwords)
        let input = UnsafeMutablePointer<UInt64>.allocate(capacity: qwords)
        let tmp = UnsafeMutablePointer<UInt64>.allocate(capacity: qwords)
        scratchR.initialize(repeating: 0, count: qwords)
        scratchZ.initialize(repeating: 0, count: qwords)
        addresses.initialize(repeating: 0, count: qwords)
        input.initialize(repeating: 0, count: qwords)
        tmp.initialize(repeating: 0, count: qwords)
        defer {
            memory.deallocate(); scratchR.deallocate(); scratchZ.deallocate()
            addresses.deallocate(); input.deallocate(); tmp.deallocate()
        }

        for lane in 0..<lanes {
            for column in 0..<2 {
                let seed = h0 + le32(UInt32(column)) + le32(UInt32(lane))
                let raw = variableHash(seed, length: blockBytes)
                let base = (lane * laneLength + column) * qwords
                for i in 0..<qwords {
                    var word: UInt64 = 0
                    for b in 0..<8 { word |= UInt64(raw[i * 8 + b]) << UInt64(b * 8) }
                    memory[base + i] = word
                }
            }
        }

        for pass in 0..<Int(iterations) {
            for slice in 0..<syncPoints {
                for lane in 0..<lanes {
                    let dataIndependent = (pass == 0 && slice < 2)
                    if dataIndependent {
                        for i in 0..<qwords { input[i] = 0 }
                        input[0] = UInt64(pass)
                        input[1] = UInt64(lane)
                        input[2] = UInt64(slice)
                        input[3] = UInt64(memoryBlocks)
                        input[4] = UInt64(iterations)
                        input[5] = UInt64(typeArgon2id)
                    }

                    var startIndex = 0
                    if pass == 0 && slice == 0 {
                        startIndex = 2
                        if dataIndependent {
                            input[6] &+= 1
                            nextAddresses(addresses, input, tmp)
                        }
                    }

                    var offset = lane * laneLength + slice * segmentLength + startIndex
                    var previous = offset % laneLength == 0 ? offset + laneLength - 1 : offset - 1

                    for index in startIndex..<segmentLength {
                        let random: UInt64
                        if dataIndependent {
                            let position = index % qwords
                            if position == 0 {
                                input[6] &+= 1
                                nextAddresses(addresses, input, tmp)
                            }
                            random = addresses[position]
                        } else {
                            random = memory[previous * qwords]
                        }

                        let ref = indexAlpha(
                            random: random, lanes: lanes, segmentLength: segmentLength,
                            sliceIndex: slice, laneIndex: lane, index: index,
                            pass: pass, laneLength: laneLength)

                        mixBlocks(memory, offset: offset, previous: previous, ref: ref,
                                  xor: pass > 0, r: scratchR, z: scratchZ)

                        previous = offset
                        offset += 1
                    }
                }
            }
        }

        var final = [UInt64](repeating: 0, count: qwords)
        for lane in 0..<lanes {
            let base = (lane * laneLength + laneLength - 1) * qwords
            for i in 0..<qwords { final[i] ^= memory[base + i] }
        }
        return variableHash(bytes(of: final), length: Int(length))
    }

    public static func hash(
        password: String, salt: Data,
        iterations: UInt32, memoryKiB: UInt32, parallelism: UInt32, length: UInt32
    ) throws -> Data {
        Data(try hash(
            password: [UInt8](Data(password.utf8)), salt: [UInt8](salt),
            iterations: iterations, memoryKiB: memoryKiB,
            parallelism: parallelism, length: length))
    }

    // MARK: - Internals

    private static func le32(_ v: UInt32) -> [UInt8] {
        [UInt8(v & 0xff), UInt8((v >> 8) & 0xff), UInt8((v >> 16) & 0xff), UInt8((v >> 24) & 0xff)]
    }

    private static func bytes(of block: [UInt64]) -> [UInt8] {
        var out = [UInt8]()
        out.reserveCapacity(block.count * 8)
        for word in block {
            for shift in stride(from: 0, to: 64, by: 8) { out.append(UInt8((word >> UInt64(shift)) & 0xff)) }
        }
        return out
    }

    private static func variableHash(_ input: [UInt8], length: Int) -> [UInt8] {
        if length <= 64 {
            var state = Blake2b(digestLength: length)
            state.update(le32(UInt32(length)))
            state.update(input)
            return state.finalize()
        }
        var out = [UInt8]()
        out.reserveCapacity(length)
        var state = Blake2b(digestLength: 64)
        state.update(le32(UInt32(length)))
        state.update(input)
        var v = state.finalize()
        out.append(contentsOf: v[0..<32])
        var produced = 32
        while length - produced > 64 {
            v = Blake2b.hash(v, digestLength: 64)
            out.append(contentsOf: v[0..<32])
            produced += 32
        }
        v = Blake2b.hash(v, digestLength: length - produced)
        out.append(contentsOf: v)
        return out
    }

    private static func mixBlocks(
        _ memory: UnsafeMutablePointer<UInt64>,
        offset: Int, previous: Int, ref: Int, xor: Bool,
        r: UnsafeMutablePointer<UInt64>, z: UnsafeMutablePointer<UInt64>
    ) {
        let p = memory + previous * qwords
        let q = memory + ref * qwords
        let o = memory + offset * qwords
        for i in 0..<qwords { r[i] = p[i] ^ q[i] }
        for i in 0..<qwords { z[i] = r[i] }
        permute(z)
        if xor {
            for i in 0..<qwords { o[i] ^= r[i] ^ z[i] }
        } else {
            for i in 0..<qwords { o[i] = r[i] ^ z[i] }
        }
    }

    private static func nextAddresses(
        _ address: UnsafeMutablePointer<UInt64>,
        _ input: UnsafeMutablePointer<UInt64>,
        _ tmp: UnsafeMutablePointer<UInt64>
    ) {
        for i in 0..<qwords { tmp[i] = input[i] }
        permute(tmp)
        for i in 0..<qwords { tmp[i] ^= input[i] }
        for i in 0..<qwords { address[i] = tmp[i] }
        permute(address)
        for i in 0..<qwords { address[i] ^= tmp[i] }
    }

    private static func permute(_ b: UnsafeMutablePointer<UInt64>) {
        for i in 0..<8 {
            let o = i * 16
            blamka(b, o, o + 1, o + 2, o + 3, o + 4, o + 5, o + 6, o + 7,
                   o + 8, o + 9, o + 10, o + 11, o + 12, o + 13, o + 14, o + 15)
        }
        for i in 0..<8 {
            let o = i * 2
            blamka(b, o, o + 1, o + 16, o + 17, o + 32, o + 33, o + 48, o + 49,
                   o + 64, o + 65, o + 80, o + 81, o + 96, o + 97, o + 112, o + 113)
        }
    }

    @inline(__always)
    private static func fBlaMka(_ x: UInt64, _ y: UInt64) -> UInt64 {
        let xy = (x & 0xffff_ffff) &* (y & 0xffff_ffff)
        return x &+ y &+ 2 &* xy
    }

    @inline(__always)
    private static func blamka(
        _ b: UnsafeMutablePointer<UInt64>,
        _ v0: Int, _ v1: Int, _ v2: Int, _ v3: Int, _ v4: Int, _ v5: Int, _ v6: Int, _ v7: Int,
        _ v8: Int, _ v9: Int, _ v10: Int, _ v11: Int, _ v12: Int, _ v13: Int, _ v14: Int, _ v15: Int
    ) {
        @inline(__always)
        func round(_ a: Int, _ bb: Int, _ c: Int, _ d: Int) {
            b[a] = fBlaMka(b[a], b[bb]); b[d] = (b[d] ^ b[a]).rotatedRight(32)
            b[c] = fBlaMka(b[c], b[d]);  b[bb] = (b[bb] ^ b[c]).rotatedRight(24)
            b[a] = fBlaMka(b[a], b[bb]); b[d] = (b[d] ^ b[a]).rotatedRight(16)
            b[c] = fBlaMka(b[c], b[d]);  b[bb] = (b[bb] ^ b[c]).rotatedRight(63)
        }
        round(v0, v4, v8, v12)
        round(v1, v5, v9, v13)
        round(v2, v6, v10, v14)
        round(v3, v7, v11, v15)
        round(v0, v5, v10, v15)
        round(v1, v6, v11, v12)
        round(v2, v7, v8, v13)
        round(v3, v4, v9, v14)
    }

    private static func indexAlpha(
        random: UInt64, lanes: Int, segmentLength: Int,
        sliceIndex: Int, laneIndex: Int, index: Int, pass: Int, laneLength: Int
    ) -> Int {
        var refLane = Int((random >> 32) % UInt64(lanes))
        if pass == 0 && sliceIndex == 0 { refLane = laneIndex }

        var m = 3 * segmentLength
        var s = ((sliceIndex + 1) % syncPoints) * segmentLength
        if refLane == laneIndex { m += index }
        if pass == 0 {
            m = sliceIndex * segmentLength
            s = 0
            if sliceIndex == 0 || refLane == laneIndex { m += index }
        }
        if index == 0 || refLane == laneIndex { m -= 1 }

        let size = UInt64(max(m, 0))
        let j1 = random & 0xffff_ffff
        var relative = (j1 &* j1) >> 32
        relative = size &- 1 &- ((size &* relative) >> 32)

        return refLane * laneLength + Int((UInt64(s) &+ relative) % UInt64(laneLength))
    }
}
