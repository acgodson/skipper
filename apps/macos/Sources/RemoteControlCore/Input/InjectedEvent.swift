import Foundation
import CoreGraphics

// Shortcuts owned by `loginwindow` (Force Quit, Lock Screen) ignore events posted to
// the HID tap; window-server shortcuts (Mission Control, App Expose) only match there.
// A gesture therefore names the tap its combo needs; everything else uses the sink's own.
public enum PostingTap: Equatable {

    case hid
    case annotatedSession

    public var location: CGEventTapLocation {
        switch self {
        case .hid: return .cghidEventTap
        case .annotatedSession: return .cgAnnotatedSessionEventTap
        }
    }
}

public enum InjectedEvent: Equatable {

    case mouse(MouseEvent)
    case scroll(ScrollEvent)
    case key(keycode: CGKeyCode, down: Bool, flags: KeyModifiers)
    case flagsChanged(keycode: CGKeyCode, flags: KeyModifiers)
    case launchApplication(path: String)
    case postingTap(PostingTap)

    public struct MouseEvent: Equatable {
        public enum Kind: Equatable { case moved, down, up, dragged }
        public var kind: Kind
        public var button: MouseButton
        public var point: CGPoint
        public var clickCount: Int
        public var flags: KeyModifiers

        public init(kind: Kind, button: MouseButton, point: CGPoint,
                    clickCount: Int = 1, flags: KeyModifiers = []) {
            self.kind = kind; self.button = button; self.point = point
            self.clickCount = clickCount; self.flags = flags
        }

        public var cgType: CGEventType {
            switch (kind, button) {
            case (.moved, _):          return .mouseMoved
            case (.down, .left):       return .leftMouseDown
            case (.up, .left):         return .leftMouseUp
            case (.dragged, .left):    return .leftMouseDragged
            case (.down, .right):      return .rightMouseDown
            case (.up, .right):        return .rightMouseUp
            case (.dragged, .right):   return .rightMouseDragged
            case (.down, .middle):     return .otherMouseDown
            case (.up, .middle):       return .otherMouseUp
            case (.dragged, .middle):  return .otherMouseDragged
            }
        }
    }

    public struct ScrollEvent: Equatable {
        public var dx: Double
        public var dy: Double
        public var phase: ScrollPhase
        public var flags: KeyModifiers

        public init(dx: Double, dy: Double, phase: ScrollPhase, flags: KeyModifiers = []) {
            self.dx = dx; self.dy = dy; self.phase = phase; self.flags = flags
        }

        public var cgScrollPhase: Int64 {
            switch phase {
            case .begin: return 1
            case .changed: return 2
            case .end: return 4
            case .momentum: return 0
            }
        }

        public var cgMomentumPhase: Int64 { phase == .momentum ? 2 : 0 }
    }
}

public struct InputDisplayTarget: Equatable {

    public let bounds: CGRect

    public init(bounds: CGRect) { self.bounds = bounds }

    public static var mainDisplay: InputDisplayTarget {
        InputDisplayTarget(bounds: CGDisplayBounds(CGMainDisplayID()))
    }

    public var isValid: Bool { bounds.width > 0 && bounds.height > 0 }

    public func point(normalizedX x: Double, y: Double) -> CGPoint {
        let cx = min(max(x, 0), 1)
        let cy = min(max(y, 0), 1)
        return CGPoint(x: bounds.minX + cx * bounds.width,
                       y: bounds.minY + cy * bounds.height)
    }

    public func point(normalized point: CGPoint) -> CGPoint {
        self.point(normalizedX: Double(point.x), y: Double(point.y))
    }
}

public struct MoveSequenceGate: Equatable {

    private var highest: Int64 = .min

    public init() {}

    public var highestAccepted: Int64? { highest == .min ? nil : highest }

    public mutating func accept(_ seq: Int64) -> Bool {
        guard seq > highest else { return false }
        highest = seq
        return true
    }

    public mutating func reset() { highest = .min }
}
