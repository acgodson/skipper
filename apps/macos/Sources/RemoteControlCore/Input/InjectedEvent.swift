import Foundation
import CoreGraphics

/// Exactly what the OS is going to be told, as a value.
///
/// The injector is a pure function from a `ctrl` message to a list of these; a
/// separate sink turns them into real `CGEvent`s. That split is the only reason
/// the headline behaviours of this phase — "a drag posts *dragged* events, not
/// moves", "input_reset releases everything and is idempotent", "Cmd+C carries
/// the Command flag" — can be asserted exactly in a unit test rather than
/// squinted at on a screen.
public enum InjectedEvent: Equatable {

    case mouse(MouseEvent)
    case scroll(ScrollEvent)
    /// A normal key. Never a modifier — see `.flagsChanged`.
    case key(keycode: CGKeyCode, down: Bool, flags: KeyModifiers)
    /// A modifier key going down or up. macOS delivers modifiers as
    /// `kCGEventFlagsChanged`, never as key-down/up, and `flags` is the FULL
    /// modifier state after the change.
    case flagsChanged(keycode: CGKeyCode, flags: KeyModifiers)
    /// Some OS actions have no key equivalent at all (Launchpad). Opening the
    /// system application is the public-API way to invoke them; PLAN.md §2.4
    /// rules out the private CoreGraphics SPI that would synthesise a real
    /// multi-touch gesture.
    case launchApplication(path: String)

    public struct MouseEvent: Equatable {
        public enum Kind: Equatable { case moved, down, up, dragged }
        public var kind: Kind
        public var button: MouseButton
        /// Global display coordinates, in points, top-left origin — the space
        /// `CGEvent` uses.
        public var point: CGPoint
        public var clickCount: Int
        public var flags: KeyModifiers

        public init(kind: Kind, button: MouseButton, point: CGPoint,
                    clickCount: Int = 1, flags: KeyModifiers = []) {
            self.kind = kind; self.button = button; self.point = point
            self.clickCount = clickCount; self.flags = flags
        }

        /// The `CGEventType` this becomes. THE assertion of PLAN.md §2.6: a
        /// `dragged` kind with the left button must be
        /// `kCGEventLeftMouseDragged`, because a window's title bar tracks
        /// dragged events and ignores plain moves — repeating `mouseMoved`
        /// while a button is held moves the cursor and leaves the window
        /// behind.
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
        /// Pixel units at the host's resolution (PROTOCOL.md §5). Pixel — not
        /// line — units are what make this feel like a trackpad instead of a
        /// notched wheel.
        public var dx: Double
        public var dy: Double
        public var phase: ScrollPhase
        public var flags: KeyModifiers

        public init(dx: Double, dy: Double, phase: ScrollPhase, flags: KeyModifiers = []) {
            self.dx = dx; self.dy = dy; self.phase = phase; self.flags = flags
        }

        /// `kCGScrollPhase*` values. `momentum` is deliberately NOT a scroll
        /// phase: macOS carries it in the separate momentum-phase field, and
        /// setting both at once makes AppKit discard the event.
        public var cgScrollPhase: Int64 {
            switch phase {
            case .begin: return 1     // kCGScrollPhaseBegan
            case .changed: return 2   // kCGScrollPhaseChanged
            case .end: return 4       // kCGScrollPhaseEnded
            case .momentum: return 0
            }
        }

        /// `kCGMomentumScrollPhaseContinue` while coasting, `None` otherwise.
        public var cgMomentumPhase: Int64 { phase == .momentum ? 2 : 0 }
    }
}

/// Where normalised `[0,1]` coordinates land on this Mac.
///
/// The host captures its main display (`ScreenCaptureSource.mainDisplay`), and
/// `CGEvent` positions are in the **global display space, in points**. Deriving
/// the target from `CGDisplayBounds` rather than from the encoded frame size is
/// deliberate: quality scaling changes the encoded resolution several times a
/// session, and the pointer must not move when it does.
public struct InputDisplayTarget: Equatable {

    public let bounds: CGRect

    public init(bounds: CGRect) { self.bounds = bounds }

    public static var mainDisplay: InputDisplayTarget {
        InputDisplayTarget(bounds: CGDisplayBounds(CGMainDisplayID()))
    }

    public var isValid: Bool { bounds.width > 0 && bounds.height > 0 }

    /// PROTOCOL.md §0: "Receivers **must** clamp." A normalised coordinate
    /// slightly outside the unit square (rounding at the very edge of the
    /// controller's window) must click the edge pixel, not fly off the display.
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

/// Drops stale packets on the unreliable `hi` channel (PROTOCOL.md §6).
///
/// Out-of-order delivery is not an error there, it is the design: a mouse
/// position that arrives after a newer one is worse than no position at all,
/// because applying it drags the cursor backwards.
public struct MoveSequenceGate: Equatable {

    private var highest: Int64 = .min

    public init() {}

    public var highestAccepted: Int64? { highest == .min ? nil : highest }

    /// True when `seq` is newer than everything seen so far.
    public mutating func accept(_ seq: Int64) -> Bool {
        guard seq > highest else { return false }
        highest = seq
        return true
    }

    /// A resumed session restarts its sequence at 1. Without this, every packet
    /// after a reconnect would look stale forever and the pointer would freeze.
    /// `input_reset` — sent after every resume, §4.4 — is what calls it.
    public mutating func reset() { highest = .min }
}
