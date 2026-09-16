#if canImport(AppKit)
import AppKit
import AVFoundation
import CoreImage
import CoreMedia
import CoreVideo
import SwiftUI
import WebRTC

/// The controller's view of the host's screen.
///
/// **Renderer choice, and a deviation from PLAN.md §1 worth reading.** The plan
/// names `RTCMTLNSVideoView`. That class does not exist in this build of
/// libwebrtc: `stasel/WebRTC` 125.0.0 ships the *header* but no implementation
/// in any slice of the xcframework —
/// `nm -gU WebRTC | grep RTCMTL` is empty for macos, ios, catalyst and
/// simulator alike, because the Metal renderer needs Xcode's shader compiler at
/// build time and these binaries are produced without it. Linking against it
/// fails with `Undefined symbols: _OBJC_CLASS_$_RTCMTLNSVideoView`.
///
/// So this file implements `RTCVideoRenderer` directly on top of
/// `AVSampleBufferDisplayLayer`. That keeps every property the plan actually
/// wanted from the Metal view: the decoded `CVPixelBuffer` comes straight out of
/// VideoToolbox, is wrapped (not copied) into a `CMSampleBuffer`, and is
/// composited on the GPU. There is no per-frame CPU conversion and no
/// `NSImage` anywhere in the path.
public final class RemoteVideoLayerRenderer: NSObject, RTCVideoRenderer {

    public let displayLayer = AVSampleBufferDisplayLayer()
    /// Reported on the main queue whenever the decoded frame size changes —
    /// which is also how the UI learns the first frame has arrived.
    public var onVideoSizeChange: ((CGSize) -> Void)?
    /// Every frame that reached the layer. The UI shows it; nothing can make it
    /// climb except decoded video.
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

    /// Called by libwebrtc on its decode thread; the useful size comes with the
    /// frame itself, so this is only a hint.
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

        // Remote control is interactive: a frame is worth showing now or not at
        // all. DisplayImmediately bypasses the layer's timebase entirely, which
        // is what keeps added latency at "one frame" instead of "one buffer".
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: true),
           CFArrayGetCount(attachments) > 0 {
            let entry = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(entry,
                                 Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                                 Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        }

        if displayLayer.status == .failed {
            // The layer fails hard (e.g. after a GPU reset) and stays failed
            // until flushed. Silently dropping every frame afterwards would look
            // exactly like "the session died", so recover instead.
            displayLayer.flush()
        }
        displayLayer.enqueue(sampleBuffer)
        renderedFrames += 1
        dumpFrameIfRequested(pixelBuffer)
        // Under RC_DEBUG this is the difference between "the window is black
        // because no frames arrive" and "…because they arrive and do not draw".
        if renderedFrames % 60 == 0 {
            RCLog.info("rendered \(renderedFrames) frames, \(Int(lastSize.width))x\(Int(lastSize.height)), layer status \(displayLayer.status.rawValue)")
        }
    }

    /// Writes one decoded frame to a PNG when `RC_DUMP_FRAME=/path/out.png` is
    /// set, after the stream has settled.
    ///
    /// Diagnostics, not a feature. `AVSampleBufferDisplayLayer` content is
    /// composited by the window server and does NOT appear in an in-process
    /// `cacheDisplay` snapshot, so a screenshot of our own window shows the
    /// video area as black even when it is perfectly alive on screen. This
    /// writes the actual decoded pixels, which is the thing one really wants to
    /// look at when asking "is the remote desktop arriving?".
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

    /// VideoToolbox hands back a `CVPixelBuffer` (the fast path). A software
    /// decode produces I420, which has to be packed into NV12 first — rare, but
    /// dropping those frames would mean a black window on the one machine that
    /// fell back.
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

/// The remote desktop, letterboxed inside a black container.
///
/// The display layer is sized to the aspect-fit rect rather than filling the
/// container, for two reasons that both matter:
///   1. Aspect ratio is preserved by construction — the remote screen can never
///      be stretched, whatever shape the window is.
///   2. The rect the pixels occupy is then *known* to this layer, so the
///      view→remote coordinate conversion (`RemoteDisplayGeometry`) is computed
///      against the same numbers AppKit is drawing with rather than against an
///      assumption about what the renderer did internally. Phase 5's pointer
///      accuracy rests on that.
///
/// Resizing this view never tells the host anything: the remote resolution is
/// the host's business, and coordinates on the wire are normalised (PLAN.md §2).
public final class RemoteScreenNSView: NSView {

