import Foundation

public enum SDPCodecPreference {

    public static let h264Name = "H264"

    public static func preferH264(in sdp: String) -> String {
        preferCodec(named: h264Name, in: sdp)
    }

    public static func preferCodec(named codec: String, in sdp: String) -> String {
        let usesCRLF = sdp.contains("\r\n")
        let separator = usesCRLF ? "\r\n" : "\n"
        var lines = sdp.components(separatedBy: separator)

        guard let videoIndex = lines.firstIndex(where: { $0.hasPrefix("m=video ") }) else { return sdp }

        var sectionEnd = lines.count
        if let next = lines[(videoIndex + 1)...].firstIndex(where: { $0.hasPrefix("m=") }) {
            sectionEnd = next
        }
        let section = lines[(videoIndex + 1)..<sectionEnd]

        var names: [String: String] = [:]
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
            let isWantedRTX = name == "rtx" && rtxFor[pt].flatMap { names[$0]?.lowercased() } == wanted
            if isWanted || isWantedRTX { preferred.append(pt) } else { rest.append(pt) }
        }
        guard !preferred.isEmpty, !rest.isEmpty else { return sdp }

        lines[videoIndex] = (prefix + preferred + rest).joined(separator: " ")
        return lines.joined(separator: separator)
    }

    public static let level5_2: UInt8 = 0x34

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

    public static func h264ProfileLevelIDs(in sdp: String) -> [String] {
        let separator = sdp.contains("\r\n") ? "\r\n" : "\n"
        return sdp.components(separatedBy: separator).compactMap { line in
            guard line.hasPrefix("a=fmtp:"), let range = line.range(of: "profile-level-id=") else { return nil }
            return String(line[range.upperBound...].prefix(6))
        }
    }

    public static func videoPayloadOrder(in sdp: String) -> [String] {
        let separator = sdp.contains("\r\n") ? "\r\n" : "\n"
        guard let line = sdp.components(separatedBy: separator).first(where: { $0.hasPrefix("m=video ") })
        else { return [] }
        return Array(line.split(separator: " ").map(String.init).dropFirst(3))
    }

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
