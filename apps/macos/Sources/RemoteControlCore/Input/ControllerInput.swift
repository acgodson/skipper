import Foundation
import CoreGraphics

/// What kind of pointer activity a sample describes. Lives here rather than in
/// the AppKit view so the sender and its tests need no window.
public enum PointerEventKind: Equatable {
    case move, down, up, drag, scroll

    /// Only a gesture already in progress may be clamped; a fresh click outside
    /// the video is not a click on the remote screen at all.
    public var clampsOutsideVideo: Bool {
        switch self {
        case .drag, .up, .scroll: return true
        case .move, .down: return false
        }
    }
}

/// One pointer event from the controller's remote-screen view, with everything
/// the wire needs.
///
/// `sample` is produced by `RemoteDisplayGeometry` (Phase 4) and is the ONLY
/// source of coordinates — this phase adds no second conversion. The rest is
/// what a `RemotePointerSample` alone cannot carry: which button, how many
/// clicks, the scroll delta (already in remote pixels, via the same geometry)
/// and its phase.
public struct RemotePointerEvent: Equatable {
    public let sample: RemotePointerSample
    public let kind: PointerEventKind
    public let button: MouseButton
    public let clickCount: Int
    /// Remote pixels, from `RemoteDisplayGeometry.remoteDelta(fromViewDelta:)`.
    public let scrollDelta: CGSize
    public let scrollPhase: ScrollPhase
    public let modifiers: KeyModifiers

    public init(sample: RemotePointerSample,
                kind: PointerEventKind,
                button: MouseButton = .left,
                clickCount: Int = 1,
                scrollDelta: CGSize = .zero,
                scrollPhase: ScrollPhase = .changed,
                modifiers: KeyModifiers = []) {
        self.sample = sample
        self.kind = kind
        self.button = button
        self.clickCount = clickCount
        self.scrollDelta = scrollDelta
        self.scrollPhase = scrollPhase
        self.modifiers = modifiers
    }
}

/// One message the controller wants to put on the wire.
///
/// The controller side is split the same way the host side is: `RemoteInputSender`
/// turns UI events into these values, and the transport encodes them. So "a
/// move while a button is held goes out as `mouse_drag` on the RELIABLE channel,
/// not as `mouse_move` on the unreliable one" is a unit-testable claim rather
/// than something you find out by dragging a window and watching it not move.
public enum OutboundInput: Equatable {
    /// The ONLY thing allowed on `hi` (PROTOCOL.md §6).
    case move(x: Double, y: Double)
    case down(MouseButtonPayload)
    case up(MouseButtonPayload)
    /// Reliable on purpose: a dropped drag point visibly breaks window dragging.
    case drag(MouseButtonPayload)
    case click(ClickPayload)
    case scroll(ScrollPayload)
    case key(down: Bool, KeyPayload)
    case gesture(GesturePayload)
    case clipboard(ClipboardTextPayload)
    case reset

    /// `hi` for moves, `ctrl` for everything else. Stated once, here, so no
    /// caller can put a drag on the unreliable channel by accident.
    public var channel: String {
        // The literals, not `PeerSession.hiLabel`: those are main-actor
        // isolated and this decision must be available from anywhere.
        if case .move = self { return "hi" }
        return "ctrl"
    }
}

/// Controller side. Converts pointer, keyboard and palette activity into
/// `OutboundInput`, and tracks which buttons are down locally so a move can be
/// promoted to a drag.
@MainActor
public final class RemoteInputSender {

    /// Where messages go. Set by whoever owns the session.
    public var send: ((OutboundInput) -> Void)?

    /// Off while the session is not live; nothing is sent and no state is kept.
    public var isEnabled = true {
        didSet {
            guard isEnabled != oldValue, !isEnabled else { return }
            releaseEverything()
        }
    }

    public private(set) var heldButtons: Set<MouseButton> = []
    public private(set) var heldKeycodes: Set<CGKeyCode> = []

    public init() {}

    // MARK: Pointer

    /// The single entry point for everything the remote screen view reports.
    /// The coordinates in `event.sample` were produced by
    /// `RemoteDisplayGeometry` — there is no second conversion anywhere in this
    /// file, deliberately.
    public func handle(_ event: RemotePointerEvent) {
        guard isEnabled else { return }
        let normalized = event.sample.normalized
        let x = Double(normalized.x), y = Double(normalized.y)

        switch event.kind {
        case .move:
            // A move with a button held is a drag even if AppKit did not label
            // it one (it happens across a window boundary).
            if let button = heldButtons.first {
                send?(.drag(MouseButtonPayload(button: button, x: x, y: y)))
            } else {
                send?(.move(x: x, y: y))
            }
        case .down:
            heldButtons.insert(event.button)
            send?(.down(MouseButtonPayload(button: event.button, x: x, y: y)))
        case .up:
            heldButtons.remove(event.button)
            send?(.up(MouseButtonPayload(button: event.button, x: x, y: y)))
        case .drag:
            let button = heldButtons.contains(event.button) ? event.button : (heldButtons.first ?? event.button)
            send?(.drag(MouseButtonPayload(button: button, x: x, y: y)))
        case .scroll:
            guard event.scrollDelta != .zero || event.scrollPhase == .end else { return }
            send?(.scroll(ScrollPayload(dx: Double(event.scrollDelta.width),
                                        dy: Double(event.scrollDelta.height),
                                        phase: event.scrollPhase)))
        }
    }

    // MARK: Keyboard

    public func key(down: Bool, keycode: CGKeyCode, modifiers: KeyModifiers, chars: String? = nil) {
        guard isEnabled else { return }
        if down { heldKeycodes.insert(keycode) } else { heldKeycodes.remove(keycode) }
        send?(.key(down: down, KeyPayload(keycode: Int(keycode), mods: modifiers, chars: chars)))
    }

    public func gesture(_ name: GestureName) {
        guard isEnabled else { return }
        send?(.gesture(GesturePayload(name)))
    }

    public func clipboard(_ payload: ClipboardTextPayload) {
        guard isEnabled else { return }
        send?(.clipboard(payload))
    }

    /// PROTOCOL.md §4.4: on every resume and every disconnect. Also clears the
    /// sender's own idea of what is held, so the controller cannot keep
    /// promoting moves to drags for a button the host has already released.
    public func reset() {
        heldButtons.removeAll()
        heldKeycodes.removeAll()
        send?(.reset)
    }

    /// Forgets what this side thinks is held, WITHOUT sending anything.
    ///
    /// Used when an `input_reset` has already gone out by another route (the
    /// state machine sends one on every resume and disconnect, PROTOCOL.md
    /// §4.4). Sending a second one would be harmless — it is idempotent — but
    /// leaving the sender's own state stale would not: it would keep promoting
    /// moves to drags for a button the host has already released.
    public func forgetHeldState() {
        heldButtons.removeAll()
        heldKeycodes.removeAll()
    }

    private func releaseEverything() { forgetHeldState() }
}
