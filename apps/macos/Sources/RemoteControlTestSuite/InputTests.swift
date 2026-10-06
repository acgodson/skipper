import Foundation
import CoreGraphics
import AppKit
import RCTestKit
import RemoteControlCore

private func envelope<T: Encodable>(_ type: String, _ payload: T) throws -> Envelope {
    try Envelope.decode(Envelope.encode(type: type, payload: payload))
}

private let unitTarget = InputDisplayTarget(bounds: CGRect(x: 0, y: 0, width: 1000, height: 1000))

private func mouseEvent(_ event: InjectedEvent?) throws -> InjectedEvent.MouseEvent {
    guard case .mouse(let mouse)? = event else {
        throw fail("expected a mouse event, got \(String(describing: event))")
    }
    return mouse
}

// MARK: - Keycodes and modifiers

public let keyMappingSuite = TestSuite("input/keys", [

    TestCase("each modifier bit maps to its exact CGEventFlags constant") {
        try expectEqual(KeyModifiers.shift.cgFlags, CGEventFlags.maskShift)
        try expectEqual(KeyModifiers.control.cgFlags, CGEventFlags.maskControl)
        try expectEqual(KeyModifiers.option.cgFlags, CGEventFlags.maskAlternate)
        try expectEqual(KeyModifiers.command.cgFlags, CGEventFlags.maskCommand)
        try expectEqual(KeyModifiers.capsLock.cgFlags, CGEventFlags.maskAlphaShift)
        try expectEqual(KeyModifiers.function.cgFlags, CGEventFlags.maskSecondaryFn)
    },

    TestCase("the protocol's bit values are exactly 1,2,4,8,16,32") {
        try expectEqual(KeyModifiers.shift.rawValue, 1)
        try expectEqual(KeyModifiers.control.rawValue, 2)
        try expectEqual(KeyModifiers.option.rawValue, 4)
        try expectEqual(KeyModifiers.command.rawValue, 8)
        try expectEqual(KeyModifiers.capsLock.rawValue, 16)
        try expectEqual(KeyModifiers.function.rawValue, 32)
    },

    TestCase("EVERY combination of the six modifiers round-trips through CGEventFlags") {
        for raw in 0...63 {
            let modifiers = KeyModifiers(rawValue: raw)
            let flags = modifiers.cgFlags
            try expectEqual(KeyModifiers(cgFlags: flags), modifiers,
                            "combination \(raw) did not survive the round trip")
            var expected: CGEventFlags = []
            for bit in [KeyModifiers.shift, .control, .option, .command, .capsLock, .function]
            where modifiers.contains(bit) {
                expected.insert(bit.cgFlags)
            }
            try expectEqual(flags.rawValue, expected.rawValue, "combination \(raw)")
        }
    },

    TestCase("bits outside the protocol are discarded, never handed to CGEvent") {
        let modifiers = KeyModifiers(wire: 0xFFFF)
        try expectEqual(modifiers, KeyModifiers.all)
        try expectEqual(KeyModifiers(wire: 64), KeyModifiers([]), "bit 6 is not defined by §5")
    },

    TestCase("modifier keycodes are recognised on both sides") {
        try expect(VirtualKey.isModifier(55), "left Command")
        try expect(VirtualKey.isModifier(54), "right Command")
        try expect(VirtualKey.isModifier(63), "fn")
        try expectFalse(VirtualKey.isModifier(VirtualKey.space))
        try expectEqual(VirtualKey.modifier(for: 55), .command)
        try expectEqual(VirtualKey.modifier(for: 60), .shift, "right Shift is still Shift")
        try expectEqual(VirtualKey.modifier(for: VirtualKey.q), [])
    },

    TestCase("a key_down for a modifier becomes flagsChanged, not a key event") {
        let injector = InputInjector(target: unitTarget)
        let events = injector.keyDown(KeyPayload(keycode: Int(VirtualKey.command), mods: [.command]))
        guard case .flagsChanged(let keycode, let flags)? = events.first else {
            throw fail("expected flagsChanged, got \(events)")
        }
        try expectEqual(keycode, VirtualKey.command)
        try expectEqual(flags, KeyModifiers.command)
        try expectEqual(events.count, 1)
    },

    TestCase("Cmd+C carries the Command flag on the letter itself") {
        let injector = InputInjector(target: unitTarget)
        _ = injector.keyDown(KeyPayload(keycode: Int(VirtualKey.command), mods: [.command]))
        let events = injector.keyDown(KeyPayload(keycode: 8, mods: [.command]))
        guard case .key(let keycode, let down, let flags)? = events.first else {
            throw fail("expected a key event, got \(events)")
        }
        try expectEqual(keycode, 8)
        try expect(down)
        try expectEqual(flags, KeyModifiers.command)
        try expectEqual(flags.cgFlags.rawValue, CGEventFlags.maskCommand.rawValue)
    },

    TestCase("releasing a modifier clears its flag even if the peer still reports it") {
        let injector = InputInjector(target: unitTarget)
        _ = injector.keyDown(KeyPayload(keycode: Int(VirtualKey.command), mods: [.command]))
        let events = injector.keyUp(KeyPayload(keycode: Int(VirtualKey.command), mods: [.command]))
        guard case .flagsChanged(_, let flags)? = events.first else {
            throw fail("expected flagsChanged, got \(events)")
        }
        try expectEqual(flags, KeyModifiers([]), "Command must not survive its own key-up")
        try expect(injector.isIdle)
    },

    TestCase("an out-of-range keycode produces nothing rather than a truncated one") {
        let injector = InputInjector(target: unitTarget)
        try expectEqual(injector.keyDown(KeyPayload(keycode: -1, mods: [])).count, 0)
        try expectEqual(injector.keyDown(KeyPayload(keycode: 70000, mods: [])).count, 0)
        try expect(injector.isIdle)
    },
])

