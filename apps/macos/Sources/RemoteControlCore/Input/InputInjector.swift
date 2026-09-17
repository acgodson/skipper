import Foundation
import CoreGraphics

public final class InputInjector {

    public var target: InputDisplayTarget

    public private(set) var heldButtons: Set<MouseButton> = []
    public private(set) var heldKeycodes: Set<CGKeyCode> = []
    public private(set) var heldModifierKeycodes: Set<CGKeyCode> = []
    public private(set) var lastPoint: CGPoint = .zero

    private var moveGate = MoveSequenceGate()

    public init(target: InputDisplayTarget = .mainDisplay) {
        self.target = target
    }

    public var isIdle: Bool {
        heldButtons.isEmpty && heldKeycodes.isEmpty && heldModifierKeycodes.isEmpty
    }

    public var derivedModifiers: KeyModifiers {
        heldModifierKeycodes.reduce(into: KeyModifiers()) { $0.formUnion(VirtualKey.modifier(for: $1)) }
    }

    // MARK: - Pointer

    public func mouseMove(_ payload: MouseMovePayload) -> [InjectedEvent] {
        guard Self.withinBounds(payload.x, payload.y), moveGate.accept(payload.seq) else { return [] }
        let point = target.point(normalizedX: payload.x, y: payload.y)
        lastPoint = point
        if let button = heldButtons.first {
            return [.mouse(.init(kind: .dragged, button: button, point: point,
                                 clickCount: 1, flags: derivedModifiers))]
        }
        return [.mouse(.init(kind: .moved, button: .left, point: point,
                             clickCount: 0, flags: derivedModifiers))]
    }

    public func mouseDown(_ payload: MouseButtonPayload) -> [InjectedEvent] {
        guard let button = payload.mouseButton, Self.withinBounds(payload.x, payload.y) else { return [] }
        let point = target.point(normalized: payload.normalized)
        lastPoint = point
        heldButtons.insert(button)
        return [.mouse(.init(kind: .down, button: button, point: point,
                             clickCount: 1, flags: derivedModifiers))]
    }

    public func mouseUp(_ payload: MouseButtonPayload) -> [InjectedEvent] {
        guard let button = payload.mouseButton, Self.withinBounds(payload.x, payload.y) else { return [] }
        let point = target.point(normalized: payload.normalized)
        lastPoint = point
        heldButtons.remove(button)
        return [.mouse(.init(kind: .up, button: button, point: point,
                             clickCount: 1, flags: derivedModifiers))]
    }

    public func mouseDrag(_ payload: MouseButtonPayload) -> [InjectedEvent] {
        guard let button = payload.mouseButton, Self.withinBounds(payload.x, payload.y) else { return [] }
        let point = target.point(normalized: payload.normalized)
        lastPoint = point
        guard heldButtons.contains(button) else {
            return [.mouse(.init(kind: .moved, button: button, point: point,
                                 clickCount: 0, flags: derivedModifiers))]
        }
        return [.mouse(.init(kind: .dragged, button: button, point: point,
                             clickCount: 1, flags: derivedModifiers))]
    }

    public func click(_ payload: ClickPayload) -> [InjectedEvent] {
        guard let button = payload.mouseButton, Self.withinBounds(payload.x, payload.y) else { return [] }
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
        guard WireBounds.accepts(payload.dx, payload.dy, in: WireBounds.scrollDelta) else { return [] }
        return [.scroll(.init(dx: payload.dx, dy: payload.dy,
                       phase: payload.scrollPhase, flags: derivedModifiers))]
    }

    private static func withinBounds(_ x: Double, _ y: Double) -> Bool {
        WireBounds.accepts(x, y, in: WireBounds.normalizedCoordinate)
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

    @discardableResult
    public func reset() -> [InjectedEvent] {
        var events: [InjectedEvent] = []

        for button in heldButtons.sorted(by: { $0.rawValue < $1.rawValue }) {
            events.append(.mouse(.init(kind: .up, button: button, point: lastPoint,
                                       clickCount: 1, flags: derivedModifiers)))
        }
        heldButtons.removeAll()

        for keycode in heldKeycodes.sorted() {
            events.append(.key(keycode: keycode, down: false, flags: derivedModifiers))
        }
        heldKeycodes.removeAll()

        for keycode in heldModifierKeycodes.sorted() {
            heldModifierKeycodes.remove(keycode)
            events.append(.flagsChanged(keycode: keycode, flags: derivedModifiers))
        }

        moveGate.reset()
        return events
    }

    // MARK: - Dispatch

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
