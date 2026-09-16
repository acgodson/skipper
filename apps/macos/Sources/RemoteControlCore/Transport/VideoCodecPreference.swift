import Foundation

/// Forcing H.264 onto the video m-line — the single most expensive decision in
/// the whole media path.
///
/// WHY THIS FILE EXISTS. Phase 4 shipped with no codec preference at all and
/// silently negotiated VP8, which libwebrtc encodes **in software**. Encoding a
/// Retina desktop in software pinned a CPU core (measured: 93.8% of one core on
/// an idle screen, against a 5% budget). H.264 is the only codec libwebrtc runs
/// on Apple's VideoToolbox hardware encoder, so "the session negotiated H.264"
/// is not a preference here, it is the efficiency requirement (PLAN.md §5).
///
/// Two independent mechanisms, deliberately belt-and-braces, because they fail
/// in different ways:
///
/// 1. `RTCRtpTransceiver.setCodecPreferences` with H.264 hoisted to the front.
///    This is the specified API and it affects both offers and answers.
/// 2. `preferH264(in:)` rewrites the `m=video` payload-type order in the local
///    SDP before `setLocalDescription`. A pure string function, so it is unit
///    testable without a peer connection, and it still works if a future
///    libwebrtc drops or changes the preference API.
///
/// Neither one *removes* VP8/VP9/AV1: a peer that genuinely cannot do H.264
/// should still get a picture. What guarantees we notice a fallback is the
/// assertion in `scripts/verify-capture.sh`, which fails the build when
/// `encoderImplementation` is not VideoToolbox.
public enum SDPCodecPreference {

    public static let h264Name = "H264"

    /// Reorders the payload types on the `m=video` line so that every H.264
    /// payload type (and its RTX companion) comes first, preserving the
    /// relative order within each group.
    ///
    /// The offerer's order decides the negotiation: an answerer picks the first
    /// codec in the offer it also supports. Rewriting the *local* description of
    /// both the offer and the answer therefore pins the codec from either end.
    public static func preferH264(in sdp: String) -> String {
        preferCodec(named: h264Name, in: sdp)
    }

    /// Generalised form; `preferH264` is the only caller in the product, but the
    /// tests use it to prove the reordering is not hard-coded to one string.
    public static func preferCodec(named codec: String, in sdp: String) -> String {
        // SDP is CRLF-delimited by RFC 4566, but libwebrtc and every munging
        // example in the wild also produce bare LF. Preserve whatever we got.
        let usesCRLF = sdp.contains("\r\n")
        let separator = usesCRLF ? "\r\n" : "\n"
        var lines = sdp.components(separatedBy: separator)

        guard let videoIndex = lines.firstIndex(where: { $0.hasPrefix("m=video ") }) else { return sdp }

        // The video section runs from the m=video line to the next m= line.
        var sectionEnd = lines.count
        if let next = lines[(videoIndex + 1)...].firstIndex(where: { $0.hasPrefix("m=") }) {
            sectionEnd = next
        }
        let section = lines[(videoIndex + 1)..<sectionEnd]

        // pt -> encoding name, from a=rtpmap:<pt> <name>/<clock>
        var names: [String: String] = [:]
        // rtx pt -> the pt it protects, from a=fmtp:<rtxpt> apt=<pt>
        var rtxFor: [String: String] = [:]
        for line in section {
            if line.hasPrefix("a=rtpmap:") {
                let body = line.dropFirst("a=rtpmap:".count)
                let parts = body.split(separator: " ", maxSplits: 1)
                guard parts.count == 2 else { continue }
                let name = parts[1].split(separator: "/").first.map(String.init) ?? ""
                names[String(parts[0])] = name
            } else if line.hasPrefix("a=fmtp:"), line.contains("apt=") {
                let body = line.dropFirst("a=fmtp:".count)
                let parts = body.split(separator: " ", maxSplits: 1)
                guard parts.count == 2 else { continue }
                for field in parts[1].split(separator: ";") where field.hasPrefix("apt=") {
                    rtxFor[String(parts[0])] = String(field.dropFirst("apt=".count))
                }
            }
        }

        // m=video <port> <proto> <pt> <pt> ...
        let header = lines[videoIndex].split(separator: " ").map(String.init)
        guard header.count > 3 else { return sdp }
        let prefix = header[0..<3]
        let payloads = Array(header[3...])

        let wanted = codec.lowercased()
        var preferred: [String] = []
        var rest: [String] = []
        for pt in payloads {
            let name = names[pt]?.lowercased()
            let isWanted = name == wanted
            // An RTX stream is useless separated from the codec it protects, so
            // it travels with it.
            let isWantedRTX = name == "rtx" && rtxFor[pt].flatMap { names[$0]?.lowercased() } == wanted
            if isWanted || isWantedRTX { preferred.append(pt) } else { rest.append(pt) }
        }
        guard !preferred.isEmpty, !rest.isEmpty else { return sdp }

        lines[videoIndex] = (prefix + preferred + rest).joined(separator: " ")
        return lines.joined(separator: separator)
    }