// MARK: - Pointer, drag and scroll

public let pointerInjectionSuite = TestSuite("input/pointer", [

    TestCase("normalised coordinates land on the exact display pixel, and clamp") {
        try expectClose(unitTarget.point(normalizedX: 0, y: 0), CGPoint(x: 0, y: 0))
        try expectClose(unitTarget.point(normalizedX: 1, y: 1), CGPoint(x: 1000, y: 1000))
        try expectClose(unitTarget.point(normalizedX: 0.25, y: 0.75), CGPoint(x: 250, y: 750))
        try expectClose(unitTarget.point(normalizedX: -0.5, y: 1.5), CGPoint(x: 0, y: 1000))
    },

    TestCase("a secondary display's origin offset is honoured") {
        let target = InputDisplayTarget(bounds: CGRect(x: -1728, y: 200, width: 1728, height: 1117))
        try expectClose(target.point(normalizedX: 0.5, y: 0.5), CGPoint(x: -864, y: 758.5))
    },

    TestCase("button down/up post the matching CGEventTypes") {
        let injector = InputInjector(target: unitTarget)
        try expectEqual(try mouseEvent(injector.mouseDown(MouseButtonPayload(button: .left, x: 0.5, y: 0.5)).first).cgType, .leftMouseDown)
        try expectEqual(try mouseEvent(injector.mouseUp(MouseButtonPayload(button: .left, x: 0.5, y: 0.5)).first).cgType, .leftMouseUp)
        try expectEqual(try mouseEvent(injector.mouseDown(MouseButtonPayload(button: .right, x: 0.5, y: 0.5)).first).cgType, .rightMouseDown)
        try expectEqual(try mouseEvent(injector.mouseUp(MouseButtonPayload(button: .right, x: 0.5, y: 0.5)).first).cgType, .rightMouseUp)
        try expectEqual(try mouseEvent(injector.mouseDown(MouseButtonPayload(button: .middle, x: 0.5, y: 0.5)).first).cgType, .otherMouseDown)
        try expectEqual(try mouseEvent(injector.mouseUp(MouseButtonPayload(button: .middle, x: 0.5, y: 0.5)).first).cgType, .otherMouseUp)
    },

    TestCase("PLAN.md §2.6: a drag posts DRAGGED events, never repeated moves") {
        let injector = InputInjector(target: unitTarget)
        _ = injector.mouseDown(MouseButtonPayload(button: .left, x: 0.1, y: 0.1))
        for step in 1...5 {
            let x = 0.1 + Double(step) * 0.1
            let events = injector.mouseDrag(MouseButtonPayload(button: .left, x: x, y: 0.1))
            let mouse = try mouseEvent(events.first)
            try expectEqual(mouse.cgType, .leftMouseDragged, "step \(step)")
            try expectNotEqual(mouse.cgType, .mouseMoved, "step \(step) must not be a plain move")
            try expectClose(mouse.point, CGPoint(x: x * 1000, y: 100), tolerance: 1e-6)
        }
        try expectEqual(try mouseEvent(injector.mouseUp(MouseButtonPayload(button: .left, x: 0.6, y: 0.1)).first).cgType, .leftMouseUp)
    },

    TestCase("right and middle drags use their own dragged types") {
        let injector = InputInjector(target: unitTarget)
        _ = injector.mouseDown(MouseButtonPayload(button: .right, x: 0.2, y: 0.2))
        try expectEqual(try mouseEvent(injector.mouseDrag(MouseButtonPayload(button: .right, x: 0.3, y: 0.2)).first).cgType, .rightMouseDragged)
        _ = injector.mouseUp(MouseButtonPayload(button: .right, x: 0.3, y: 0.2))
        _ = injector.mouseDown(MouseButtonPayload(button: .middle, x: 0.2, y: 0.2))
        try expectEqual(try mouseEvent(injector.mouseDrag(MouseButtonPayload(button: .middle, x: 0.3, y: 0.2)).first).cgType, .otherMouseDragged)
    },

    TestCase("a stray move on `hi` mid-drag stays a drag") {
        let injector = InputInjector(target: unitTarget)
        _ = injector.mouseDown(MouseButtonPayload(button: .left, x: 0.1, y: 0.1))
        let events = injector.mouseMove(MouseMovePayload(x: 0.4, y: 0.4, seq: 1))
        try expectEqual(try mouseEvent(events.first).cgType, .leftMouseDragged,
                        "a move while the button is held must not break the drag")
    },

    TestCase("a plain move is a move, with no click state") {
        let injector = InputInjector(target: unitTarget)
        let mouse = try mouseEvent(injector.mouseMove(MouseMovePayload(x: 0.4, y: 0.6, seq: 1)).first)
        try expectEqual(mouse.cgType, .mouseMoved)
        try expectEqual(mouse.clickCount, 0)
        try expectClose(mouse.point, CGPoint(x: 400, y: 600), tolerance: 1e-6)
    },

    TestCase("a drag with nothing held degrades to a move rather than a phantom drag") {
        let injector = InputInjector(target: unitTarget)
        try expectEqual(try mouseEvent(injector.mouseDrag(MouseButtonPayload(button: .left, x: 0.5, y: 0.5)).first).cgType, .mouseMoved)
    },

    TestCase("click count 1-3 produces increasing click state, and is clamped") {
        let injector = InputInjector(target: unitTarget)
        let double = injector.click(ClickPayload(button: .left, x: 0.5, y: 0.5, count: 2))
        try expectEqual(double.count, 4, "two down/up pairs")
        try expectEqual(try mouseEvent(double[0]).clickCount, 1)
        try expectEqual(try mouseEvent(double[1]).clickCount, 1)
        try expectEqual(try mouseEvent(double[2]).clickCount, 2)
        try expectEqual(try mouseEvent(double[3]).clickCount, 2)
        try expectEqual(injector.click(ClickPayload(button: .left, x: 0, y: 0, count: 9)).count, 6, "clamped to 3")
        try expectEqual(injector.click(ClickPayload(button: .left, x: 0, y: 0, count: 0)).count, 2, "clamped to 1")
        try expect(injector.isIdle, "a click leaves nothing held")
    },

    TestCase("modifiers held over a click ride along on the mouse event") {
        let injector = InputInjector(target: unitTarget)
        _ = injector.keyDown(KeyPayload(keycode: Int(VirtualKey.command), mods: [.command]))
        let mouse = try mouseEvent(injector.mouseDown(MouseButtonPayload(button: .left, x: 0.5, y: 0.5)).first)
        try expectEqual(mouse.flags, KeyModifiers.command, "Cmd-click must reach the host as a Cmd-click")
    },

    TestCase("scroll phases map to the exact kCGScrollPhase values") {
        let injector = InputInjector(target: unitTarget)
        func scroll(_ phase: ScrollPhase) throws -> InjectedEvent.ScrollEvent {
            guard case .scroll(let event)? = injector.scroll(ScrollPayload(dx: 3, dy: -7, phase: phase)).first else {
                throw fail("expected a scroll event")
            }
            return event
        }
        try expectEqual(try scroll(.begin).cgScrollPhase, 1)
        try expectEqual(try scroll(.changed).cgScrollPhase, 2)
        try expectEqual(try scroll(.end).cgScrollPhase, 4)
        try expectEqual(try scroll(.momentum).cgScrollPhase, 0)
        try expectEqual(try scroll(.momentum).cgMomentumPhase, 2)
        try expectEqual(try scroll(.changed).cgMomentumPhase, 0)
        try expectClose(try scroll(.changed).dx, 3)
        try expectClose(try scroll(.changed).dy, -7)
    },

    TestCase("an unknown scroll phase scrolls anyway rather than vanishing") {
        try expectEqual(ScrollPhase(wire: "wobble"), .changed)
        try expectEqual(ScrollPhase(wire: "BEGIN"), .begin)
    },

    TestCase("an unknown button number is ignored, not treated as left") {
        let injector = InputInjector(target: unitTarget)
        try expectEqual(injector.mouseDown(MouseButtonPayload(button: 7, x: 0.5, y: 0.5)).count, 0)
        try expect(injector.isIdle)
    },
])

