import Foundation
import CoreGraphics
import CoreMedia
import CoreVideo
import ScreenCaptureKit
#if canImport(AppKit)
import AppKit
#endif

/// Anything that can produce frames for the host's video track.
///
/// Two implementations exist: `ScreenCaptureSource` (the product) and
/// `SyntheticFrameSource` (used by `scripts/test-media.sh`, because a headless
/// CLI process cannot hold a Screen Recording grant — TCC attributes it to the
/// terminal, not to the binary). Both feed the *same* `RTCVideoSource`, encoder
/// and transport, so the integration test exercises the real media path.
@MainActor
public protocol VideoFrameProducer: AnyObject {
    var onFrame: ((CVPixelBuffer, Int64) -> Void)? { get set }
    var onSizeChange: ((Int, Int, Double) -> Void)? { get set }
    var onFailure: ((CaptureFailure) -> Void)? { get set }
    func start() async throws
    func stop() async
    /// Frame-rate ceiling. The adaptive policy drives this.
    func setTargetFPS(_ fps: Int) async
}

public enum CaptureFailure: Swift.Error, LocalizedError, Equatable {
    /// The Screen Recording grant is absent or was revoked. TCC binds the grant
    /// to the code signature, and this app is ad-hoc signed, so a rebuild
    /// genuinely can revoke it — this is a normal runtime state, not a
    /// programming error, and it must reach the UI with the deep link.
    case screenRecordingDenied
    case noDisplay
    case streamStopped(String)
    case other(String)

    public var errorDescription: String? {
        switch self {
        case .screenRecordingDenied:
            return "Screen Recording permission is not granted, so this Mac cannot capture its screen. The controller will connect but see nothing."
        case .noDisplay:
            return "No display was found to capture."
        case .streamStopped(let reason):
            return "Screen capture stopped: \(reason)"
        case .other(let message):
            return message
        }
    }

    public var isPermissionProblem: Bool {
        if case .screenRecordingDenied = self { return true }
        return false
    }
}

/// ScreenCaptureKit capture of the main display, delivered as `CVPixelBuffer`s.
///
/// Notes that are load-bearing rather than decorative:
///
/// * **Pixel format is NV12, not BGRA.** SCK defaults to BGRA; libwebrtc's
///   VideoToolbox H.264 encoder wants bi-planar 4:2:0 and converts BGRA in
///   *software* if it does not get it. Asking SCK for `420f` moves that
///   conversion into the same hardware pass that is already compositing the
///   screen, and is a large part of staying inside the CPU budget.
/// * **`showsCursor = true`** — PLAN.md. A remote desktop with no visible
///   pointer is unusable.
/// * **Only `.complete` frames are forwarded.** SCK emits `.idle` and
///   `.blank` status frames; encoding those would defeat the whole point of a
///   change-driven capture.
/// * **`minimumFrameInterval` is re-applied on idle** via `updateConfiguration`.
///   SCK not delivering frames is half the saving; the stream not waking up 30
///   times a second to check is the other half.
@MainActor
public final class ScreenCaptureSource: NSObject, VideoFrameProducer {

    public var onFrame: ((CVPixelBuffer, Int64) -> Void)?
    public var onSizeChange: ((Int, Int, Double) -> Void)?
    public var onFailure: ((CaptureFailure) -> Void)?

    public private(set) var isRunning = false
    public private(set) var pixelWidth = 0
    public private(set) var pixelHeight = 0
    public private(set) var backingScale: Double = 1
    public private(set) var currentFPS = QualityProfile.activeFramerate
    /// Frames actually forwarded to the encoder. The integration test and the
    /// host UI both read this; a still image cannot make it climb.
    public private(set) var deliveredFrames: Int = 0
    public private(set) var lastFrameAt: Date?
    /// `.complete` frames SCK delivered that carried no dirty rectangles, i.e.
    /// were pixel-identical to the previous one and were dropped. Exposed so a
    /// diagnostic can tell "nothing is arriving" from "nothing is changing".
    public private(set) var idleFrames: Int = 0
    /// Frames SCK delivered with no dirty-rect attachment at all. Those are
    /// forwarded (never silently go dark), but if this number is large the
    /// change detection is not working and the diagnostic below says so.
    public private(set) var framesWithoutDirtyInfo: Int = 0

