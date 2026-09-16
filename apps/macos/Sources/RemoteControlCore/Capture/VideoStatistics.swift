import Foundation

public struct VideoStatistics: Equatable, Codable {
    public var framesEncoded: Int = 0
    public var framesSent: Int = 0
    public var bytesSent: Int = 0
    public var framesDecoded: Int = 0
    public var framesReceived: Int = 0
    public var bytesReceived: Int = 0
    public var framesPerSecond: Double = 0
    public var frameWidth: Int = 0
    public var frameHeight: Int = 0
    public var encoderImplementation: String = ""
    public var decoderImplementation: String = ""
    public var codecMimeType: String = ""

    public init() {}

    public var isHardwareH264: Bool {
        let implementation = encoderImplementation.isEmpty ? decoderImplementation : encoderImplementation
        guard codecMimeType.lowercased().hasSuffix("h264") else { return false }
        return implementation.localizedCaseInsensitiveContains("videotoolbox")
    }

    public static func parse(_ entries: [(type: String, values: [String: Any])]) -> VideoStatistics {
        var stats = VideoStatistics()
        func int(_ values: [String: Any], _ key: String) -> Int? {
            (values[key] as? NSNumber)?.intValue
        }

        var codecs: [String: String] = [:]
        for entry in entries where entry.type == "codec" {
            guard let id = entry.values["id"] as? String,
                  let mime = entry.values["mimeType"] as? String else { continue }
            codecs[id] = mime
        }
        var codecID: String?

        for entry in entries {
            let kind = entry.values["kind"] as? String ?? entry.values["mediaType"] as? String
            guard kind == "video" else { continue }
            switch entry.type {
            case "outbound-rtp":
                stats.framesEncoded += int(entry.values, "framesEncoded") ?? 0
                stats.framesSent += int(entry.values, "framesSent") ?? 0
                stats.bytesSent += int(entry.values, "bytesSent") ?? 0
                if let fps = (entry.values["framesPerSecond"] as? NSNumber)?.doubleValue { stats.framesPerSecond = fps }
                if let width = int(entry.values, "frameWidth") { stats.frameWidth = width }
                if let height = int(entry.values, "frameHeight") { stats.frameHeight = height }
                if let implementation = entry.values["encoderImplementation"] as? String {
                    stats.encoderImplementation = implementation
                }
                if let id = entry.values["codecId"] as? String { codecID = id }
            case "inbound-rtp":
                stats.framesDecoded += int(entry.values, "framesDecoded") ?? 0
                stats.framesReceived += int(entry.values, "framesReceived") ?? 0
                stats.bytesReceived += int(entry.values, "bytesReceived") ?? 0
                if let fps = (entry.values["framesPerSecond"] as? NSNumber)?.doubleValue { stats.framesPerSecond = fps }
                if let width = int(entry.values, "frameWidth") { stats.frameWidth = width }
                if let height = int(entry.values, "frameHeight") { stats.frameHeight = height }
                if let implementation = entry.values["decoderImplementation"] as? String {
                    stats.decoderImplementation = implementation
                }
                if let id = entry.values["codecId"] as? String { codecID = id }
            default:
                continue
            }
        }
        if let codecID, let mime = codecs[codecID] { stats.codecMimeType = mime }
        return stats
    }

    public static func bitrate(from earlier: VideoStatistics, to later: VideoStatistics,
                               seconds: TimeInterval, direction: Direction) -> Double {
        guard seconds > 0 else { return 0 }
        let delta: Int
        switch direction {
        case .outbound: delta = later.bytesSent - earlier.bytesSent
        case .inbound: delta = later.bytesReceived - earlier.bytesReceived
        }
        return Double(max(0, delta)) * 8.0 / seconds
    }

    public static func measuredFPS(from earlier: VideoStatistics, to later: VideoStatistics,
                                   seconds: TimeInterval, direction: Direction) -> Double {
        guard seconds > 0 else { return 0 }
        let delta: Int
        switch direction {
        case .outbound: delta = later.framesEncoded - earlier.framesEncoded
        case .inbound: delta = later.framesDecoded - earlier.framesDecoded
        }
        return Double(max(0, delta)) / seconds
    }

    public enum Direction { case inbound, outbound }
}
