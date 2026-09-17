#if canImport(AppKit)
import AppKit
import AVFoundation
import CoreImage
import CoreMedia
import CoreVideo
import SwiftUI
import WebRTC

public final class RemoteVideoLayerRenderer: NSObject, RTCVideoRenderer {

    public let displayLayer = AVSampleBufferDisplayLayer()
    public var onVideoSizeChange: ((CGSize) -> Void)?
    public private(set) var renderedFrames = 0

    private var lastSize: CGSize = .zero
    private var formatDescription: CMVideoFormatDescription?
    private var conversionPool: CVPixelBufferPool?
    private let lock = NSLock()

    public override init() {
        super.init()
        displayLayer.videoGravity = .resizeAspect
        displayLayer.backgroundColor = NSColor.black.cgColor
    }

    // MARK: RTCVideoRenderer

    public func setSize(_ size: CGSize) {
        report(size: size)
    }

    public func renderFrame(_ frame: RTCVideoFrame?) {
        guard let frame else { return }
        guard let pixelBuffer = RemoteVideoLayerRenderer.pixelBuffer(from: frame, pool: &conversionPool) else { return }
        report(size: CGSize(width: Int(frame.width), height: Int(frame.height)))
        enqueue(pixelBuffer, timeStampNs: frame.timeStampNs)
    }

    // MARK: Internals

    private func report(size: CGSize) {
        guard size.width > 0, size.height > 0 else { return }
        lock.lock()
        let changed = size != lastSize
        if changed { lastSize = size }
        lock.unlock()
        guard changed else { return }
        DispatchQueue.main.async { [weak self] in self?.onVideoSizeChange?(size) }
    }

    private func enqueue(_ pixelBuffer: CVPixelBuffer, timeStampNs: Int64) {
        if formatDescription == nil ||
            !CMVideoFormatDescriptionMatchesImageBuffer(formatDescription!, imageBuffer: pixelBuffer) {
            var description: CMVideoFormatDescription?
            guard CMVideoFormatDescriptionCreateForImageBuffer(
                allocator: kCFAllocatorDefault, imageBuffer: pixelBuffer,
                formatDescriptionOut: &description) == noErr, let description else { return }
            formatDescription = description
        }
        guard let formatDescription else { return }

        var timing = CMSampleTimingInfo(
            duration: .invalid,
            presentationTimeStamp: CMTime(value: timeStampNs, timescale: 1_000_000_000),
            decodeTimeStamp: .invalid)
        var sampleBuffer: CMSampleBuffer?
        guard CMSampleBufferCreateReadyWithImageBuffer(
            allocator: kCFAllocatorDefault, imageBuffer: pixelBuffer,
            formatDescription: formatDescription, sampleTiming: &timing,
            sampleBufferOut: &sampleBuffer) == noErr, let sampleBuffer else { return }

        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: true),
           CFArrayGetCount(attachments) > 0 {
            let entry = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(entry,
                                 Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                                 Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        }

        if displayLayer.status == .failed {
            displayLayer.flush()
        }
        displayLayer.enqueue(sampleBuffer)
        renderedFrames += 1
        dumpFrameIfRequested(pixelBuffer)
        if renderedFrames % 60 == 0 {
            RCLog.info("rendered \(renderedFrames) frames, \(Int(lastSize.width))x\(Int(lastSize.height)), layer status \(displayLayer.status.rawValue)")
        }
    }

    private func dumpFrameIfRequested(_ pixelBuffer: CVPixelBuffer) {
        guard !hasDumpedFrame, renderedFrames >= 60,
              let path = ProcessInfo.processInfo.environment["RC_DUMP_FRAME"] else { return }
        hasDumpedFrame = true
        let image = CIImage(cvPixelBuffer: pixelBuffer)
        let representation = NSCIImageRep(ciImage: image)
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil,
                                      pixelsWide: Int(image.extent.width),
                                      pixelsHigh: Int(image.extent.height),
                                      bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                      isPlanar: false, colorSpaceName: .deviceRGB,
                                      bytesPerRow: 0, bitsPerPixel: 0)
        guard let bitmap else { return }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        representation.draw(in: image.extent)
        NSGraphicsContext.restoreGraphicsState()
        guard let data = bitmap.representation(using: .png, properties: [:]) else { return }
        try? data.write(to: URL(fileURLWithPath: path))
        RCLog.info("wrote a decoded frame to \(path)")
    }
    private var hasDumpedFrame = false

    private static func pixelBuffer(from frame: RTCVideoFrame,
                                    pool: inout CVPixelBufferPool?) -> CVPixelBuffer? {
        if let native = frame.buffer as? RTCCVPixelBuffer { return native.pixelBuffer }
        guard let i420 = frame.buffer.toI420() as? RTCI420Buffer else { return nil }
        let width = Int(i420.width), height = Int(i420.height)
        if pool == nil {
            let attributes: [String: Any] = [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height,
                kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
            ]
            var created: CVPixelBufferPool?
            guard CVPixelBufferPoolCreate(kCFAllocatorDefault, nil,
                                          attributes as CFDictionary, &created) == kCVReturnSuccess else { return nil }
            pool = created
        }
        guard let pool else { return nil }
        var buffer: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &buffer) == kCVReturnSuccess,
              let pixelBuffer = buffer,
              CVPixelBufferGetWidth(pixelBuffer) == width,
              CVPixelBufferGetHeight(pixelBuffer) == height else { return nil }

        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }
        if let destination = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0) {
            let stride = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0)
            let bytes = destination.assumingMemoryBound(to: UInt8.self)
            for row in 0..<height {
                memcpy(bytes + row * stride, i420.dataY + row * Int(i420.strideY), width)
            }
        }
        if let destination = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 1) {
            let stride = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 1)
            let bytes = destination.assumingMemoryBound(to: UInt8.self)
            let chromaWidth = Int(i420.chromaWidth), chromaHeight = Int(i420.chromaHeight)
            for row in 0..<chromaHeight {
                let line = bytes + row * stride
                let u = i420.dataU + row * Int(i420.strideU)
                let v = i420.dataV + row * Int(i420.strideV)
                for column in 0..<chromaWidth {
                    line[column * 2] = u[column]
                    line[column * 2 + 1] = v[column]
                }
            }
        }
        return pixelBuffer
    }
}

