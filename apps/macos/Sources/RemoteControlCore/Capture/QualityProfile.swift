import Foundation

public enum QualityWireMode: String, CaseIterable, Codable, Equatable {
    case auto
    case sharp
    case smooth

    public init(wire: String) {
        self = QualityWireMode(rawValue: wire.lowercased()) ?? .auto
    }

    /// The ladder, cheapest first. `API.md` §4.4 states a ceiling in these values.
    public static let ladder: [QualityWireMode] = [.smooth, .auto, .sharp]

    /// `auto` is the answer for anything unrecognised, here and in the Go mirror: a
    /// value neither side understands must never buy the top tier.
    public static let fallbackCeiling: QualityWireMode = .auto

    public var rank: Int {
        Self.ladder.firstIndex(of: self) ?? Self.fallbackCeiling.rank
    }

    /// This mode, or `ceiling`, whichever is lower. The host's whole gate (`API.md` §4.4).
    public func clamped(to ceiling: QualityWireMode) -> QualityWireMode {
        Self.ladder[min(rank, ceiling.rank)]
    }

    /// A server-stated ceiling this build may not recognise. An unknown string clamps to
    /// `auto` rather than to `sharp`, the same fail-closed answer as a stale cache.
    public static func ceiling(wire: String?) -> QualityWireMode {
        guard let wire, let known = QualityWireMode(rawValue: wire.lowercased()) else {
            return fallbackCeiling
        }
        return known
    }

    /// The host's gate, as a function of what it knows (`API.md` §4.4). The host owns
    /// the encoder, so this answer is the whole enforcement: a controller may ask for
    /// anything and the host configures only what comes back from here.
    ///
    /// `stated` is nil when there is no entitlement to read at all, and `fresh` is false
    /// once the cached answer is older than `refreshAfterSec`. Both resolve to `auto`,
    /// because the alternative — an unreachable or stale account server handing out the
    /// top tier — is the one outcome a gate must not have.
    public static func permitted(requested: QualityWireMode,
                                stated: QualityWireMode?,
                                fresh: Bool) -> QualityWireMode {
        guard let stated, fresh else { return requested.clamped(to: fallbackCeiling) }
        return requested.clamped(to: stated)
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

    /// The ceiling each mode may ask the encoder for. Until this existed every mode
    /// asked for `burstBitrateBps`, so "quality" capped encode width and left the
    /// bandwidth — the dominant variable cost — untouched, and gating it saved nothing.
    ///
    /// A ceiling is not a target: a still desktop encodes at a few hundred kbps whatever
    /// this says, and adaptive framerate drops it further when nothing moves. The ceiling
    /// binds only under heavy motion, where libwebrtc gives back resolution rather than
    /// falling apart. So each number is set by what the tier must be allowed to cost, and
    /// the derivation is in `docs/BETA.md` §2.3:
    ///
    /// - `sharp` keeps `burstBitrateBps`. It is what the shipped client has always asked
    ///   for and what coturn's `max-bps` was sized against, so tiering below it changes
    ///   no relay ceiling.
    /// - `auto` is the **largest** ceiling under which the live 50¢ / 5-hour trial still
    ///   pays for itself: the trial's worst case is 5 h at this bitrate fully relayed, and
    ///   the margin that has to cover it runs out at 2.14 Mbps. 2 Mbps is that bound,
    ///   rounded down, and it is why a trial is capped here.
    /// - `smooth` is half of `auto`, which is what makes the tier worth choosing — a 25%
    ///   saving for 2.25× fewer pixels would not be — and it leaves a constrained uplink
    ///   enough headroom for congestion control to work rather than to drop frames.
    public static func maximumBitrateBps(for mode: QualityWireMode) -> Int {
        switch mode {
        case .sharp: return burstBitrateBps
        case .auto: return 2_000_000
        case .smooth: return 1_000_000
        }
    }

    /// The floor is a quarter of the ceiling, never above `floorBitrateBps`. A floor that
    /// is a large fraction of the ceiling makes a congested link drop packets instead of
    /// adapting, and the congested link is exactly what `smooth` exists for.
    public static func minimumBitrateBps(for mode: QualityWireMode) -> Int {
        min(floorBitrateBps, maximumBitrateBps(for: mode) / 4)
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
                                  maxBitrateBps: maximumBitrateBps(for: mode),
                                  minBitrateBps: minimumBitrateBps(for: mode),
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
            maxBitrateBps: maximumBitrateBps(for: mode),
            minBitrateBps: minimumBitrateBps(for: mode),
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
