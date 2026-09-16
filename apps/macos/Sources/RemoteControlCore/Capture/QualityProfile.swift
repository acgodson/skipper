import Foundation

public enum QualityWireMode: String, CaseIterable, Codable, Equatable {
    case auto
    case sharp
    case smooth

    public init(wire: String) {
        self = QualityWireMode(rawValue: wire.lowercased()) ?? .auto
    }
}

public extension QualityMode {
    var wireMode: QualityWireMode {
        switch self {
        case .best: return .sharp
        case .balanced: return .auto
        case .lowBandwidth: return .smooth
        }
    }
}

public struct QualityPayload: Codable, Equatable {
    public var mode: String
    public init(mode: String) { self.mode = mode }
    public init(_ mode: QualityWireMode) { self.mode = mode.rawValue }
    public var wireMode: QualityWireMode { QualityWireMode(wire: mode) }
}

public struct QualityProfile: Equatable {

    public let mode: QualityWireMode
    public let maxBitrateBps: Int
    public let minBitrateBps: Int
    public let maxFramerate: Int
    public let scaleResolutionDownBy: Double
    public let encodeWidth: Int
    public let encodeHeight: Int

    public init(mode: QualityWireMode, maxBitrateBps: Int, minBitrateBps: Int,
                maxFramerate: Int, scaleResolutionDownBy: Double,
                encodeWidth: Int, encodeHeight: Int) {
        self.mode = mode
        self.maxBitrateBps = maxBitrateBps
        self.minBitrateBps = minBitrateBps
        self.maxFramerate = maxFramerate
        self.scaleResolutionDownBy = scaleResolutionDownBy
        self.encodeWidth = encodeWidth
        self.encodeHeight = encodeHeight
    }

    public static let burstBitrateBps = 8_000_000
    public static let floorBitrateBps = 400_000
    public static let activeFramerate = 30

    public static func maximumWidth(for mode: QualityWireMode) -> Int? {
        switch mode {
        case .sharp: return 2560
        case .auto: return 1920
        case .smooth: return 1280
        }
    }

    public static func cappedSize(width: Int, height: Int, mode: QualityWireMode) -> (width: Int, height: Int) {
        guard width > 0, height > 0 else { return (0, 0) }
        func even(_ value: Double) -> Int { max(2, Int((value / 2).rounded()) * 2) }
        guard let cap = maximumWidth(for: mode), width > cap else {
            return (even(Double(width)), even(Double(height)))
        }
        let scale = Double(width) / Double(cap)
        return (even(Double(cap)), even(Double(height) / scale))
    }

    public static func profile(for mode: QualityWireMode, displayWidth: Int, displayHeight: Int) -> QualityProfile {
        guard displayWidth > 0, displayHeight > 0 else {
            return QualityProfile(mode: mode,
                                  maxBitrateBps: burstBitrateBps,
                                  minBitrateBps: floorBitrateBps,
                                  maxFramerate: activeFramerate,
                                  scaleResolutionDownBy: 1.0,
                                  encodeWidth: 0, encodeHeight: 0)
        }
        var scale = 1.0
        if let cap = maximumWidth(for: mode), displayWidth > cap {
            scale = Double(displayWidth) / Double(cap)
        }
        let size = cappedSize(width: displayWidth, height: displayHeight, mode: mode)
        return QualityProfile(
            mode: mode,
            maxBitrateBps: burstBitrateBps,
            minBitrateBps: floorBitrateBps,
            maxFramerate: activeFramerate,
            scaleResolutionDownBy: scale,
            encodeWidth: size.width,
            encodeHeight: size.height)
    }
}

public struct AdaptiveFrameRatePolicy: Equatable {

    public let activeFPS: Int
    public let idleFPS: Int
    public let deepIdleFPS: Int
    public let idleAfter: TimeInterval
    public let deepIdleAfter: TimeInterval

    public init(activeFPS: Int = QualityProfile.activeFramerate,
                idleFPS: Int = 5,
                deepIdleFPS: Int = 1,
                idleAfter: TimeInterval = 2.0,
                deepIdleAfter: TimeInterval = 10.0) {
        self.activeFPS = activeFPS
        self.idleFPS = idleFPS
        self.deepIdleFPS = deepIdleFPS
        self.idleAfter = idleAfter
        self.deepIdleAfter = deepIdleAfter
    }

    public func targetFPS(secondsSinceLastFrame: TimeInterval) -> Int {
        if secondsSinceLastFrame >= deepIdleAfter { return deepIdleFPS }
        if secondsSinceLastFrame >= idleAfter { return idleFPS }
        return activeFPS
    }

    public func shouldReconfigure(currentFPS: Int, secondsSinceLastFrame: TimeInterval) -> Bool {
        targetFPS(secondsSinceLastFrame: secondsSinceLastFrame) != currentFPS
    }
}
