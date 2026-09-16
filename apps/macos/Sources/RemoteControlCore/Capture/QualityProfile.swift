import Foundation

/// The `quality` values that travel on the wire (PROTOCOL.md §5).
///
/// Deliberately distinct from `QualityMode`, the three labels the UI shows.
/// The UI names a *preference* ("Best Quality"); the wire names a *strategy*
/// ("prefer resolution"). Keeping them separate means the UI copy can change
/// without a protocol change, and an unknown wire value degrades to `auto`
/// rather than being dropped.
public enum QualityWireMode: String, CaseIterable, Codable, Equatable {
    case auto
    case sharp      // prefer resolution: text stays crisp, motion may judder
    case smooth     // prefer frame rate: scale down, keep 30 fps

    /// Unknown values are `auto`. PROTOCOL.md §0: receivers ignore what they do
    /// not recognise rather than failing the session over it.
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

/// What a quality mode actually *does* to the encoder and the capture pipeline,
/// resolved against a specific display size.
///
/// The bitrate CAP is the same in every mode, and that is intentional
/// (PLAN.md §5: 0.5–3 Mbps typical, 8 Mbps burst). libwebrtc's bandwidth
/// estimator decides the steady-state rate from the actual link; a hard cap
/// below the burst does not save bandwidth on an idle screen — it only starves
/// the one moment that needs it, the full-screen repaint after a window opens,
/// which is exactly when a low cap looks like mush. Modes therefore differ by
/// **resolution and frame rate**, the two knobs that trade cleanly against each
/// other, and let BWE find the rate.
public struct QualityProfile: Equatable {

    public let mode: QualityWireMode
    /// Hard ceiling handed to `RTCRtpEncodingParameters.maxBitrateBps`.
    public let maxBitrateBps: Int
    /// Floor, so a momentarily pessimistic estimate cannot collapse to a
    /// slideshow of blocks.
    public let minBitrateBps: Int
    /// Ceiling handed to the encoder and to the capture stream when active.
    public let maxFramerate: Int
    /// `RTCRtpEncodingParameters.scaleResolutionDownBy`. 1.0 = native pixels.
    public let scaleResolutionDownBy: Double
    /// The size frames are adapted to before encoding — `scaleResolutionDownBy`
    /// applied to the display, rounded to even numbers (H.264 chroma subsampling
    /// requires even dimensions; an odd width silently costs a column).
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

    /// PLAN.md §5. Burst ceiling, identical in all three modes.
    public static let burstBitrateBps = 8_000_000
    public static let floorBitrateBps = 400_000
    /// PLAN.md §5: 30 fps cap while the screen is changing.
    public static let activeFramerate = 30

    /// Longest edge the encoder is fed in each mode.
    ///
    /// PLAN.md targets "adaptive, ~1080p effective", and these numbers are what
    /// makes that true. Phase 4 originally capped `auto` at 2560 and left
    /// `sharp` uncapped, which on a Retina display meant capturing and encoding
    /// the full 2880x1800 native pixel grid — a 5K-class stream for a desktop
    /// session, and a large part of why the CPU budget was blown.
    ///
    /// These are **pixel** widths, not points. A 1440-point Retina display is
    /// 2880 pixels wide, and the pixel grid is what the encoder sees.
    public static func maximumWidth(for mode: QualityWireMode) -> Int? {
        switch mode {
        case .sharp: return 2560     // never uncapped: no desktop session needs 5K
        case .auto: return 1920      // ~1080p effective, PLAN.md §5
        case .smooth: return 1280
        }
    }

    /// The pixel size an encoder should be fed for a display of `width`x`height`
    /// pixels in this mode: the cap applied while keeping aspect, with both
    /// dimensions even (H.264 4:2:0 cannot represent an odd edge).
    ///
    /// Idempotent — feeding it its own output returns that output. That matters:
    /// the capture stream reports its configured size back as `display_info`,
    /// which is then fed to this function again, and a non-idempotent version
    /// oscillated between capped and native on every round trip.
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

/// PLAN.md §5, the idle-CPU requirement, expressed as a pure function so it can
/// be tested without a screen.
///
/// ScreenCaptureKit only *delivers* a frame when something changed, so an idle
/// desktop already costs close to nothing. This policy is the second half of
/// that: it lowers `SCStreamConfiguration.minimumFrameInterval` as well, so the
/// capture machinery itself stops waking up 30 times a second to discover there
/// is nothing to send. Both halves are needed to stay under 5%.
public struct AdaptiveFrameRatePolicy: Equatable {

    /// Frame rate while the screen is changing.
    public let activeFPS: Int
    /// Frame rate once nothing has changed for `idleAfter`.
    public let idleFPS: Int
    /// Frame rate once nothing has changed for `deepIdleAfter`.
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

    /// Target frame rate given how long ago the last *changed* frame arrived.
    public func targetFPS(secondsSinceLastFrame: TimeInterval) -> Int {
        if secondsSinceLastFrame >= deepIdleAfter { return deepIdleFPS }
        if secondsSinceLastFrame >= idleAfter { return idleFPS }
        return activeFPS
    }

    /// Reconfiguring an `SCStream` is not free, so only act on a real change.
    public func shouldReconfigure(currentFPS: Int, secondsSinceLastFrame: TimeInterval) -> Bool {
        targetFPS(secondsSinceLastFrame: secondsSinceLastFrame) != currentFPS
    }
}