// MARK: - The `hi` sequence gate

public let sequenceGateSuite = TestSuite("input/seq", [

    TestCase("a stale seq is dropped and a newer one is accepted") {
        var gate = MoveSequenceGate()
        try expect(gate.accept(1))
        try expect(gate.accept(2))
        try expectFalse(gate.accept(2), "a duplicate is stale")
        try expectFalse(gate.accept(1), "an out-of-order straggler is stale")
        try expect(gate.accept(3))
        try expectEqual(gate.highestAccepted, 3)
    },

    TestCase("the very first packet is accepted whatever its seq") {
        var gate = MoveSequenceGate()
        try expectNil(gate.highestAccepted)
        try expect(gate.accept(0), "seq 0 is not 'no packet yet'")
        var other = MoveSequenceGate()
        try expect(other.accept(-5))
    },

    TestCase("the injector drops stale positions and keeps the newest one") {
        let injector = InputInjector(target: unitTarget)
        try expectEqual(injector.mouseMove(MouseMovePayload(x: 0.1, y: 0.1, seq: 10)).count, 1)
        try expectEqual(injector.mouseMove(MouseMovePayload(x: 0.9, y: 0.9, seq: 4)).count, 0,
                        "a stale position must not drag the cursor backwards")
        try expectClose(injector.lastPoint, CGPoint(x: 100, y: 100), tolerance: 1e-6)
        try expectEqual(injector.mouseMove(MouseMovePayload(x: 0.2, y: 0.2, seq: 11)).count, 1)
        try expectClose(injector.lastPoint, CGPoint(x: 200, y: 200), tolerance: 1e-6)
    },

    TestCase("input_reset reopens the gate, so a resumed peer is not frozen") {
        let injector = InputInjector(target: unitTarget)
        _ = injector.mouseMove(MouseMovePayload(x: 0.5, y: 0.5, seq: 900))
        _ = injector.reset()
        try expectEqual(injector.mouseMove(MouseMovePayload(x: 0.3, y: 0.3, seq: 1)).count, 1,
                        "the post-resume sequence must be accepted")
    },
])

// MARK: - input_reset

