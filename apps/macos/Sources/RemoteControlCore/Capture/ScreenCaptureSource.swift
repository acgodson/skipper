import Foundation
import CoreGraphics
import CoreMedia
import CoreVideo
import ScreenCaptureKit
#if canImport(AppKit)
import AppKit
#endif

@MainActor
public protocol VideoFrameProducer: AnyObject {
    var onFrame: ((CVPixelBuffer, Int64) -> Void)? { get set }
    var onSizeChange: ((Int, Int, Double) -> Void)? { get set }
    var onFailure: ((CaptureFailure) -> Void)? { get set }
    func start() async throws
    func stop() async
    func setTargetFPS(_ fps: Int) async
}

public enum CaptureFailure: Swift.Error, LocalizedError, Equatable {
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
            return RCLog.enabled ? "Screen capture stopped: \(reason)" : "This Mac stopped sharing its screen."
        case .other(let message):
            return message
        }
    }

    public var isPermissionProblem: Bool {
        if case .screenRecordingDenied = self { return true }
        return false
    }
}

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
    public private(set) var deliveredFrames: Int = 0
    public private(set) var lastFrameAt: Date?
    public private(set) var idleFrames: Int = 0
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

    public static var hasScreenRecordingPermission: Bool { CGPreflightScreenCaptureAccess() }

    public func start() async throws {
        guard !isRunning else { return }

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
            RCLog.info("capture fps \(previous) -> \(fps) (changed frames \(deliveredFrames), unchanged dropped \(idleFrames))")
        } catch {
            currentFPS = previous
            RCLog.error("capture: could not change frame rate to \(fps): \(error)")
        }
    }

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
        let native = ScreenCaptureSource.nativePixelSize(of: display)
        let size = QualityProfile.cappedSize(width: native.width,
                                             height: native.height,
                                             mode: profile.mode)
        configuration.width = size.width
        configuration.height = size.height
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(max(1, fps)))
        configuration.queueDepth = 5
        configuration.showsCursor = false
        configuration.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
        configuration.colorSpaceName = CGColorSpace.sRGB
        configuration.scalesToFit = true
        return configuration
    }

    private func handle(buffer: CVPixelBuffer, timeNs: Int64, changed: Bool, hadDirtyRectInfo: Bool = true) {
        guard changed else {
            idleFrames += 1
            return
        }
        if !hadDirtyRectInfo { framesWithoutDirtyInfo += 1 }
        deliveredFrames += 1
        lastFrameAt = Date()
        if currentFPS != policy.activeFPS {
            Task { await setTargetFPS(policy.activeFPS) }
        }
        onFrame?(buffer, timeNs)
    }

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

    private static func classify(_ error: Swift.Error) -> CaptureFailure {
        if let failure = error as? CaptureFailure { return failure }
        let nsError = error as NSError
        if !CGPreflightScreenCaptureAccess() { return .screenRecordingDenied }
        if nsError.domain == SCStreamErrorDomain {
            switch nsError.code {
            case -3801, -3802, -3803:
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

private final class StreamOutput: NSObject, SCStreamOutput {

    private let deliver: (CVPixelBuffer, Int64, Bool, Bool) -> Void

    init(deliver: @escaping (CVPixelBuffer, Int64, Bool, Bool) -> Void) {
        self.deliver = deliver
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, CMSampleBufferIsValid(sampleBuffer) else { return }
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
                as? [[SCStreamFrameInfo: Any]],
              let info = attachments.first,
              let raw = info[.status] as? Int,
              let status = SCFrameStatus(rawValue: raw), status == .complete else { return }
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let time = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let timeNs = Int64(CMTimeGetSeconds(time) * 1_000_000_000)

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
