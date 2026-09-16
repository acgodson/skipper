import Foundation
import CoreGraphics

/// Translates `ctrl` / `hi` input messages into the exact OS events to post, and
/// owns the held-state bookkeeping that keeps a modifier from getting stuck.
///
/// **Why this is a pure translator.** A stuck Command key is the worst failure
/// this product can have: the remote Mac becomes unusable and nothing on screen
/// explains why. The rule that prevents it — every press is tracked, and
/// `input_reset` releases exactly what is tracked and nothing else — is only
/// trustworthy if it can be asserted directly. So this type never calls
/// CoreGraphics; it returns `[InjectedEvent]` and `CGEventSink` posts them.
public final class InputInjector {

    /// Where normalised coordinates land. Re-read on every reset and whenever
    /// the display reconfigures.
    public var target: InputDisplayTarget

    // Held state. `public private(set)` because the tests assert on it and the
    // UI can show it; nothing outside may mutate it.
    public private(set) var heldButtons: Set<MouseButton> = []
    public private(set) var heldKeycodes: Set<CGKeyCode> = []
    public private(set) var heldModifierKeycodes: Set<CGKeyCode> = []
    /// Last position anything was posted at, so a reset releases the button
    /// where the pointer actually is rather than at the origin.
    public private(set) var lastPoint: CGPoint = .zero

    private var moveGate = MoveSequenceGate()

    public init(target: InputDisplayTarget = .mainDisplay) {
        self.target = target
    }

    /// Nothing is held: the state a session must start and end in.
    public var isIdle: Bool {
        heldButtons.isEmpty && heldKeycodes.isEmpty && heldModifierKeycodes.isEmpty
    }

    /// Modifier flags implied by the modifier keys currently held down here.
    public var derivedModifiers: KeyModifiers {
        heldModifierKeycodes.reduce(into: KeyModifiers()) { $0.formUnion(VirtualKey.modifier(for: $1)) }
    }

    // MARK: - Pointer

    /// `hi` channel. Returns no events for a stale packet (PROTOCOL.md §6).
    public func mouseMove(_ payload: MouseMovePayload) -> [InjectedEvent] {
        guard moveGate.accept(payload.seq) else { return [] }
        let point = target.point(normalizedX: payload.x, y: payload.y)
        lastPoint = point
        // A move that arrives while a button is held is still a DRAG. The
        // controller sends drags on `ctrl` and never here, but a straggler on
        // `hi` mid-gesture must not break the drag by posting a plain move.
        if let button = heldButtons.first {
            return [.mouse(.init(kind: .dragged, button: button, point: point,
                                 clickCount: 1, flags: derivedModifiers))]
        }
        return [.mouse(.init(kind: .moved, button: .left, point: point,
                             clickCount: 0, flags: derivedModifiers))]
    }

    public func mouseDown(_ payload: MouseButtonPayload) -> [InjectedEvent] {
        guard let button = payload.mouseButton else { return [] }
        let point = target.point(normalized: payload.normalized)
        lastPoint = point
        heldButtons.insert(button)
        return [.mouse(.init(kind: .down, button: button, point: point,
                             clickCount: 1, flags: derivedModifiers))]
    }

    public func mouseUp(_ payload: MouseButtonPayload) -> [InjectedEvent] {
        guard let button = payload.mouseButton else { return [] }
        let point = target.point(normalized: payload.normalized)
        lastPoint = point
        heldButtons.remove(button)
        return [.mouse(.init(kind: .up, button: button, point: point,
                             clickCount: 1, flags: derivedModifiers))]
    }

    /// PLAN.md §2.6 — the headline. This must produce a *dragged* event, not a
    /// move, or dragging a window by its title bar moves the cursor and leaves
    /// the window where it was.
    public func mouseDrag(_ payload: MouseButtonPayload) -> [InjectedEvent] {
        guard let button = payload.mouseButton else { return [] }
        let point = target.point(normalized: payload.normalized)
        lastPoint = point
        guard heldButtons.contains(button) else {
            // Drag with nothing held: the down was lost or is out of order.
            // Moving is the honest fallback; a dragged event with no button
            // down is discarded by AppKit anyway.
            return [.mouse(.init(kind: .moved, button: button, point: point,
                                 clickCount: 0, flags: derivedModifiers))]
        }
        return [.mouse(.init(kind: .dragged, button: button, point: point,
                             clickCount: 1, flags: derivedModifiers))]
    }

    /// `click {count}`. Each pair carries an increasing click state, which is
    /// how macOS recognises a double- or triple-click rather than two clicks.
    public func click(_ payload: ClickPayload) -> [InjectedEvent] {
        guard let button = payload.mouseButton else { return [] }
        let point = target.point(normalized: payload.normalized)
        lastPoint = point
        let flags = derivedModifiers
        var events: [InjectedEvent] = []
        for index in 1...payload.clampedCount {
            events.append(.mouse(.init(kind: .down, button: button, point: point,
                                       clickCount: index, flags: flags)))
            events.append(.mouse(.init(kind: .up, button: button, point: point,
                                       clickCount: index, flags: flags)))
        }
        return events
    }