public final class RemoteScreenNSView: NSView {

    public var onPointerSample: ((RemotePointerSample, PointerEventKind) -> Void)?
    public var onPointerEvent: ((RemotePointerEvent) -> Void)?
    public var isCapturingKeyboard = false { didSet { needsDisplay = true } }
    public var onVideoSizeChange: ((CGSize) -> Void)?
    public var cursorShape: CursorShape = .arrow {
        didSet {
            guard cursorShape != oldValue else { return }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            cursorLayer.path = cursorShape.path
            CATransaction.commit()
        }
    }

    public private(set) var videoSize: CGSize = .zero
    public var remoteDisplaySize: CGSize = .zero {
        didSet { if remoteDisplaySize != oldValue { needsLayout = true } }
    }

    public let renderer = RemoteVideoLayerRenderer()
    private var trackingArea: NSTrackingArea?

    private let cursorLayer = CAShapeLayer()
    deinit { if cursorHidden { NSCursor.unhide() } }
    private weak var attachedTrack: RTCVideoTrack?

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        renderer.displayLayer.frame = bounds
        layer?.addSublayer(renderer.displayLayer)
        configureCursorLayer()
        renderer.onVideoSizeChange = { [weak self] size in
            guard let self else { return }
            self.videoSize = size
            self.needsLayout = true
            self.onVideoSizeChange?(size)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    public override var isFlipped: Bool { true }

    public func attach(track: RTCVideoTrack?) {
        guard track !== attachedTrack else { return }
        attachedTrack?.remove(renderer)
        attachedTrack = track
        guard let track else {
            videoSize = .zero
            return
        }
        track.add(renderer)
    }

    public var geometry: RemoteDisplayGeometry {
        let remote = remoteDisplaySize.width > 0 ? remoteDisplaySize : videoSize
        return RemoteDisplayGeometry(remoteSize: remote, viewSize: bounds.size)
    }

    public override func layout() {
        super.layout()
        let rect = geometry.videoRect
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        renderer.displayLayer.frame = rect.isEmpty ? bounds : rect
        renderer.displayLayer.isHidden = videoSize == .zero
        CATransaction.commit()
    }

    // MARK: Pointer

    public override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: bounds,
                                  options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    private func report(_ event: NSEvent, _ kind: PointerEventKind, button: MouseButton = .left) {
        let point = convert(event.locationInWindow, from: nil)
        moveCursorLayer(to: point)
        guard let sample = geometry.sample(atView: point, clamp: kind.clampsOutsideVideo) else { return }
        onPointerSample?(sample, kind)

        var delta = CGSize.zero
        var phase = ScrollPhase.changed
        if kind == .scroll {
            delta = geometry.remoteDelta(fromViewDelta: CGSize(width: event.scrollingDeltaX,
                                                               height: event.scrollingDeltaY))
            phase = RemoteScreenNSView.scrollPhase(of: event)
        }
        onPointerEvent?(RemotePointerEvent(
            sample: sample,
            kind: kind,
            button: button,
            clickCount: kind == .down || kind == .up ? max(1, event.clickCount) : 1,
            scrollDelta: delta,
            scrollPhase: phase,
            modifiers: KeyModifiers(appKitFlags: event.modifierFlags)))
    }

    static func scrollPhase(of event: NSEvent) -> ScrollPhase {
        if !event.momentumPhase.isEmpty {
            return event.momentumPhase.contains(.ended) ? .end : .momentum
        }
        if event.phase.contains(.began) || event.phase.contains(.mayBegin) { return .begin }
        if event.phase.contains(.ended) || event.phase.contains(.cancelled) { return .end }
        return .changed
    }

    public override func mouseMoved(with event: NSEvent) {
        hideLocalCursor()
        report(event, .move)
    }

    // MARK: Local cursor

    private var cursorHidden = false

    private var isShowingVideo: Bool { renderer.renderedFrames > 0 }

    private func configureCursorLayer() {
        cursorLayer.path = cursorShape.path
        cursorLayer.fillColor = NSColor.black.cgColor
        cursorLayer.strokeColor = NSColor.white.cgColor
        cursorLayer.lineWidth = 1.2
        cursorLayer.lineJoin = .round
        cursorLayer.bounds = CGRect(x: 0, y: 0, width: 14, height: 20)
        cursorLayer.anchorPoint = .zero
        cursorLayer.isHidden = true
        cursorLayer.zPosition = 10
        layer?.addSublayer(cursorLayer)
    }

    private var canDrawLocalCursor: Bool { cursorLayer.path != nil }

    private func moveCursorLayer(to point: CGPoint) {
        guard isShowingVideo else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        cursorLayer.position = point
        cursorLayer.isHidden = false
        CATransaction.commit()
    }

    private func hideCursorLayer() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        cursorLayer.isHidden = true
        CATransaction.commit()
    }