public let inputResetSuite = TestSuite("input/reset", [

    TestCase("reset releases every held button, key and modifier") {
        let injector = InputInjector(target: unitTarget)
        _ = injector.mouseDown(MouseButtonPayload(button: .left, x: 0.5, y: 0.25))
        _ = injector.mouseDown(MouseButtonPayload(button: .right, x: 0.5, y: 0.25))
        _ = injector.keyDown(KeyPayload(keycode: Int(VirtualKey.command), mods: [.command]))
        _ = injector.keyDown(KeyPayload(keycode: Int(VirtualKey.shift), mods: [.command, .shift]))
        _ = injector.keyDown(KeyPayload(keycode: VirtualKey.q == 12 ? 12 : 12, mods: [.command, .shift]))
        try expectEqual(injector.heldButtons.count, 2)
        try expectEqual(injector.heldKeycodes.count, 1)
        try expectEqual(injector.heldModifierKeycodes.count, 2)

        let events = injector.reset()
        try expect(injector.isIdle, "nothing may remain held after a reset")
        try expectEqual(injector.heldButtons.count, 0)
        try expectEqual(injector.heldKeycodes.count, 0)
        try expectEqual(injector.heldModifierKeycodes.count, 0)

        try expectEqual(events.count, 5)
        try expectEqual(try mouseEvent(events[0]).cgType, .leftMouseUp)
        try expectEqual(try mouseEvent(events[1]).cgType, .rightMouseUp)
        try expectClose(try mouseEvent(events[0]).point, CGPoint(x: 500, y: 250), tolerance: 1e-6)
        guard case .key(let keycode, let down, _) = events[2] else { throw fail("expected a key-up, got \(events[2])") }
        try expectEqual(keycode, 12)
        try expectFalse(down)
        guard case .flagsChanged(_, let finalFlags) = events[4] else { throw fail("expected flagsChanged last") }
        try expectEqual(finalFlags, KeyModifiers([]))
    },

    TestCase("reset is idempotent — the second call does nothing at all") {
        let injector = InputInjector(target: unitTarget)
        _ = injector.mouseDown(MouseButtonPayload(button: .left, x: 0.5, y: 0.5))
        _ = injector.keyDown(KeyPayload(keycode: Int(VirtualKey.command), mods: [.command]))
        try expectGreaterThan(injector.reset().count, 0)
        try expectEqual(injector.reset().count, 0, "PROTOCOL.md §5: input_reset must be idempotent")
        try expectEqual(injector.reset().count, 0)
        try expect(injector.isIdle)
    },

    TestCase("reset on a fresh injector is a no-op, not an error") {
        let injector = InputInjector(target: unitTarget)
        try expectEqual(injector.reset().count, 0)
    },

    TestCase("an input_reset envelope drives the same path") {
        let injector = InputInjector(target: unitTarget)
        _ = injector.keyDown(KeyPayload(keycode: Int(VirtualKey.command), mods: [.command]))
        let events = try expectNotNil(injector.handle(ctrl: try envelope(CtrlType.inputReset, EmptyPayload())))
        try expectEqual(events.count, 1)
        try expect(injector.isIdle)
    },

    TestCase("a drag interrupted by a reset does not leave the button down") {
        let injector = InputInjector(target: unitTarget)
        _ = injector.mouseDown(MouseButtonPayload(button: .left, x: 0.2, y: 0.2))
        _ = injector.mouseDrag(MouseButtonPayload(button: .left, x: 0.4, y: 0.2))
        let events = injector.reset()
        try expectEqual(try mouseEvent(events.first).cgType, .leftMouseUp)
        try expectClose(try mouseEvent(events.first).point, CGPoint(x: 400, y: 200), tolerance: 1e-6)
    },
])

// MARK: - Envelope dispatch

public let inputDispatchSuite = TestSuite("input/dispatch", [

    TestCase("every input type routes, and nothing else is claimed") {
        let injector = InputInjector(target: unitTarget)
        let mine = [
            CtrlType.mouseDown, CtrlType.mouseUp, CtrlType.mouseDrag, CtrlType.click,
            CtrlType.keyDown, CtrlType.keyUp, CtrlType.scroll, CtrlType.gesture, CtrlType.inputReset,
        ]
        for type in mine {
            let envelope = try Envelope.decode(Envelope.encode(type: type, payload: EmptyPayload()))
            try expectNotNil(injector.handle(ctrl: envelope), "\(type) must be claimed by the injector")
        }
        for type in [CtrlType.ping, CtrlType.pong, CtrlType.quality, CtrlType.displayInfo,
                     CtrlType.clipboardText, CtrlType.sessionClose, "some_future_type"] {
            let envelope = try Envelope.decode(Envelope.encode(type: type, payload: EmptyPayload()))
            try expectNil(injector.handle(ctrl: envelope), "\(type) is not the injector's business")
        }
    },

    TestCase("a real mouse_down envelope injects at the right pixel") {
        let injector = InputInjector(target: unitTarget)
        let payload = MouseButtonPayload(button: .left, x: 0.75, y: 0.25)
        let events = try expectNotNil(injector.handle(ctrl: try envelope(CtrlType.mouseDown, payload)))
        let mouse = try mouseEvent(events.first)
        try expectEqual(mouse.cgType, .leftMouseDown)
        try expectClose(mouse.point, CGPoint(x: 750, y: 250), tolerance: 1e-6)
    },

    TestCase("a malformed payload produces no events instead of a wrong one") {
        let injector = InputInjector(target: unitTarget)
        let events = try expectNotNil(injector.handle(ctrl: try envelope(CtrlType.mouseDown, EmptyPayload())))
        try expectEqual(events.count, 0)
        try expect(injector.isIdle)
    },
])

// MARK: - Gestures

