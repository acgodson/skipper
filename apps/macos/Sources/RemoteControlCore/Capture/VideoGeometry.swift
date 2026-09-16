import Foundation
import CoreGraphics

/// The letterbox maths that turns a point in the controller's view into a point
/// on the host's display, and back.
///
/// WHY THIS IS ITS OWN FILE, WITH TESTS, IN PHASE 4:
/// Phase 5 injects mouse events from these numbers. If the conversion is off by
/// the letterbox offset, or by the backing scale, or by a half-pixel, nothing
/// *fails* — the pointer simply lands somewhere slightly wrong, drags slide, and
/// the product feels broken in a way that is very hard to bisect later. So the
/// conversion is written and pinned to exact expected values now, before any
/// input code depends on it.
///
/// Conventions (PROTOCOL.md §0):
///   * View coordinates here are **top-left origin, y down**. AppKit hands out
///     bottom-left origin points, so the view layer flips once, at the boundary,
///     and everything below this line is top-left.
///   * Normalised coordinates are `[0, 1]`, x left→right, y top→bottom of the
///     host's captured display. That is what goes on the wire — never pixels —
///     so resizing the controller window cannot change the remote resolution.
public struct RemoteDisplayGeometry: Equatable {

    /// Pixel size of the host's captured display (from `display_info`).
    public let remoteSize: CGSize
    /// Size of the container view the video is drawn into.
    public let viewSize: CGSize

    public init(remoteSize: CGSize, viewSize: CGSize) {
        self.remoteSize = remoteSize
        self.viewSize = viewSize
    }

    public init(remote: DisplayInfoPayload, viewSize: CGSize) {
        self.init(remoteSize: CGSize(width: Double(remote.w), height: Double(remote.h)),
                  viewSize: viewSize)
    }

    /// True when both sizes are usable. Every conversion is undefined otherwise
    /// and returns nil / .zero rather than a NaN that would propagate silently.
    public var isValid: Bool {
        remoteSize.width > 0 && remoteSize.height > 0 && viewSize.width > 0 && viewSize.height > 0
    }

    /// Aspect-**fit**: the whole remote screen is visible, with black bars on the
    /// two axes that do not bind. Never aspect-fill — cropping the remote screen
    /// would hide a menu bar or a Dock the user is trying to click.
    public var videoRect: CGRect {
        RemoteDisplayGeometry.aspectFit(content: remoteSize, within: viewSize)
    }

    /// One scalar because the fit is uniform: remote pixels per view point.
    public var scale: CGFloat {
        guard isValid else { return 0 }
        return remoteSize.width / videoRect.width
    }

    public static func aspectFit(content: CGSize, within container: CGSize) -> CGRect {
        guard content.width > 0, content.height > 0,
              container.width > 0, container.height > 0 else { return .zero }
        let contentAspect = content.width / content.height
        let containerAspect = container.width / container.height
        var size: CGSize
        if contentAspect > containerAspect {
            // Wider than the container: width binds, bars top and bottom.
            size = CGSize(width: container.width, height: container.width / contentAspect)
        } else {
            // Taller (or equal): height binds, bars left and right.
            size = CGSize(width: container.height * contentAspect, height: container.height)
        }
        let origin = CGPoint(x: (container.width - size.width) / 2,
                             y: (container.height - size.height) / 2)
        return CGRect(origin: origin, size: size)
    }

    // MARK: - View -> remote

    /// Remote **pixel** coordinates, or nil when the point is in a letterbox bar
    /// (or outside the view entirely). nil means "not on the remote screen" and
    /// callers must not invent a position for it.
    public func remotePixel(fromView point: CGPoint) -> CGPoint? {
        guard isValid else { return nil }
        let rect = videoRect
        guard point.x >= rect.minX, point.x <= rect.maxX,
              point.y >= rect.minY, point.y <= rect.maxY else { return nil }
        return CGPoint(x: (point.x - rect.minX) * scale,
                       y: (point.y - rect.minY) * scale)
    }

