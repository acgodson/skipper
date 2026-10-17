import Foundation
import CoreGraphics

public enum PointerEventKind: Equatable {
    case move, down, up, drag, scroll

    public var clampsOutsideVideo: Bool {
        switch self {
        case .drag, .up, .scroll: return true
        case .move, .down: return false
        }
    }
}

public struct RemotePointerEvent: Equatable {
    public let sample: RemotePointerSample
    public let kind: PointerEventKind
    public let button: MouseButton
    public let clickCount: Int
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

public enum OutboundInput: Equatable {
    case move(x: Double, y: Double)
    case down(MouseButtonPayload)
    case up(MouseButtonPayload)
    case drag(MouseButtonPayload)
    case click(ClickPayload)
    case scroll(ScrollPayload)
    case key(down: Bool, KeyPayload)
    case gesture(GesturePayload)
    case clipboard(ClipboardTextPayload)
    case reset

    public var channel: String {
        if case .move = self { return "hi" }
        return "ctrl"
    }
}

@MainActor
public final class RemoteInputSender {

    public var send: ((OutboundInput) -> Void)?

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

    public func handle(_ event: RemotePointerEvent) {
        guard isEnabled else { return }
        let normalized = event.sample.normalized
        let x = Double(normalized.x), y = Double(normalized.y)

        switch event.kind {
        case .move:
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

    public func reset() {
        heldButtons.removeAll()
        heldKeycodes.removeAll()
        send?(.reset)
    }

    /// Lets go of whatever the remote Mac is still holding down. Called whenever the pointer
    /// stops belonging to the remote screen, so a half-finished drag cannot stick over there.
    @discardableResult
    public func releaseHeld() -> Bool {
        guard !heldButtons.isEmpty || !heldKeycodes.isEmpty else { return false }
        reset()
        return true
    }

    public func forgetHeldState() {
        heldButtons.removeAll()
        heldKeycodes.removeAll()
    }

    private func releaseEverything() { forgetHeldState() }
}