public let gestureSuite = TestSuite("input/gestures", [

    TestCase("the gesture name -> action mapping is TOTAL: every case does something") {
        for gesture in GestureName.allCases {
            let events = GestureCatalog.events(for: gesture)
            try expectGreaterThan(events.count, 0, "\(gesture.rawValue) maps to nothing — a palette button that silently no-ops")
        }
        try expectEqual(GestureName.allCases.count, 9, "PROTOCOL.md §5 lists nine gestures")
    },

    TestCase("every gesture the protocol names is decodable, and nothing else is") {
        let wireNames = ["mission_control", "app_expose", "show_desktop", "launchpad", "spotlight",
                         "app_switcher", "screenshot_region", "force_quit", "lock_screen"]
        for name in wireNames {
            try expectNotNil(GestureName(wire: name), "\(name) is in §5 and must decode")
        }
        try expectEqual(Set(GestureName.allCases.map(\.rawValue)), Set(wireNames))
        try expectNil(GestureName(wire: "rm_rf"))
        try expectNil(GestureName(wire: "MISSION_CONTROL"), "the wire form is exact")
    },

    TestCase("no two gestures do the same thing") {
        var seen: [[InjectedEvent]] = []
        for gesture in GestureName.allCases {
            let events = GestureCatalog.events(for: gesture)
            try expectFalse(seen.contains(events), "\(gesture.rawValue) duplicates another gesture's action")
            seen.append(events)
        }
    },

    TestCase("each gesture is the documented public shortcut") {
        try expectEqual(GestureCatalog.action(for: .missionControl), .combo(KeyCombo(VirtualKey.upArrow, [.control, .function])))
        try expectEqual(GestureCatalog.action(for: .appExpose), .combo(KeyCombo(VirtualKey.downArrow, [.control, .function])))
        try expectEqual(GestureCatalog.action(for: .showDesktop), .combo(KeyCombo(VirtualKey.f11, [.function])))
        try expectEqual(GestureCatalog.action(for: .spotlight), .combo(KeyCombo(VirtualKey.space, [.command])))
        try expectEqual(GestureCatalog.action(for: .appSwitcher), .combo(KeyCombo(VirtualKey.tab, [.command])))
        try expectEqual(GestureCatalog.action(for: .screenshotRegion), .combo(KeyCombo(VirtualKey.four, [.command, .shift])))
        try expectEqual(GestureCatalog.action(for: .forceQuit), .combo(KeyCombo(VirtualKey.escape, [.command, .option], tap: .annotatedSession)))
        try expectEqual(GestureCatalog.action(for: .lockScreen), .combo(KeyCombo(VirtualKey.q, [.control, .command], tap: .annotatedSession)))
        try expectEqual(GestureCatalog.action(for: .launchpad), .launchApplication(path: GestureCatalog.launchpadPath))
    },

    TestCase("a gesture never leaves a modifier held") {
        for gesture in GestureName.allCases {
            var held: KeyModifiers = []
            var sawKey = false
            for event in GestureCatalog.events(for: gesture) {
                switch event {
                case .flagsChanged(_, let flags): held = flags
                case .key(_, _, let flags):
                    sawKey = true
                    try expectEqual(flags, held, "\(gesture.rawValue): the key must carry exactly the modifiers pressed for it")
                default: break
                }
            }
            try expectEqual(held, KeyModifiers([]), "\(gesture.rawValue) left modifiers held")
            if case .combo = GestureCatalog.action(for: gesture) {
                try expect(sawKey, "\(gesture.rawValue) is a combo but posts no key")
            }
        }
    },

    TestCase("Cmd+Shift+4 presses and releases both modifiers around the 4") {
        let events = GestureCatalog.events(for: .screenshotRegion)
        try expectEqual(events.count, 6, "shift down, command down, 4 down, 4 up, command up, shift up")
        guard case .key(let keycode, true, let flags) = events[2] else { throw fail("expected the key-down third") }
        try expectEqual(keycode, VirtualKey.four)
        try expectEqual(flags, KeyModifiers([.command, .shift]))
    },

    TestCase("an unknown gesture name is ignored rather than mis-executed") {
        let injector = InputInjector(target: unitTarget)
        try expectEqual(injector.gesture(GesturePayload(name: "definitely_not_a_gesture")).count, 0)
    },

    TestCase("the injector executes a gesture envelope end to end") {
        let injector = InputInjector(target: unitTarget)
        let events = try expectNotNil(injector.handle(ctrl: try envelope(CtrlType.gesture, GesturePayload(.spotlight))))
        try expectEqual(events, GestureCatalog.events(for: .spotlight))
        try expect(injector.isIdle, "a gesture leaves nothing held")
    },

    TestCase("only the loginwindow-owned gestures ask for a posting tap") {
        var asking: Set<String> = []
        for gesture in GestureName.allCases {
            let taps = GestureCatalog.events(for: gesture).compactMap { event -> PostingTap? in
                guard case .postingTap(let tap) = event else { return nil }
                return tap
            }
            try expectLessThan(taps.count, 2, "\(gesture.rawValue) names its posting tap more than once")
            if let tap = taps.first {
                try expectEqual(tap, .annotatedSession)
                asking.insert(gesture.rawValue)
            }
        }
        try expectEqual(asking, ["force_quit", "lock_screen"],
                        "Force Quit and Lock Screen are the loginwindow shortcuts; nothing else may pick a tap")
    },

    TestCase("a gesture names its tap before any event it applies to") {
        guard case .postingTap = GestureCatalog.events(for: .forceQuit).first else {
            throw fail("the posting tap must come first, or the key is posted on the wrong tap")
        }
    },

    TestCase("ordinary mouse and keyboard input never picks a posting tap") {
        let injector = InputInjector(target: unitTarget)
        var events: [InjectedEvent] = []
        events += injector.mouseMove(MouseMovePayload(x: 0.4, y: 0.4, seq: 1))
        events += injector.mouseDown(MouseButtonPayload(button: .left, x: 0.4, y: 0.4))
        events += injector.mouseDrag(MouseButtonPayload(button: .left, x: 0.5, y: 0.5))
        events += injector.mouseUp(MouseButtonPayload(button: .left, x: 0.5, y: 0.5))
        events += injector.click(ClickPayload(button: .left, x: 0.5, y: 0.5, count: 1))
        events += injector.scroll(ScrollPayload(dx: 0, dy: -20, phase: .changed))
        events += injector.keyDown(KeyPayload(keycode: Int(VirtualKey.command), mods: [.command]))
        events += injector.keyDown(KeyPayload(keycode: 0, mods: [.command]))
        events += injector.keyUp(KeyPayload(keycode: 0, mods: [.command]))
        events += injector.keyUp(KeyPayload(keycode: Int(VirtualKey.command), mods: [.command]))
        events += injector.reset()
        try expectGreaterThan(events.count, 0)
        for event in events {
            if case .postingTap = event { throw fail("remote input must stay on the sink's own tap") }
        }
    },
])