    /// Normalised `[0,1]` coordinates for the wire, or nil outside the video.
    public func normalized(fromView point: CGPoint) -> CGPoint? {
        guard let pixel = remotePixel(fromView: point) else { return nil }
        return CGPoint(x: pixel.x / remoteSize.width, y: pixel.y / remoteSize.height)
    }

    /// Normalised coordinates with the point clamped to the video area first.
    ///
    /// This is the right behaviour *during a drag*: the pointer leaving the
    /// video while a button is held must keep dragging along the edge, not
    /// teleport or stall (PLAN.md §2.6). It is the wrong behaviour for a fresh
    /// click, which is why the clamping variant is separate and explicit.
    public func clampedNormalized(fromView point: CGPoint) -> CGPoint {
        guard isValid else { return .zero }
        let rect = videoRect
        let x = min(max(point.x, rect.minX), rect.maxX)
        let y = min(max(point.y, rect.minY), rect.maxY)
        let px = (x - rect.minX) * scale
        let py = (y - rect.minY) * scale
        return CGPoint(x: min(max(px / remoteSize.width, 0), 1),
                       y: min(max(py / remoteSize.height, 0), 1))
    }

    /// A view-space delta (a scroll gesture, a drag increment) in remote pixels.
    /// PROTOCOL.md §5 specifies `scroll` in host pixel units, so this is the
    /// conversion the scroll handler will use in Phase 5.
    public func remoteDelta(fromViewDelta delta: CGSize) -> CGSize {
        guard isValid else { return .zero }
        return CGSize(width: delta.width * scale, height: delta.height * scale)
    }

    // MARK: - Remote -> view

    /// Inverse of `remotePixel(fromView:)`. Used to draw a remote-space overlay
    /// (a cursor, a highlight) at the right place in the view.
    public func viewPoint(fromRemotePixel point: CGPoint) -> CGPoint {
        guard isValid else { return .zero }
        let rect = videoRect
        return CGPoint(x: rect.minX + point.x / scale, y: rect.minY + point.y / scale)
    }

    public func viewPoint(fromNormalized point: CGPoint) -> CGPoint {
        viewPoint(fromRemotePixel: CGPoint(x: point.x * remoteSize.width,
                                           y: point.y * remoteSize.height))
    }
}

/// One pointer position, in every space anyone downstream needs it in.
/// Phase 5 sends `normalized`; diagnostics show `remotePixel`.
public struct RemotePointerSample: Equatable {
    public let viewPoint: CGPoint
    public let remotePixel: CGPoint
    public let normalized: CGPoint
    /// False when the raw point was outside the video and had to be clamped.
    public let insideVideo: Bool

    public init(viewPoint: CGPoint, remotePixel: CGPoint, normalized: CGPoint, insideVideo: Bool) {
        self.viewPoint = viewPoint
        self.remotePixel = remotePixel
        self.normalized = normalized
        self.insideVideo = insideVideo
    }
}

public extension RemoteDisplayGeometry {
    /// The one call the view layer makes. `clamp: true` is for drags.
    func sample(atView point: CGPoint, clamp: Bool) -> RemotePointerSample? {
        guard isValid else { return nil }
        if let pixel = remotePixel(fromView: point) {
            return RemotePointerSample(
                viewPoint: point,
                remotePixel: pixel,
                normalized: CGPoint(x: pixel.x / remoteSize.width, y: pixel.y / remoteSize.height),
                insideVideo: true)
        }
        guard clamp else { return nil }
        let normalized = clampedNormalized(fromView: point)
        return RemotePointerSample(
            viewPoint: point,
            remotePixel: CGPoint(x: normalized.x * remoteSize.width,
                                 y: normalized.y * remoteSize.height),
            normalized: normalized,
            insideVideo: false)
    }
}
