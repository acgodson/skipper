import CoreGraphics
import Foundation

public enum CursorShape: String, CaseIterable, Codable, Equatable, Sendable {
    case arrow
    case iBeam = "ibeam"
    case crosshair
    case pointingHand = "pointing_hand"
    case openHand = "open_hand"
    case closedHand = "closed_hand"
    case resizeLeftRight = "resize_lr"
    case resizeUpDown = "resize_ud"
    case resizeDiagonalNESW = "resize_diag_nesw"
    case resizeDiagonalNWSE = "resize_diag_nwse"
    case notAllowed = "not_allowed"
    case busy

    public init(wire: String) { self = CursorShape(rawValue: wire) ?? .arrow }
}

public struct CursorShapePayload: Codable, Equatable {
    public var shape: String
    public init(_ shape: CursorShape) { self.shape = shape.rawValue }
    public init(shape: String) { self.shape = shape }
    public var cursorShape: CursorShape { CursorShape(wire: shape) }
}

// Glyphs are drawn in a y-down space with the hot spot at the origin, so a layer
// positioned at the pointer puts the hot spot exactly under it at any scale.
public extension CursorShape {

    var path: CGPath {
        switch self {
        case .arrow: return CursorGlyph.arrow
        case .iBeam: return CursorGlyph.iBeam
        case .crosshair: return CursorGlyph.crosshair
        case .pointingHand: return CursorGlyph.pointingHand
        case .openHand: return CursorGlyph.openHand
        case .closedHand: return CursorGlyph.closedHand
        case .resizeLeftRight: return CursorGlyph.doubleArrow(angle: 0)
        case .resizeUpDown: return CursorGlyph.doubleArrow(angle: .pi / 2)
        case .resizeDiagonalNESW: return CursorGlyph.doubleArrow(angle: -.pi / 4)
        case .resizeDiagonalNWSE: return CursorGlyph.doubleArrow(angle: .pi / 4)
        case .notAllowed: return CursorGlyph.notAllowed
        case .busy: return CursorGlyph.hourglass
        }
    }
}

enum CursorGlyph {

    static let arrow = polygon([
        (0, 0), (0, 16.5), (4.2, 12.7), (6.8, 18.4), (9.3, 17.2), (6.7, 11.7), (11.6, 11.4),
    ], hotSpot: .zero)

    static let iBeam = polygon([
        (0, 0), (8, 0), (8, 1.6), (4.8, 1.6), (4.8, 16.4), (8, 16.4),
        (8, 18), (0, 18), (0, 16.4), (3.2, 16.4), (3.2, 1.6), (0, 1.6),
    ], hotSpot: CGPoint(x: 4, y: 9))

    static let crosshair: CGPath = {
        let c: CGFloat = 10.5, t: CGFloat = 0.9, end: CGFloat = 21
        return polygon([
            (c - t, 0), (c + t, 0), (c + t, c - t), (end, c - t), (end, c + t), (c + t, c + t),
            (c + t, end), (c - t, end), (c - t, c + t), (0, c + t), (0, c - t), (c - t, c - t),
        ], hotSpot: CGPoint(x: c, y: c))
    }()

    static let pointingHand = union([
        CGRect(x: 5, y: 0, width: 4, height: 12),
        CGRect(x: 3, y: 9, width: 14, height: 13),
        CGRect(x: 9, y: 7, width: 3.6, height: 6),
        CGRect(x: 12.4, y: 8, width: 3.6, height: 6),
        CGRect(x: 0, y: 12, width: 5, height: 5),
    ], radius: 1.8, hotSpot: CGPoint(x: 7, y: 0))

    static let openHand = union([
        CGRect(x: 3, y: 10, width: 14, height: 12),
        CGRect(x: 3.6, y: 2, width: 3.2, height: 11),
        CGRect(x: 7.2, y: 0, width: 3.2, height: 13),
        CGRect(x: 10.8, y: 1, width: 3.2, height: 12),
        CGRect(x: 14.4, y: 3.5, width: 3.2, height: 9.5),
        CGRect(x: 0, y: 12, width: 5, height: 4),
    ], radius: 1.6, hotSpot: CGPoint(x: 10, y: 11))

    static let closedHand = union([
        CGRect(x: 3, y: 8, width: 14, height: 12),
        CGRect(x: 3.6, y: 5, width: 3.2, height: 5),
        CGRect(x: 7.2, y: 4.5, width: 3.2, height: 5),
        CGRect(x: 10.8, y: 4.5, width: 3.2, height: 5),
        CGRect(x: 14.4, y: 5.5, width: 3.2, height: 5),
        CGRect(x: 1, y: 11, width: 5, height: 4),
    ], radius: 1.6, hotSpot: CGPoint(x: 10, y: 11))

    static func doubleArrow(angle: CGFloat) -> CGPath {
        let shaft = polygon([
            (-11, 0), (-6, -5), (-6, -1.3), (6, -1.3), (6, -5),
            (11, 0), (6, 5), (6, 1.3), (-6, 1.3), (-6, 5),
        ], hotSpot: .zero)
        var rotation = CGAffineTransform(rotationAngle: angle)
        return shaft.copy(using: &rotation) ?? shaft
    }

    static let notAllowed: CGPath = {
        let radius: CGFloat = 8, width: CGFloat = 2.4
        let ring = CGPath(ellipseIn: CGRect(x: -radius, y: -radius, width: radius * 2, height: radius * 2),
                          transform: nil)
            .copy(strokingWithWidth: width, lineCap: .butt, lineJoin: .miter, miterLimit: 4)
        var rotation = CGAffineTransform(rotationAngle: .pi / 4)
        let bar = CGPath(rect: CGRect(x: -radius, y: -width / 2, width: radius * 2, height: width),
                         transform: &rotation)
        return ring.union(bar)
    }()

    static let hourglass = polygon([
        (0, 0), (12, 0), (12, 2), (7.2, 9), (12, 16),
        (12, 18), (0, 18), (0, 16), (4.8, 9), (0, 2),
    ], hotSpot: CGPoint(x: 6, y: 9))

    private static func polygon(_ points: [(CGFloat, CGFloat)], hotSpot: CGPoint) -> CGPath {
        let path = CGMutablePath()
        path.addLines(between: points.map { CGPoint(x: $0.0 - hotSpot.x, y: $0.1 - hotSpot.y) })
        path.closeSubpath()
        return path
    }

    private static func union(_ rects: [CGRect], radius: CGFloat, hotSpot: CGPoint) -> CGPath {
        let shifted = rects.map { $0.offsetBy(dx: -hotSpot.x, dy: -hotSpot.y) }
        return shifted.dropFirst().reduce(rounded(shifted[0], radius)) { $0.union(rounded($1, radius)) }
    }

    private static func rounded(_ rect: CGRect, _ radius: CGFloat) -> CGPath {
        let r = min(radius, rect.width / 2, rect.height / 2)
        return CGPath(roundedRect: rect, cornerWidth: r, cornerHeight: r, transform: nil)
    }
}