// MARK: - Clipboard

public let clipboardSuite = TestSuite("input/clipboard", [

    TestCase("the hash is base64 SHA-256 of the UTF-8 text") {
        try expectEqual(ClipboardSyncEngine.hash("abc"),
                        "ungWv48Bz+pBQUDeXa4iI7ADYaOWF3qctBD/YfIAFa0=")
        try expectNotEqual(ClipboardSyncEngine.hash("abc"), ClipboardSyncEngine.hash("abd"))
    },

    TestCase("the echo guard drops the reflected message but accepts a new one") {
        let a = ClipboardSyncEngine(originId: "111111111")
        let b = ClipboardSyncEngine(originId: "222222222")

        let outgoing = try expectNotNil(a.localChange(text: "hello"), "a genuine copy must be sent")
        try expectEqual(outgoing.originId, "111111111")
        try expectEqual(outgoing.hash, ClipboardSyncEngine.hash("hello"))

        try expectEqual(b.receive(outgoing), "hello", "the peer must accept it")
        try expectNil(b.localChange(text: "hello"), "the reflected copy must be dropped")
        try expectGreaterThanOrEqual(b.droppedEchoes, 1)
        try expectNil(b.receive(outgoing), "a duplicate delivery must be dropped")

        let second = try expectNotNil(b.localChange(text: "goodbye"))
        try expectEqual(a.receive(second), "goodbye", "a real, different copy must still get through")
        try expectNil(a.localChange(text: "goodbye"), "and must not bounce straight back")
    },

    TestCase("copying the same text twice is not sent twice") {
        let engine = ClipboardSyncEngine(originId: "111111111")
        try expectNotNil(engine.localChange(text: "x"))
        try expectNil(engine.localChange(text: "x"))
        try expectNotNil(engine.localChange(text: "y"))
        try expectNotNil(engine.localChange(text: "x"))
    },

    TestCase("a message from our own deviceId is dropped") {
        let engine = ClipboardSyncEngine(originId: "111111111")
        let mine = ClipboardTextPayload(text: "loop", originId: "111111111",
                                        hash: ClipboardSyncEngine.hash("loop"))
        try expectNil(engine.receive(mine))
    },

    TestCase("a hash that does not describe its text is refused") {
        let engine = ClipboardSyncEngine(originId: "111111111")
        let bad = ClipboardTextPayload(text: "real", originId: "222222222",
                                       hash: ClipboardSyncEngine.hash("different"))
        try expectNil(engine.receive(bad))
    },

    TestCase("oversize text is dropped in both directions, and empty text is never sent") {
        let engine = ClipboardSyncEngine(originId: "111111111")
        let big = String(repeating: "A", count: ClipboardSyncEngine.maxTextBytes + 1)
        try expectNil(engine.localChange(text: big))
        try expectEqual(engine.droppedOversize, 1)
        try expectNil(engine.receive(ClipboardTextPayload(text: big, originId: "222222222",
                                                          hash: ClipboardSyncEngine.hash(big))))
        try expectNil(engine.localChange(text: ""))
        let atLimit = String(repeating: "A", count: ClipboardSyncEngine.maxTextBytes)
        try expectNotNil(engine.localChange(text: atLimit))
    },

    TestCase("the limit is measured in UTF-8 bytes, not characters") {
        let engine = ClipboardSyncEngine(originId: "111111111")
        let emoji = String(repeating: "\u{1F600}", count: ClipboardSyncEngine.maxTextBytes / 4 + 1)
        try expectGreaterThan(emoji.utf8.count, ClipboardSyncEngine.maxTextBytes)
        try expectLessThan(emoji.count, ClipboardSyncEngine.maxTextBytes)
        try expectNil(engine.localChange(text: emoji))
    },

    TestCase("the payload's description never contains the text") {
        let payload = ClipboardTextPayload(text: "sup3r-s3cret-passphrase", originId: "111111111",
                                           hash: ClipboardSyncEngine.hash("sup3r-s3cret-passphrase"))
        let described = "\(payload)"
        try expectFalse(described.contains("sup3r"), "clipboard contents must never reach a log")
        try expect(described.contains("redacted"))
    },

    TestCase("clipboard_text survives the wire envelope intact") {
        let payload = ClipboardTextPayload(text: "line one\nline two \u{1F600}", originId: "482719351",
                                           hash: ClipboardSyncEngine.hash("line one\nline two \u{1F600}"))
        let decoded = try envelope(CtrlType.clipboardText, payload).decodePayload(ClipboardTextPayload.self)
        try expectEqual(decoded, payload)
    },
])

// MARK: - Controller side