    private let policy: AdaptiveFrameRatePolicy
    private var stream: SCStream?
    private var output: StreamOutput?
    private var display: SCDisplay?
    private var idleTimer: DispatchSourceTimer?
    private var screenObserver: Any?
    private var watchdogTicks = 0
    private var profile: QualityProfile = .profile(for: .auto, displayWidth: 0, displayHeight: 0)
    private let sampleQueue = DispatchQueue(label: "com.godson.remotecontrol.capture", qos: .userInteractive)

    public init(policy: AdaptiveFrameRatePolicy = AdaptiveFrameRatePolicy()) {
        self.policy = policy
        super.init()
    }

    deinit {
        idleTimer?.cancel()
    }

    /// Cheap, dialog-free probe. Mirrors `PermissionsModel`, deliberately: the
    /// capture path must not depend on the UI having refreshed recently.
    public static var hasScreenRecordingPermission: Bool { CGPreflightScreenCaptureAccess() }

    public func start() async throws {
        guard !isRunning else { return }

        // Two gates, on purpose. The preflight is instant and catches the normal
        // "never granted" case with a precise error; SCShareableContent is the
        // authority and catches the case the preflight lies about — a grant that
        // was invalidated because the ad-hoc signature changed on rebuild.
        guard ScreenCaptureSource.hasScreenRecordingPermission else {
            throw CaptureFailure.screenRecordingDenied
        }

        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        } catch {
            throw ScreenCaptureSource.classify(error)
        }
        guard let display = ScreenCaptureSource.mainDisplay(in: content) else {
            throw CaptureFailure.noDisplay
        }
        self.display = display

        let configuration = makeConfiguration(for: display, fps: policy.activeFPS)
        let filter = SCContentFilter(display: display, excludingWindows: [])
        let output = StreamOutput { [weak self] buffer, timeNs, changed, hadInfo in
            Task { @MainActor in
                self?.handle(buffer: buffer, timeNs: timeNs, changed: changed, hadDirtyRectInfo: hadInfo)
            }
        }
        let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
        do {
            try stream.addStreamOutput(output, type: .screen, sampleHandlerQueue: sampleQueue)
            try await stream.startCapture()
        } catch {
            throw ScreenCaptureSource.classify(error)
        }

