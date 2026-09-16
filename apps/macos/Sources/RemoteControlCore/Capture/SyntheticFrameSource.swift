import Foundation
import CoreVideo

/// A deterministic moving test pattern in the same NV12 pixel format
/// `ScreenCaptureSource` produces, feeding the same `RTCVideoSource`, the same
/// VideoToolbox encoder and the same transport.
///
/// WHY IT EXISTS: `scripts/test-media.sh` runs two *headless* instances, and a
/// headless CLI process cannot hold a Screen Recording grant — macOS attributes
/// TCC to the responsible process (the terminal), not to the binary, so
/// `CGPreflightScreenCaptureAccess()` is false there no matter what the user
/// grants. Rather than pretend, the integration test drives this producer and
/// asserts on the *decoded frame count at the far end*, which is only ever
/// non-zero and rising if capture → encode → SRTP → decode all work. Real
/// ScreenCaptureKit capture is verified separately by running the .app.
///
/// The pattern MOVES every frame on purpose: a static image lets H.264 collapse
/// to skip frames, and then a broken pipeline and a working one look identical.
@MainActor
public final class SyntheticFrameSource: VideoFrameProducer {

    public var onFrame: ((CVPixelBuffer, Int64) -> Void)?
    public var onSizeChange: ((Int, Int, Double) -> Void)?
    public var onFailure: ((CaptureFailure) -> Void)?

    public private(set) var isRunning = false
    public private(set) var generatedFrames = 0

    private let width: Int
    private let height: Int
    private var fps: Int
    private var timer: DispatchSourceTimer?
    private var pool: CVPixelBufferPool?
    private let startTime = Date()

    /// The size the headless integration test runs at.
    ///
    /// It used to be 1280x720 — and that single number is why a codec
    /// regression shipped. libwebrtc advertises H.264 at level 3.1, whose
    /// maximum frame is exactly 1280x720; a 720p synthetic source therefore
    /// encoded happily on VideoToolbox while the real 1920x1200 desktop fell
    /// back to software VP8, and the synthetic test reported success. The
    /// default is now the same order of magnitude as a real desktop, so the two
    /// paths cannot diverge silently again.
    public static var defaultSize: (width: Int, height: Int) {
        let raw = ProcessInfo.processInfo.environment["RC_SYNTHETIC_SIZE"] ?? "1920x1200"
        let parts = raw.lowercased().split(separator: "x").compactMap { Int($0) }
        guard parts.count == 2, parts[0] > 0, parts[1] > 0 else { return (1920, 1200) }
        return (parts[0], parts[1])
    }

    public convenience init() {
        let size = SyntheticFrameSource.defaultSize
        self.init(width: size.width, height: size.height)
    }

    public init(width: Int, height: Int, fps: Int = QualityProfile.activeFramerate) {
        // Even dimensions; see QualityProfile.
        self.width = max(2, width - (width % 2))
        self.height = max(2, height - (height % 2))
        self.fps = fps
    }

    public func start() async throws {
        guard !isRunning else { return }
        let attributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
        ]
        var pool: CVPixelBufferPool?
        let status = CVPixelBufferPoolCreate(kCFAllocatorDefault, nil, attributes as CFDictionary, &pool)
        guard status == kCVReturnSuccess, let pool else {
            throw CaptureFailure.other("could not create a pixel buffer pool (\(status))")
        }
        self.pool = pool
        isRunning = true
        onSizeChange?(width, height, 1.0)
        schedule()
    }

    public func stop() async {
        timer?.cancel()
        timer = nil
        isRunning = false
    }

    public func setTargetFPS(_ fps: Int) async {
        guard fps > 0, fps != self.fps else { return }
        self.fps = fps
        if isRunning { schedule() }
    }

    /// A `DispatchSourceTimer`, NOT a `Timer` on `RunLoop.main`. `rc-node` parks
    /// its main thread in `dispatchMain()`, where there is no run loop and a
    /// `Timer` never fires — which is precisely the difference between "the
    /// media test measures 30 fps" and "the media test measures nothing".
    private func schedule() {
        timer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now(), repeating: 1.0 / Double(fps), leeway: .milliseconds(2))
        // `Task { @MainActor }`, not `MainActor.assumeIsolated`: a dispatch
        // handler on the main QUEUE is not, as far as Swift's runtime check is
        // concerned, running on the MainActor's executor, and the assumption
        // traps ("Incorrect actor executor assumption") in a process that parks
        // its main thread in `dispatchMain()` rather than a run loop.
        timer.setEventHandler { [weak self] in
            Task { @MainActor in self?.emit() }
        }
        timer.resume()
        self.timer = timer
    }

    private func emit() {
        guard isRunning, let pool else { return }
        var buffer: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &buffer) == kCVReturnSuccess,
              let pixelBuffer = buffer else { return }

        let frameIndex = generatedFrames
        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        if let yPlane = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0) {
            let stride = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0)
            let bar = (frameIndex * 11) % width          // sweeps across, never repeats a pair
            let barWidth = min(60, width - bar)
            let bytes = yPlane.assumingMemoryBound(to: UInt8.self)
            // Two `memset`s per row, NOT a per-pixel loop. This target is built
            // -Onone in debug, where a 921,600-iteration Swift loop per frame
            // costs more than the H.264 encode and libwebrtc's CPU-overuse
            // detector responds by dropping the frame rate — which then looks
            // exactly like a broken pipeline in the media test.
            for row in 0..<height {
                let base = bytes + row * stride
                // Horizontal banding that shifts every frame, so no two
                // consecutive frames are predictable from each other...
                memset(base, Int32(UInt8((row &+ frameIndex &* 3) & 0x7F) &+ 40), width)
                // ...plus a hard-edged moving bar the encoder cannot skip.
                if barWidth > 0 { memset(base + bar, 235, barWidth) }
            }
        }
        if let uvPlane = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 1) {
            let stride = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 1)
            let rows = CVPixelBufferGetHeightOfPlane(pixelBuffer, 1)
            let bytes = uvPlane.assumingMemoryBound(to: UInt8.self)
            for row in 0..<rows {
                memset(bytes + row * stride, 128, stride)
            }
        }
        CVPixelBufferUnlockBaseAddress(pixelBuffer, [])

        generatedFrames += 1
        let timeNs = Int64(Date().timeIntervalSince(startTime) * 1_000_000_000)
        onFrame?(pixelBuffer, timeNs)
    }
}