public let controllerInputSuite = TestSuite("input/controller", [

    TestCase("moves go on `hi` and everything else on `ctrl`") {
        try expectEqual(OutboundInput.move(x: 0, y: 0).channel, "hi")
        try expectEqual(OutboundInput.drag(MouseButtonPayload(button: .left, x: 0, y: 0)).channel, "ctrl",
                        "PROTOCOL.md §6: a drag must never travel on the unreliable channel")
        try expectEqual(OutboundInput.down(MouseButtonPayload(button: .left, x: 0, y: 0)).channel, "ctrl")
        try expectEqual(OutboundInput.up(MouseButtonPayload(button: .left, x: 0, y: 0)).channel, "ctrl")
        try expectEqual(OutboundInput.scroll(ScrollPayload(dx: 0, dy: 0, phase: .begin)).channel, "ctrl")
        try expectEqual(OutboundInput.key(down: true, KeyPayload(keycode: 0, mods: [])).channel, "ctrl")
        try expectEqual(OutboundInput.gesture(GesturePayload(.spotlight)).channel, "ctrl")
        try expectEqual(OutboundInput.reset.channel, "ctrl")
    },

    TestCase("a move with a button held is promoted to a reliable drag") {
        let sender = RemoteInputSender()
        var sent: [OutboundInput] = []
        sender.send = { sent.append($0) }

        sender.handle(pointer(0.1, 0.1, .move))
        guard case .move = sent[0] else { throw fail("expected a move, got \(sent[0])") }

        sender.handle(pointer(0.1, 0.1, .down))
        sender.handle(pointer(0.5, 0.5, .move))
        guard case .drag(let payload) = sent[2] else { throw fail("expected a drag, got \(sent[2])") }
        try expectClose(payload.x, 0.5)
        try expectEqual(sent[2].channel, "ctrl")

        sender.handle(pointer(0.5, 0.5, .up))
        sender.handle(pointer(0.6, 0.6, .move))
        guard case .move = sent[4] else { throw fail("after the button is released it is a move again") }
    },

    TestCase("the sender tracks held buttons and reset clears them") {
        let sender = RemoteInputSender()
        var sent: [OutboundInput] = []
        sender.send = { sent.append($0) }
        sender.handle(pointer(0.1, 0.1, .down, button: .right))
        try expectEqual(sender.heldButtons, [.right])
        sender.key(down: true, keycode: VirtualKey.q, modifiers: [.command])
        try expectEqual(sender.heldKeycodes, [VirtualKey.q])
        sender.reset()
        try expectEqual(sender.heldButtons.count, 0)
        try expectEqual(sender.heldKeycodes.count, 0)
        guard case .reset = sent.last else { throw fail("reset must be sent on the wire too") }
    },

    TestCase("a disabled sender sends nothing and forgets what was held") {
        let sender = RemoteInputSender()
        var sent: [OutboundInput] = []
        sender.send = { sent.append($0) }
        sender.handle(pointer(0.1, 0.1, .down))
        sender.isEnabled = false
        sender.handle(pointer(0.2, 0.2, .move))
        sender.key(down: true, keycode: VirtualKey.q, modifiers: [])
        sender.gesture(.spotlight)
        try expectEqual(sent.count, 1, "only the pre-disable event")
        try expectEqual(sender.heldButtons.count, 0)
    },

    TestCase("a zero-delta scroll is not sent, but the end of a gesture is") {
        let sender = RemoteInputSender()
        var sent: [OutboundInput] = []
        sender.send = { sent.append($0) }
        sender.handle(pointer(0.5, 0.5, .scroll, scrollDelta: .zero, phase: .changed))
        try expectEqual(sent.count, 0, "an empty scroll is noise")
        sender.handle(pointer(0.5, 0.5, .scroll, scrollDelta: .zero, phase: .end))
        try expectEqual(sent.count, 1, "the end phase must arrive so the host stops the gesture")
        sender.handle(pointer(0.5, 0.5, .scroll, scrollDelta: CGSize(width: 0, height: -12), phase: .changed))
        guard case .scroll(let payload) = sent[1] else { throw fail("expected a scroll") }
        try expectClose(payload.dy, -12)
    },

    TestCase("the keyboard tap's escape hatch is a combination nothing else uses") {
        try expectEqual(KeyboardCaptureTap.escapeHatchModifiers, KeyModifiers([.control, .option, .command]))
        try expectEqual(KeyboardCaptureTap.escapeHatchKeycode, 40)
        for gesture in GestureName.allCases {
            if case .combo(let combo) = GestureCatalog.action(for: gesture) {
                try expectFalse(combo.keycode == KeyboardCaptureTap.escapeHatchKeycode
                                && combo.modifiers == KeyboardCaptureTap.escapeHatchModifiers,
                                "\(gesture.rawValue) collides with the escape hatch")
            }
        }
    },
])

private func pointer(_ x: Double, _ y: Double, _ kind: PointerEventKind,
                     button: MouseButton = .left,
                     scrollDelta: CGSize = .zero,
                     phase: ScrollPhase = .changed) -> RemotePointerEvent {
    RemotePointerEvent(
        sample: RemotePointerSample(viewPoint: CGPoint(x: x, y: y),
                                    remotePixel: CGPoint(x: x * 1000, y: y * 1000),
                                    normalized: CGPoint(x: x, y: y),
                                    insideVideo: true),
        kind: kind, button: button, clickCount: 1,
        scrollDelta: scrollDelta, scrollPhase: phase, modifiers: [])
}

// MARK: - Real CGEvent construction

