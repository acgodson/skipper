import Foundation
import CoreVideo

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

    public static var defaultSize: (width: Int, height: Int) {
        let raw = DevelopmentHooks.value(.syntheticSize) ?? "1920x1200"
        let parts = raw.lowercased().split(separator: "x").compactMap { Int($0) }
        guard parts.count == 2, parts[0] > 0, parts[1] > 0 else { return (1920, 1200) }
        return (parts[0], parts[1])
    }

    public convenience init() {
        let size = SyntheticFrameSource.defaultSize
        self.init(width: size.width, height: size.height)
    }

    public init(width: Int, height: Int, fps: Int = QualityProfile.activeFramerate) {
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

    private func schedule() {
        timer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now(), repeating: 1.0 / Double(fps), leeway: .milliseconds(2))
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
            let bar = (frameIndex * 11) % width
            let barWidth = min(60, width - bar)
            let bytes = yPlane.assumingMemoryBound(to: UInt8.self)
            for row in 0..<height {
                let base = bytes + row * stride
                memset(base, Int32(UInt8((row &+ frameIndex &* 3) & 0x7F) &+ 40), width)
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