    public func scroll(_ payload: ScrollPayload) -> [InjectedEvent] {
        [.scroll(.init(dx: payload.dx, dy: payload.dy,
                       phase: payload.scrollPhase, flags: derivedModifiers))]
    }

    // MARK: - Keyboard

    public func keyDown(_ payload: KeyPayload) -> [InjectedEvent] {
        guard let keycode = payload.virtualKey else { return [] }
        if VirtualKey.isModifier(keycode) {
            heldModifierKeycodes.insert(keycode)
            return [.flagsChanged(keycode: keycode, flags: derivedModifiers.union(payload.modifiers))]
        }
        heldKeycodes.insert(keycode)
        return [.key(keycode: keycode, down: true,
                     flags: derivedModifiers.union(payload.modifiers))]
    }

    public func keyUp(_ payload: KeyPayload) -> [InjectedEvent] {
        guard let keycode = payload.virtualKey else { return [] }
        if VirtualKey.isModifier(keycode) {
            heldModifierKeycodes.remove(keycode)
            // The released modifier is subtracted explicitly: a peer that
            // reports the pre-change modifier state on key-up would otherwise
            // leave the flag set, which is precisely a stuck Command key.
            var flags = derivedModifiers.union(payload.modifiers)
            flags.remove(VirtualKey.modifier(for: keycode))
            return [.flagsChanged(keycode: keycode, flags: flags)]
        }
        heldKeycodes.remove(keycode)
        return [.key(keycode: keycode, down: false,
                     flags: derivedModifiers.union(payload.modifiers))]
    }

    // MARK: - Gestures

    public func gesture(_ payload: GesturePayload) -> [InjectedEvent] {
        guard let name = payload.gesture else { return [] }
        return GestureCatalog.events(for: name)
    }

    // MARK: - Reset

    /// PROTOCOL.md §5 `input_reset`: release every held key, modifier and mouse
    /// button. Sent after every resume and every disconnect (§4.4).
    ///
    /// Idempotent by construction: it releases exactly what is tracked, and
    /// what is tracked is then empty, so a second call returns no events at
    /// all. That is asserted, because "we send it twice on reconnect" is the
    /// normal case, not an edge case.
    @discardableResult
    public func reset() -> [InjectedEvent] {
        var events: [InjectedEvent] = []

        // Buttons first: a button released after its modifiers would briefly
        // look like an unmodified click to whatever is under the cursor.
        for button in heldButtons.sorted(by: { $0.rawValue < $1.rawValue }) {
            events.append(.mouse(.init(kind: .up, button: button, point: lastPoint,
                                       clickCount: 1, flags: derivedModifiers)))
        }
        heldButtons.removeAll()

        for keycode in heldKeycodes.sorted() {
            events.append(.key(keycode: keycode, down: false, flags: derivedModifiers))
        }
        heldKeycodes.removeAll()

        // Modifiers last, one at a time, each with the flags that remain after
        // it goes up — the sequence real hardware produces.
        for keycode in heldModifierKeycodes.sorted() {
            heldModifierKeycodes.remove(keycode)
            events.append(.flagsChanged(keycode: keycode, flags: derivedModifiers))
        }

        // A resumed peer restarts its `hi` sequence at 1. Without this the gate
        // would reject every packet after a reconnect and the pointer would
        // freeze with no error anywhere.
        moveGate.reset()
        return events
    }

    // MARK: - Dispatch

    /// Routes one decoded `ctrl` envelope. Returns nil for a type this injector
    /// does not own (clipboard, quality, ping…), so the caller can tell "not
    /// mine" from "mine, and it produced nothing".
    public func handle(ctrl envelope: Envelope) -> [InjectedEvent]? {
        switch envelope.type {
        case CtrlType.mouseDown:
            return decode(envelope, MouseButtonPayload.self).map(mouseDown) ?? []
        case CtrlType.mouseUp:
            return decode(envelope, MouseButtonPayload.self).map(mouseUp) ?? []
        case CtrlType.mouseDrag:
            return decode(envelope, MouseButtonPayload.self).map(mouseDrag) ?? []
        case CtrlType.click:
            return decode(envelope, ClickPayload.self).map(click) ?? []
        case CtrlType.keyDown:
            return decode(envelope, KeyPayload.self).map(keyDown) ?? []
        case CtrlType.keyUp:
            return decode(envelope, KeyPayload.self).map(keyUp) ?? []
        case CtrlType.scroll:
            return decode(envelope, ScrollPayload.self).map(scroll) ?? []
        case CtrlType.gesture:
            return decode(envelope, GesturePayload.self).map(gesture) ?? []
        case CtrlType.inputReset:
            return reset()
        default:
            return nil
        }
    }

    private func decode<T: Decodable>(_ envelope: Envelope, _ type: T.Type) -> T? {
        try? envelope.decodePayload(type)
    }
}