    /// H.264 level 5.2 — 36864 macroblocks, i.e. up to 8K. The level byte of a
    /// `profile-level-id`.
    public static let level5_2: UInt8 = 0x34

    /// Raises the H.264 **level** advertised in every `a=fmtp` line to 5.2.
    ///
    /// THIS IS THE FIX FOR THE PHASE 4 CPU FAILURE, and it is not cosmetic.
    /// The `stasel/WebRTC` M125 build advertises H.264 as
    /// `profile-level-id=640c1f` and `42e01f`. The trailing `1f` is level 3.1,
    /// whose maximum frame size is 1620 macroblocks — **exactly 1280x720**.
    /// Feed that encoder a 1920x1200 desktop and libwebrtc gives up on H.264 and
    /// falls back to the next negotiated codec, which is software VP8. That is
    /// why an idle screen sat at 94% of a CPU core.
    ///
    /// Reproduced deterministically before this was written: the same code path,
    /// same pixel format, same everything, reports `encoderImplementation` =
    /// VideoToolbox at 1280x720 and `libvpx` at 1920x1200.
    ///
    /// Raising the level is honest rather than a lie to the peer: Apple Silicon
    /// VideoToolbox encodes and decodes H.264 well past 4K, and both ends of
    /// this product are Apple Silicon Macs running this same binary. The profile
    /// (`640c` High / `42e0` Constrained Baseline) is left exactly as libwebrtc
    /// chose it; only the level byte moves.
    public static func raiseH264Level(in sdp: String, to level: UInt8 = level5_2) -> String {
        let separator = sdp.contains("\r\n") ? "\r\n" : "\n"
        var lines = sdp.components(separatedBy: separator)
        let target = String(format: "%02x", level)
        var changed = false
        for index in lines.indices {
            let line = lines[index]
            guard line.hasPrefix("a=fmtp:"), let range = line.range(of: "profile-level-id=") else { continue }
            let tail = line[range.upperBound...]
            let value = String(tail.prefix(6))
            guard value.count == 6,
                  let current = UInt8(value.suffix(2), radix: 16),
                  current < level else { continue }
            lines[index] = line.replacingOccurrences(of: "profile-level-id=" + value,
                                                     with: "profile-level-id=" + value.prefix(4) + target)
            changed = true
        }
        return changed ? lines.joined(separator: separator) : sdp
    }

    /// The `profile-level-id` values present, in order. Diagnostics and tests.
    public static func h264ProfileLevelIDs(in sdp: String) -> [String] {
        let separator = sdp.contains("\r\n") ? "\r\n" : "\n"
        return sdp.components(separatedBy: separator).compactMap { line in
            guard line.hasPrefix("a=fmtp:"), let range = line.range(of: "profile-level-id=") else { return nil }
            return String(line[range.upperBound...].prefix(6))
        }
    }

    /// The payload types on the `m=video` line, in order. Diagnostics and tests.
    public static func videoPayloadOrder(in sdp: String) -> [String] {
        let separator = sdp.contains("\r\n") ? "\r\n" : "\n"
        guard let line = sdp.components(separatedBy: separator).first(where: { $0.hasPrefix("m=video ") })
        else { return [] }
        return Array(line.split(separator: " ").map(String.init).dropFirst(3))
    }

    /// The encoding name of the first payload type on the `m=video` line —
    /// i.e. the codec this description actually asks for.
    public static func firstVideoCodecName(in sdp: String) -> String? {
        let separator = sdp.contains("\r\n") ? "\r\n" : "\n"
        let lines = sdp.components(separatedBy: separator)
        guard let first = videoPayloadOrder(in: sdp).first else { return nil }
        for line in lines where line.hasPrefix("a=rtpmap:\(first) ") {
            let body = line.dropFirst("a=rtpmap:\(first) ".count)
            return body.split(separator: "/").first.map(String.init)
        }
        return nil
    }
}