public let cgEventConstructionSuite = TestSuite("input/cgevent", [

    TestCase("a left drag really builds a kCGEventLeftMouseDragged") {
        let sink = CGEventSink()
        let event = try expectNotNil(sink.makeEvent(.mouse(.init(
            kind: .dragged, button: .left, point: CGPoint(x: 120, y: 340), clickCount: 1))))
        try expectEqual(event.type, CGEventType.leftMouseDragged)
        try expectClose(event.location, CGPoint(x: 120, y: 340), tolerance: 0.5)
    },

    TestCase("every mouse kind/button pair builds the CGEventType it claims") {
        let sink = CGEventSink()
        for kind in [InjectedEvent.MouseEvent.Kind.down, .up, .dragged] {
            for button in MouseButton.allCases {
                let descriptor = InjectedEvent.MouseEvent(kind: kind, button: button,
                                                          point: CGPoint(x: 10, y: 10))
                let event = try expectNotNil(sink.makeEvent(.mouse(descriptor)))
                try expectEqual(event.type, descriptor.cgType, "\(kind) \(button)")
            }
        }
    },

    TestCase("click state reaches CoreGraphics, which is what makes a double-click one") {
        let sink = CGEventSink()
        let event = try expectNotNil(sink.makeEvent(.mouse(.init(
            kind: .down, button: .left, point: .zero, clickCount: 2))))
        try expectEqual(event.getIntegerValueField(.mouseEventClickState), 2)
    },

    TestCase("modifier flags survive into the built event, for all 64 combinations") {
        let sink = CGEventSink()
        for raw in 0...63 {
            let modifiers = KeyModifiers(rawValue: raw)
            let event = try expectNotNil(sink.makeEvent(.key(keycode: VirtualKey.space,
                                                             down: true, flags: modifiers)))
            try expectEqual(KeyModifiers(cgFlags: event.flags), modifiers, "combination \(raw)")
        }
    },

    TestCase("a scroll is built in PIXEL units and carries its phase") {
        let sink = CGEventSink()
        let began = try expectNotNil(sink.makeEvent(.scroll(.init(dx: 0, dy: -30, phase: .begin))))
        try expectEqual(began.type, CGEventType.scrollWheel)
        try expectEqual(began.getIntegerValueField(.scrollWheelEventIsContinuous), 1,
                        "isContinuous=1 is what 'pixel units' means to CoreGraphics")
        try expectEqual(began.getIntegerValueField(.scrollWheelEventScrollPhase), 1)
        try expectEqual(began.getIntegerValueField(.scrollWheelEventPointDeltaAxis1), -30)
        try expectEqual(began.getIntegerValueField(.scrollWheelEventDeltaAxis1), -3)

        let momentum = try expectNotNil(sink.makeEvent(.scroll(.init(dx: 0, dy: -5, phase: .momentum))))
        try expectEqual(momentum.getIntegerValueField(.scrollWheelEventMomentumPhase), 2)
        try expectEqual(momentum.getIntegerValueField(.scrollWheelEventScrollPhase), 0,
                        "momentum must not also set a scroll phase")

        let horizontal = try expectNotNil(sink.makeEvent(.scroll(.init(dx: 17, dy: 0, phase: .changed))))
        try expectEqual(horizontal.getIntegerValueField(.scrollWheelEventPointDeltaAxis2), 17)
    },

    TestCase("a modifier builds a flagsChanged event carrying its keycode") {
        let sink = CGEventSink()
        let event = try expectNotNil(sink.makeEvent(.flagsChanged(keycode: VirtualKey.command,
                                                                  flags: [.command])))
        try expectEqual(event.type, CGEventType.flagsChanged)
        try expectEqual(event.getIntegerValueField(.keyboardEventKeycode), Int64(VirtualKey.command))
        try expect(event.flags.contains(.maskCommand))
    },

    TestCase("Cmd+Space builds exactly the events Spotlight responds to") {
        let sink = CGEventSink()
        let events = GestureCatalog.events(for: .spotlight)
        try expectEqual(events.count, 4)
        let built = events.compactMap { sink.makeEvent($0) }
        try expectEqual(built.count, 4)
        try expectEqual(built[0].type, CGEventType.flagsChanged)
        try expectEqual(built[1].type, CGEventType.keyDown)
        try expectEqual(built[1].getIntegerValueField(.keyboardEventKeycode), Int64(VirtualKey.space))
        try expect(built[1].flags.contains(.maskCommand), "without this it types a space")
        try expectEqual(built[2].type, CGEventType.keyUp)
        try expectEqual(built[3].type, CGEventType.flagsChanged)
        try expectFalse(built[3].flags.contains(.maskCommand), "Command must be released again")
    },

    TestCase("a launch-application gesture has no CGEvent, by design") {
        let sink = CGEventSink()
        try expectNil(sink.makeEvent(.launchApplication(path: GestureCatalog.launchpadPath)))
    },

    TestCase("posting without the Accessibility grant is refused, not silently attempted") {
        let sink = CGEventSink()
        try expectNil(sink.lastAccessibilityState, "nothing probed yet")
        var reported: Bool?
        sink.onAccessibilityChange = { reported = $0 }
        sink.post([.mouse(.init(kind: .moved, button: .left, point: .zero, clickCount: 0))])
        try expectEqual(reported, sink.hasAccessibilityPermission)
        try expectEqual(sink.lastAccessibilityState, sink.hasAccessibilityPermission)
        if sink.hasAccessibilityPermission {
            try expectEqual(sink.postedEvents, 1)
        } else {
            try expectEqual(sink.postedEvents, 0, "an ungranted host must not pretend it injected")
        }
    },

    TestCase("an empty batch does not even probe the permission") {
        let sink = CGEventSink()
        sink.post([])
        try expectNil(sink.lastAccessibilityState)
    },
])

public let appKitModifierSuite = TestSuite("input/appkit-modifiers", [
    TestCase("AppKit modifier flags map to the same bits CoreGraphics does") {
        let pairs: [(NSEvent.ModifierFlags, KeyModifiers)] = [
            (.shift, .shift), (.control, .control), (.option, .option),
            (.command, .command), (.capsLock, .capsLock), (.function, .function),
        ]
        for (appKit, expected) in pairs {
            try expectEqual(KeyModifiers(appKitFlags: appKit), expected)
        }
        try expectEqual(KeyModifiers(appKitFlags: [.command, .shift]), KeyModifiers([.command, .shift]))
        try expectEqual(KeyModifiers(appKitFlags: []), KeyModifiers([]))
        try expectEqual(KeyModifiers(appKitFlags: [.numericPad, .command]), KeyModifiers.command)
    },
])