    private func hideLocalCursor() {
        guard canDrawLocalCursor else { return }
        guard !cursorHidden, isShowingVideo, window?.isKeyWindow == true else { return }
        NSCursor.hide()
        cursorHidden = true
    }

    private func showLocalCursor() {
        guard cursorHidden else { return }
        NSCursor.unhide()
        cursorHidden = false
    }

    public override func mouseEntered(with event: NSEvent) { hideLocalCursor() }
    public override func mouseExited(with event: NSEvent) {
        showLocalCursor()
        hideCursorLayer()
    }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { showLocalCursor() }
        observeFocusLoss()
    }

    private func observeFocusLoss() {
        let centre = NotificationCenter.default
        for name in [NSWindow.didResignKeyNotification, NSApplication.didResignActiveNotification] {
            centre.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.showLocalCursor() }
            }
        }
    }
    public override func mouseDragged(with event: NSEvent) { report(event, .drag, button: .left) }
    public override func rightMouseDragged(with event: NSEvent) { report(event, .drag, button: .right) }
    public override func otherMouseDragged(with event: NSEvent) { report(event, .drag, button: .middle) }
    public override func mouseDown(with event: NSEvent) { report(event, .down, button: .left) }
    public override func mouseUp(with event: NSEvent) { report(event, .up, button: .left) }
    public override func rightMouseDown(with event: NSEvent) { report(event, .down, button: .right) }
    public override func rightMouseUp(with event: NSEvent) { report(event, .up, button: .right) }
    public override func otherMouseDown(with event: NSEvent) { report(event, .down, button: .middle) }
    public override func otherMouseUp(with event: NSEvent) { report(event, .up, button: .middle) }
    public override func scrollWheel(with event: NSEvent) { report(event, .scroll) }

    public override var acceptsFirstResponder: Bool { true }
    public override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

// MARK: - SwiftUI

public struct RemoteScreenView: NSViewRepresentable {

    @ObservedObject private var session: SessionCoordinator
    private let onPointerSample: ((RemotePointerSample, PointerEventKind) -> Void)?
    private let onVideoSizeChange: ((CGSize) -> Void)?
    private let capturingKeyboard: Bool

    public init(session: SessionCoordinator,
                capturingKeyboard: Bool = false,
                onVideoSizeChange: ((CGSize) -> Void)? = nil,
                onPointerSample: ((RemotePointerSample, PointerEventKind) -> Void)? = nil) {
        self.session = session
        self.capturingKeyboard = capturingKeyboard
        self.onVideoSizeChange = onVideoSizeChange
        self.onPointerSample = onPointerSample
    }

    public func makeNSView(context: Context) -> RemoteScreenNSView {
        let view = RemoteScreenNSView(frame: .zero)
        view.onPointerSample = onPointerSample
        view.onVideoSizeChange = onVideoSizeChange
        view.onPointerEvent = { [weak session] event in session?.sendPointer(event) }
        return view
    }

    public func updateNSView(_ view: RemoteScreenNSView, context: Context) {
        view.onPointerSample = onPointerSample
        view.onVideoSizeChange = onVideoSizeChange
        view.isCapturingKeyboard = capturingKeyboard
        view.onPointerEvent = { [weak session] event in session?.sendPointer(event) }
        if let info = session.remoteDisplay {
            view.remoteDisplaySize = CGSize(width: Double(info.w), height: Double(info.h))
        }
        view.cursorShape = session.remoteCursorShape
        view.attach(track: session.remoteTrack)
    }

    public static func dismantleNSView(_ view: RemoteScreenNSView, coordinator: ()) {
        view.attach(track: nil)
    }
}
#endif