        self.stream = stream
        self.output = output
        self.isRunning = true
        self.currentFPS = policy.activeFPS
        self.pixelWidth = configuration.width
        self.pixelHeight = configuration.height
        self.backingScale = ScreenCaptureSource.backingScale(for: display)
        onSizeChange?(pixelWidth, pixelHeight, backingScale)
        startIdleWatchdog()
        observeDisplayReconfiguration()
        RCLog.info("capture started \(pixelWidth)x\(pixelHeight) @\(backingScale)x")
    }

    public func stop() async {
        idleTimer?.cancel()
        idleTimer = nil
        #if canImport(AppKit)
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        screenObserver = nil
        #endif
        guard let stream else { isRunning = false; return }
        self.stream = nil
        self.output = nil
        isRunning = false
        try? await stream.stopCapture()
    }

    public func setTargetFPS(_ fps: Int) async {
        guard let stream, let display, fps != currentFPS, fps > 0 else { return }
        let previous = currentFPS
        currentFPS = fps
        let configuration = makeConfiguration(for: display, fps: fps)
        do {
            try await stream.updateConfiguration(configuration)
            // Logged unconditionally, because "the adaptive frame rate is not
            // actually taking effect" is precisely the failure that shipped in
            // Phase 4 and that no unit test could have caught. verify-capture.sh
            // asserts on these lines.
            RCLog.info("capture fps \(previous) -> \(fps) (changed frames \(deliveredFrames), unchanged dropped \(idleFrames))")
        } catch {
            currentFPS = previous
            RCLog.error("capture: could not change frame rate to \(fps): \(error)")
        }
    }

    /// Applies a quality profile: the encode resolution is enforced here, at the
    /// capture stage, as well as in the encoder. Scaling in SCK is free (the
    /// compositor is already scaling) and it means the pixels never exist.
    public func apply(profile: QualityProfile) async {
        self.profile = profile
        guard let stream, let display, isRunning else { return }
        let configuration = makeConfiguration(for: display, fps: currentFPS)
        do {
            try await stream.updateConfiguration(configuration)
            pixelWidth = configuration.width
            pixelHeight = configuration.height
            onSizeChange?(pixelWidth, pixelHeight, backingScale)
        } catch {
            RCLog.error("capture: could not apply quality profile: \(error)")
        }
    }

    // MARK: - Internals

    private func makeConfiguration(for display: SCDisplay, fps: Int) -> SCStreamConfiguration {
        let configuration = SCStreamConfiguration()
        // The cap is applied to the display's NATIVE pixel grid every time,
        // never to whatever this stream is currently configured at.
        //
        // That is the whole fix for a bug that shipped in Phase 4: the capture
        // size was reported upwards as `display_info`, the quality profile was
        // recomputed from *that*, and the recomputed profile then no longer
        // asked for any downscale — so the next reconfiguration went back to
        // native 2880x1800 and the stream oscillated. Deriving from the native
        // size makes this idempotent.
        let native = ScreenCaptureSource.nativePixelSize(of: display)
        let size = QualityProfile.cappedSize(width: native.width,
                                             height: native.height,
                                             mode: profile.mode)
        configuration.width = size.width
        configuration.height = size.height
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(max(1, fps)))
        configuration.queueDepth = 5
        // The CONTROLLER draws the pointer locally from its own mouse (see
        // RemoteScreenNSView.cursorLayer), which is instant. Capturing the host's
        // cursor as well would show a second, lagging pointer chasing the first.
        // PLAN.md's "cursor must be visible" requirement is still met — the
        // cursor is simply rendered at the near end instead of the far end.
        configuration.showsCursor = false
        configuration.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
        configuration.colorSpaceName = CGColorSpace.sRGB
        configuration.scalesToFit = true
        return configuration
    }

    /// `changed == false` means ScreenCaptureKit handed us a `.complete` frame
    /// whose dirty-rect list is empty: pixel-identical to the last one.
    ///
    /// SCK emits these regularly even on a motionless desktop, and Phase 4
    /// treated every one as activity. That did two expensive things at once: it
    /// re-encoded an unchanged screen, and — because `handle` snaps the stream
    /// back to 30 fps whenever a frame arrives — it held the capture at the
    /// active frame rate permanently, so the adaptive idle policy below never
    /// once took effect. Measured on an idle screen: 13.5 fps and 3.3 Mbps of
    /// nothing. Dropping them here is what makes "1–5 fps when static" true.
    private func handle(buffer: CVPixelBuffer, timeNs: Int64, changed: Bool, hadDirtyRectInfo: Bool = true) {
        guard changed else {
            idleFrames += 1
            return
        }
        if !hadDirtyRectInfo { framesWithoutDirtyInfo += 1 }
        deliveredFrames += 1
        lastFrameAt = Date()
        if currentFPS != policy.activeFPS {
            // Something moved while we were idling: go back to full rate now,
            // not on the next watchdog tick, or the first frame of a drag is
            // followed by a visible stall.
            Task { await setTargetFPS(policy.activeFPS) }
        }
        onFrame?(buffer, timeNs)
    }

    /// Dispatch, not `RunLoop.main`: the headless driver has no run loop.
    private func startIdleWatchdog() {
        idleTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 1.0, repeating: 1.0, leeway: .milliseconds(200))
        timer.setEventHandler { [weak self] in
            Task { @MainActor in
                guard let self, self.isRunning else { return }
                let idle = Date().timeIntervalSince(self.lastFrameAt ?? Date())
                self.watchdogTicks += 1
                if self.watchdogTicks % 5 == 0 {
                    RCLog.info("capture tick fps=\(self.currentFPS) idle=\(String(format: "%.1f", idle))s changed frames \(self.deliveredFrames), unchanged dropped \(self.idleFrames), no-dirty-info \(self.framesWithoutDirtyInfo)")
                }
                guard self.policy.shouldReconfigure(currentFPS: self.currentFPS,
                                                    secondsSinceLastFrame: idle) else { return }
                await self.setTargetFPS(self.policy.targetFPS(secondsSinceLastFrame: idle))
            }
        }
        timer.resume()
        idleTimer = timer
    }

    /// A resolution change, a display being plugged in, or the main display
    /// moving must re-target the stream and re-send `display_info`
    /// (PROTOCOL.md §5), or the controller keeps letterboxing to a stale size.
    private func observeDisplayReconfiguration() {
        #if canImport(AppKit)
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.handleDisplayReconfiguration() }
        }
        #endif
    }

    private func handleDisplayReconfiguration() {
        guard isRunning else { return }
        Task { [weak self] in
            guard let self else { return }
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
                guard let display = ScreenCaptureSource.mainDisplay(in: content) else { return }
                self.display = display
                self.backingScale = ScreenCaptureSource.backingScale(for: display)
                let configuration = self.makeConfiguration(for: display, fps: self.currentFPS)
                guard configuration.width != self.pixelWidth || configuration.height != self.pixelHeight else { return }
                let filter = SCContentFilter(display: display, excludingWindows: [])
                try await self.stream?.updateContentFilter(filter)
                try await self.stream?.updateConfiguration(configuration)
                self.pixelWidth = configuration.width
                self.pixelHeight = configuration.height
                self.onSizeChange?(self.pixelWidth, self.pixelHeight, self.backingScale)
                RCLog.info("capture retargeted to \(self.pixelWidth)x\(self.pixelHeight)")
            } catch {
                self.onFailure?(ScreenCaptureSource.classify(error))
            }
        }
    }

    private static func mainDisplay(in content: SCShareableContent) -> SCDisplay? {
        content.displays.first { $0.displayID == CGMainDisplayID() } ?? content.displays.first
    }

    /// SCDisplay reports points; the encoder sees pixels. A 1440-point Retina
    /// display is a 2880-pixel one, and confusing the two is how "cap at 2560"
    /// silently did nothing.
    private static func nativePixelSize(of display: SCDisplay) -> (width: Int, height: Int) {
        let scale = backingScale(for: display)
        return (Int(Double(display.width) * scale), Int(Double(display.height) * scale))
    }

    private static func backingScale(for display: SCDisplay) -> Double {
        #if canImport(AppKit)
        for screen in NSScreen.screens {
            let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
            if number?.uint32Value == display.displayID { return Double(screen.backingScaleFactor) }
        }
        return Double(NSScreen.main?.backingScaleFactor ?? 1)
        #else
        return 1
        #endif
    }

    /// TCC denial does not arrive as a nice sentinel: SCK reports it as an
    /// `SCStreamError` in the `com.apple.ScreenCaptureKit` domain, and the codes
    /// have shifted between OS versions. Match on what is stable — the domain
    /// plus the "user declined" / "missing entitlement" codes — and re-probe TCC
    /// before deciding it is something else.
    private static func classify(_ error: Swift.Error) -> CaptureFailure {
        if let failure = error as? CaptureFailure { return failure }
        let nsError = error as NSError
        if !CGPreflightScreenCaptureAccess() { return .screenRecordingDenied }
        if nsError.domain == SCStreamErrorDomain {
            switch nsError.code {
            case -3801, -3802, -3803:   // userDeclined / missing entitlement family
                return .screenRecordingDenied
            default:
                return .other("\(nsError.localizedDescription) (SCStream \(nsError.code))")
            }
        }
        return .other(nsError.localizedDescription)
    }
}

