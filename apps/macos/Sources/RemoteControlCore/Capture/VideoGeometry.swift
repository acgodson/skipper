import Foundation
import CoreGraphics

public struct RemoteDisplayGeometry: Equatable {

    public let remoteSize: CGSize
    public let viewSize: CGSize

    public init(remoteSize: CGSize, viewSize: CGSize) {
        self.remoteSize = remoteSize
        self.viewSize = viewSize
    }

    public init(remote: DisplayInfoPayload, viewSize: CGSize) {
        self.init(remoteSize: CGSize(width: Double(remote.w), height: Double(remote.h)),
                  viewSize: viewSize)
    }

    public var isValid: Bool {
        remoteSize.width > 0 && remoteSize.height > 0 && viewSize.width > 0 && viewSize.height > 0
    }

    public var videoRect: CGRect {
        RemoteDisplayGeometry.aspectFit(content: remoteSize, within: viewSize)
    }

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
            size = CGSize(width: container.width, height: container.width / contentAspect)
        } else {
            size = CGSize(width: container.height * contentAspect, height: container.height)
        }
        let origin = CGPoint(x: (container.width - size.width) / 2,
                             y: (container.height - size.height) / 2)
        return CGRect(origin: origin, size: size)
    }

    // MARK: - View -> remote

    public func remotePixel(fromView point: CGPoint) -> CGPoint? {
        guard isValid else { return nil }
        let rect = videoRect
        guard point.x >= rect.minX, point.x <= rect.maxX,
              point.y >= rect.minY, point.y <= rect.maxY else { return nil }
        return CGPoint(x: (point.x - rect.minX) * scale,
                       y: (point.y - rect.minY) * scale)
    }

    public func normalized(fromView point: CGPoint) -> CGPoint? {
        guard let pixel = remotePixel(fromView: point) else { return nil }
        return CGPoint(x: pixel.x / remoteSize.width, y: pixel.y / remoteSize.height)
    }

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

    public func remoteDelta(fromViewDelta delta: CGSize) -> CGSize {
        guard isValid else { return .zero }
        return CGSize(width: delta.width * scale, height: delta.height * scale)
    }

    // MARK: - Remote -> view

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

public struct RemotePointerSample: Equatable {
    public let viewPoint: CGPoint
    public let remotePixel: CGPoint
    public let normalized: CGPoint
    public let insideVideo: Bool

    public init(viewPoint: CGPoint, remotePixel: CGPoint, normalized: CGPoint, insideVideo: Bool) {
        self.viewPoint = viewPoint
        self.remotePixel = remotePixel
        self.normalized = normalized
        self.insideVideo = insideVideo
    }
}

public extension RemoteDisplayGeometry {
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