    /// Every pointer sample, already converted into the remote display's space.
    /// Kept for the toolbar's live read-out.
    public var onPointerSample: ((RemotePointerSample, PointerEventKind) -> Void)?
    /// PHASE 5: the full event — button, click count, scroll delta and phase —
    /// on top of the same `RemoteDisplayGeometry` sample. This is what the
    /// input sender consumes.
    public var onPointerEvent: ((RemotePointerEvent) -> Void)?
    /// True while "Capture keyboard" is on, purely so this view can draw the
    /// focus ring that tells the user where their keystrokes are going.
    public var isCapturingKeyboard = false { didSet { needsDisplay = true } }
    /// Fires when the first frame arrives, and on any later size change.
    public var onVideoSizeChange: ((CGSize) -> Void)?

    public private(set) var videoSize: CGSize = .zero
    /// Size of the host's display in pixels, from `display_info`. Preferred over
    /// the decoded frame size because quality scaling changes the latter while
    /// the aspect ratio and the coordinate space stay the host's.
    public var remoteDisplaySize: CGSize = .zero {
        didSet { if remoteDisplaySize != oldValue { needsLayout = true } }
    }

    public let renderer = RemoteVideoLayerRenderer()
    private var trackingArea: NSTrackingArea?

    /// Locally drawn pointer, positioned from the REAL mouse, not from the video.
    ///
    /// WHY: the cursor you saw before was the host's, captured and streamed back,
    /// so it could not appear until a full round trip had completed —
    /// send input -> host injects -> host redraws -> capture -> H.264 encode ->
    /// network -> decode -> present. Even on a perfect link that is one or two
    /// frame intervals plus codec time; over a relay it is far worse. No amount
    /// of network tuning removes it, because it is a feedback loop, not a delay.
    ///
    /// Drawing the pointer locally breaks the loop: it moves with the hand at
    /// screen refresh rate while the rest of the frame catches up. This is what
    /// Parsec and Moonlight do, and it is the single biggest factor in whether
    /// remote control feels responsive.
    ///
    /// A CALayer is used rather than `draw(_:)` because repositioning a layer is
    /// GPU-composited and costs no redraw of the video underneath.
    private let cursorLayer = CAShapeLayer()
    // Restoring the cursor on teardown is not optional — see hideLocalCursor().
    deinit { if cursorHidden { NSCursor.unhide() } }
    private weak var attachedTrack: RTCVideoTrack?

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        renderer.displayLayer.frame = bounds
        layer?.addSublayer(renderer.displayLayer)
        configureCursorLayer()   // AFTER the video layer, or it is painted over
        renderer.onVideoSizeChange = { [weak self] size in
            guard let self else { return }
            self.videoSize = size
            self.needsLayout = true
            self.onVideoSizeChange?(size)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    /// Top-left origin, so every coordinate in this file and in
    /// `RemoteDisplayGeometry` is in the same space as the remote screen.
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

    /// The geometry the pointer conversion and the letterbox share.
    public var geometry: RemoteDisplayGeometry {
        let remote = remoteDisplaySize.width > 0 ? remoteDisplaySize : videoSize
        return RemoteDisplayGeometry(remoteSize: remote, viewSize: bounds.size)
    }

    public override func layout() {
        super.layout()
        let rect = geometry.videoRect
        CATransaction.begin()
        CATransaction.setDisableActions(true)   // no implicit animation on resize
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

    /// AppKit hands out bottom-left origin window coordinates; `isFlipped`
    /// makes `convert(_:from: nil)` produce top-left ones for this view. Doing
    /// the flip here, once, is why nothing downstream has to think about it.
    private func report(_ event: NSEvent, _ kind: PointerEventKind, button: MouseButton = .left) {
        let point = convert(event.locationInWindow, from: nil)
        moveCursorLayer(to: point)
        // A drag clamps: the pointer leaving the video mid-drag must keep
        // dragging along the edge, not stop dead (PLAN.md §2.6).
        guard let sample = geometry.sample(atView: point, clamp: kind.clampsOutsideVideo) else { return }
        onPointerSample?(sample, kind)

        var delta = CGSize.zero
        var phase = ScrollPhase.changed
        if kind == .scroll {
            // The SAME geometry converts the scroll delta into remote pixels
            // that PROTOCOL.md §5 asks for. Signs are passed through unchanged:
            // both ends are macOS and share NSEvent's convention, so a natural
            // -scrolling controller feels natural on the host too.
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

    /// NSEvent splits the gesture into `phase` (finger on the trackpad) and
    /// `momentumPhase` (coasting after lift-off). PROTOCOL.md §5 carries one
    /// field, so momentum wins when it is present — that is what keeps inertial
    /// scrolling smooth on the far side instead of stopping dead at lift-off.
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

    /// Hide the CONTROLLER's own pointer while it is over the remote screen.
    ///
    /// The host's cursor is already painted into the captured video, so without
    /// this you see two pointers — yours floating on top of his — and aiming
    /// becomes guesswork. Screen Sharing and AnyDesk both hide the local one.
    ///
    /// SAFETY, and it matters: `NSCursor.hide()`/`unhide()` are a NESTED COUNTER,
    /// not a toggle. An unbalanced hide leaves the user with no cursor anywhere
    /// in macOS — close to unrecoverable for a non-technical user without a
    /// reboot. `cursorHidden` pins the counter to 0 or 1, and EVERY path that can
    /// take the pointer away restores it: exiting the view, the window losing
    /// key, the app deactivating (Cmd-Tab), the view leaving its window, and
    /// deinit.
    private var cursorHidden = false

    /// Only hide once video is actually on screen. Hiding the pointer over a
    /// black "waiting for video" view would just blind the user.
    private var isShowingVideo: Bool { renderer.renderedFrames > 0 }

    /// Builds the pointer as a VECTOR PATH rather than from `NSCursor.arrow.image`.
    ///
    /// The bitmap route looked obvious and was wrong: `NSCursor.arrow.image` is
    /// served by the window server, and in a process without that connection it
    /// comes back zero-sized. The layer then has no contents, draws nothing, and
    /// — because the system cursor is hidden — the user is left with no pointer
    /// at all. A path has no such dependency, and is resolution-independent, so
    /// it stays crisp on any display without juggling contentsScale.
    private func configureCursorLayer() {
        let path = CGMutablePath()
        // Classic arrow, tip at (0,0), y increasing downward.
        path.addLines(between: [
            CGPoint(x: 0,    y: 0),
            CGPoint(x: 0,    y: 16.5),
            CGPoint(x: 4.2,  y: 12.7),
            CGPoint(x: 6.8,  y: 18.4),
            CGPoint(x: 9.3,  y: 17.2),
            CGPoint(x: 6.7,  y: 11.7),
            CGPoint(x: 11.6, y: 11.4),
        ])
        path.closeSubpath()

        cursorLayer.path = path
        cursorLayer.fillColor = NSColor.black.cgColor
        // White outline so it stays visible over dark windows, exactly as the
        // real macOS pointer does.
        cursorLayer.strokeColor = NSColor.white.cgColor
        cursorLayer.lineWidth = 1.2
        cursorLayer.lineJoin = .round
        cursorLayer.bounds = CGRect(x: 0, y: 0, width: 14, height: 20)
        // Origin at the tip: the drawn point is exactly where a click lands.
        cursorLayer.anchorPoint = .zero
        cursorLayer.isHidden = true
        cursorLayer.zPosition = 10
        layer?.addSublayer(cursorLayer)
    }

    /// True only if we can actually draw a pointer.
    ///
    /// SAFETY RULE, learned the hard way: never hide the system cursor unless a
    /// replacement is genuinely on screen. Hiding it and then failing to draw
    /// leaves the user with no pointer at all, which is far worse than the
    /// double-cursor this was meant to solve.
    private var canDrawLocalCursor: Bool { cursorLayer.path != nil }

    private func moveCursorLayer(to point: CGPoint) {
        guard isShowingVideo else { return }
        // No implicit animation: an eased cursor is worse than a late one.
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
        guard canDrawLocalCursor else { return }   // no replacement -> keep the real one
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
        // Leaving a window (session ended, view torn down) must never strand a
        // hidden cursor.
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

    /// The view accepts first responder so a click focuses it; keyboard capture
    /// keys off window focus, not on this, but a view that cannot be focused
    /// makes "is my typing going to the other Mac?" impossible to answer.
    public override var acceptsFirstResponder: Bool { true }
    public override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

// MARK: - SwiftUI

/// SwiftUI wrapper. Takes the coordinator rather than a track so that no
/// libwebrtc type appears in the app target's UI code.
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
        // Straight into the session's input sender: every pointer event the
        // view produces goes on the wire, converted once, by the geometry the
        // view is already drawing with.
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
        view.attach(track: session.remoteTrack)
    }

    public static func dismantleNSView(_ view: RemoteScreenNSView, coordinator: ()) {
        view.attach(track: nil)
    }
}
#endif