// MARK: - SCStreamDelegate

extension ScreenCaptureSource: SCStreamDelegate {
    nonisolated public func stream(_ stream: SCStream, didStopWithError error: Swift.Error) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.isRunning = false
            self.stream = nil
            let failure = ScreenCaptureSource.classify(error)
            RCLog.error("capture stopped: \(failure.localizedDescription)")
            self.onFailure?(failure)
        }
    }
}

/// Lives off the main actor: SCK delivers on its own queue and hopping every
/// frame to the main actor before even looking at it would put the whole capture
/// rate behind the UI run loop.
private final class StreamOutput: NSObject, SCStreamOutput {

    private let deliver: (CVPixelBuffer, Int64, Bool, Bool) -> Void

    init(deliver: @escaping (CVPixelBuffer, Int64, Bool, Bool) -> Void) {
        self.deliver = deliver
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, CMSampleBufferIsValid(sampleBuffer) else { return }
        // SCK attaches a status to every sample. `.idle` means "nothing changed,
        // here is a keepalive" and `.blank` means "the display is off"; sending
        // either to the encoder would burn CPU and bandwidth for no new pixels.
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
                as? [[SCStreamFrameInfo: Any]],
              let info = attachments.first,
              let raw = info[.status] as? Int,
              let status = SCFrameStatus(rawValue: raw), status == .complete else { return }
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let time = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let timeNs = Int64(CMTimeGetSeconds(time) * 1_000_000_000)

        // `.complete` alone is NOT "something changed" — SCK marks frames
        // complete whenever it has a valid surface for us, dirty or not. The
        // dirty-rect list is the authority. Note the deliberate asymmetry: a
        // MISSING attachment is treated as changed (never silently stop sending
        // video because an OS release renamed a key), an attachment that is
        // present and empty is treated as unchanged.
        let changed: Bool
        let hadInfo: Bool
        if let rects = info[.dirtyRects] as? [Any] {
            changed = !rects.isEmpty
            hadInfo = true
        } else {
            changed = true
            hadInfo = false
        }
        deliver(pixelBuffer, timeNs, changed, hadInfo)
    }
}
