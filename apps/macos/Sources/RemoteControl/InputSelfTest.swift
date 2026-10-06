import AppKit
import CoreGraphics
import ApplicationServices
import RemoteControlCore

@MainActor
final class InputSelfTest {

    static var isRequested: Bool { DevelopmentHooks.isOn(.inputSelfTest) }

    private let injector = InputInjector()
    private let sink = CGEventSink()
    private var window: NSWindow?
    private var tap: CFMachPort?
    private var tapSource: CFRunLoopSource?
    private var observed: [CGEventType: Int] = [:]
    private var observedKeyFlags: [CGEventFlags] = []
    private var observedScrollContinuous: [Int64] = []
    private var passes = 0
    private var failures = 0

    private var screenFrame: CGRect { NSScreen.main?.frame ?? .zero }

    func run() {
        report("begin")
        guard AXIsProcessTrusted() else {
            let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
            _ = AXIsProcessTrustedWithOptions(options as CFDictionary)
            report("accessibility FAIL — RemoteControl.app does not have Accessibility permission (the system consent dialog has been raised)")
            finish()
            return
        }
        check(true, "accessibility", "the Accessibility grant is present")

        let restore = currentCursor()
        installObservationTap()
        makeWindow()

        Task { @MainActor in
            await settle(0.5)
            await checkCursorAccuracy()
            await checkStaleSequenceIsDropped()
            await checkWindowDragMovesTheWindow()
            await checkScrollIsPixelUnits()
            await checkModifierFlagsReachTheSession()
            await checkInputResetReleasesHeldButton()
            await checkGesturesTakeEffect()
            await checkForceQuitTakesEffect()
            moveCursor(to: restore)
            finish()
        }
    }

    // MARK: - Checks

    private func checkCursorAccuracy() async {
        injector.target = .mainDisplay
        var worst = 0.0
        var seq: Int64 = 1
        for (nx, ny) in [(0.25, 0.25), (0.75, 0.40), (0.50, 0.60)] {
            let expected = injector.target.point(normalizedX: nx, y: ny)
            sink.post(injector.mouseMove(MouseMovePayload(x: nx, y: ny, seq: seq)))
            seq += 1
            await settle(0.15)
            let actual = currentCursor()
            let delta = hypot(actual.x - expected.x, actual.y - expected.y)
            worst = max(worst, delta)
            report(String(format: "cursor target (%.2f,%.2f) expected %.0f,%.0f actual %.0f,%.0f delta %.1fpx",
                          nx, ny, expected.x, expected.y, actual.x, actual.y, delta))
        }
        check(worst <= 2.0, "cursor_accuracy",
              String(format: "the injected cursor arrived within %.1fpt of every target", worst))
    }

    private func checkStaleSequenceIsDropped() async {
        injector.target = .mainDisplay
        sink.post(injector.mouseMove(MouseMovePayload(x: 0.30, y: 0.30, seq: 5_000)))
        await settle(0.15)
        let afterFresh = currentCursor()
        sink.post(injector.mouseMove(MouseMovePayload(x: 0.80, y: 0.80, seq: 4_999)))
        await settle(0.15)
        let afterStale = currentCursor()
        let moved = hypot(afterStale.x - afterFresh.x, afterStale.y - afterFresh.y)
        check(moved <= 1.0, "stale_seq_dropped",
              String(format: "a stale packet moved the cursor %.1fpt (must be 0)", moved))
    }

    private func checkWindowDragMovesTheWindow() async {
        guard let window else { check(false, "window_drag", "no test window"); return }
        let before = window.frame
        let titleBar = CGPoint(x: before.midX, y: before.maxY - 12)
        let start = toCoreGraphics(titleBar)
        let dx = 180.0, dy = 120.0

        sink.post(injector.mouseDown(payloadAt(start)))
        await settle(0.12)
        let dragEventsBefore = observed[.leftMouseDragged] ?? 0
        let moveEventsBefore = observed[.mouseMoved] ?? 0
        for step in 1...12 {
            let fraction = Double(step) / 12.0
            let point = CGPoint(x: start.x + dx * fraction, y: start.y + dy * fraction)
            sink.post(injector.mouseDrag(payloadAt(point)))
            await settle(0.03)
        }
        sink.post(injector.mouseUp(payloadAt(CGPoint(x: start.x + dx, y: start.y + dy))))
        await settle(0.35)

        let after = window.frame
        let movedX = after.origin.x - before.origin.x
        let movedY = before.origin.y - after.origin.y
        report(String(format: "window frame %.0f,%.0f -> %.0f,%.0f (moved %.0f,%.0f; asked for %.0f,%.0f)",
                      before.origin.x, before.origin.y, after.origin.x, after.origin.y, movedX, movedY, dx, dy))

        let draggedPosted = (observed[.leftMouseDragged] ?? 0) - dragEventsBefore
        let movesPosted = (observed[.mouseMoved] ?? 0) - moveEventsBefore
        check(draggedPosted >= 10, "drag_posts_dragged_events",
              "the session saw \(draggedPosted) leftMouseDragged events (and \(movesPosted) plain moves) during the drag")
        check(abs(movedX - dx) <= 20 && abs(movedY - dy) <= 20, "window_actually_moved",
              String(format: "the window moved %.0f,%.0f — dragging by the title bar really moves it", movedX, movedY))
    }

    private func checkScrollIsPixelUnits() async {
        observedScrollContinuous.removeAll()
        let before = observed[.scrollWheel] ?? 0
        sink.post(injector.scroll(ScrollPayload(dx: 0, dy: -40, phase: .begin)))
        await settle(0.06)
        sink.post(injector.scroll(ScrollPayload(dx: 0, dy: -40, phase: .changed)))
        await settle(0.06)
        sink.post(injector.scroll(ScrollPayload(dx: 0, dy: 0, phase: .end)))
        await settle(0.15)
        let posted = (observed[.scrollWheel] ?? 0) - before
        check(posted >= 3, "scroll_events_reached_the_session", "\(posted) scroll events observed")
        check(observedScrollContinuous.allSatisfy { $0 == 1 } && !observedScrollContinuous.isEmpty,
              "scroll_is_pixel_units",
              "every scroll event carried isContinuous=1, i.e. pixel units, not notched lines")
    }

    private func checkModifierFlagsReachTheSession() async {
        observedKeyFlags.removeAll()
        let f15 = 113
        sink.post(injector.keyDown(KeyPayload(keycode: Int(VirtualKey.command), mods: [.command])))
        await settle(0.06)
        sink.post(injector.keyDown(KeyPayload(keycode: f15, mods: [.command])))
        await settle(0.06)
        sink.post(injector.keyUp(KeyPayload(keycode: f15, mods: [.command])))
        await settle(0.06)
        sink.post(injector.keyUp(KeyPayload(keycode: Int(VirtualKey.command), mods: [.command])))
        await settle(0.15)
        let sawCommand = observedKeyFlags.contains { $0.contains(.maskCommand) }
        check(sawCommand, "modifier_flags_reach_the_session",
              "a key event carrying maskCommand was observed (\(observedKeyFlags.count) key events seen)")
        check(injector.isIdle, "keys_released", "nothing is left held after the key sequence")
    }

    // A gesture that crosses the wire and is posted as the right OS events can still
    // leave the host untouched, so this check looks at what macOS did, not at what we sent.
    private func checkGesturesTakeEffect() async {
        for (gesture, name) in [(GestureName.missionControl, "mission_control_takes_effect"),
                                (GestureName.appExpose, "app_expose_takes_effect")] {
            let before = dockWindowCount()
            sink.post(GestureCatalog.events(for: gesture))
            await settle(1.5)
            let during = dockWindowCount()
            check(during > before, name,
                  "\(gesture.rawValue): the Dock's on-screen windows went \(before) -> \(during)")

            sink.post(GestureCatalog.events(for: gesture))
            await settle(1.5)
            let after = dockWindowCount()
            check(after <= before, "\(gesture.rawValue)_left_cleanly",
                  "the full-screen effect was dismissed (\(during) -> \(after))")
        }
    }

    // Force Quit is owned by `loginwindow`, which ignores HID-posted synthetic events;
    // this passes only while the catalog asks for the annotated-session tap.
    private func checkForceQuitTakesEffect() async {
        let before = onScreenWindowCount(ownedBy: "loginwindow")
        sink.post(GestureCatalog.events(for: .forceQuit))
        await settle(1.5)
        let during = onScreenWindowCount(ownedBy: "loginwindow")
        check(during > before, "force_quit_takes_effect",
              "force_quit: loginwindow's on-screen windows went \(before) -> \(during)")

        var after = during
        for tap in [PostingTap.annotatedSession, .hid] where after > before {
            sink.post(KeyCombo(VirtualKey.escape, [], tap: tap).events)
            await settle(1.0)
            after = onScreenWindowCount(ownedBy: "loginwindow")
        }
        check(after <= before, "force_quit_left_cleanly",
              "the Force Quit dialog was dismissed (\(during) -> \(after))")
    }

    private func dockWindowCount() -> Int { onScreenWindowCount(ownedBy: "Dock") }

    private func onScreenWindowCount(ownedBy owner: String) -> Int {
        let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
        return windows.filter { ($0[kCGWindowOwnerName as String] as? String) == owner }.count
    }

    private func checkInputResetReleasesHeldButton() async {
        guard let window else { check(false, "input_reset", "no test window"); return }
        let point = toCoreGraphics(CGPoint(x: window.frame.midX, y: window.frame.midY))
        let upBefore = observed[.leftMouseUp] ?? 0
        sink.post(injector.mouseDown(payloadAt(point)))
        await settle(0.12)
        check(!injector.isIdle, "reset_precondition", "the button is genuinely held before the reset")

        let events = injector.reset()
        sink.post(events)
        await settle(0.2)
        let upAfter = (observed[.leftMouseUp] ?? 0) - upBefore
        check(upAfter >= 1, "input_reset_releases_the_button",
              "the session received \(upAfter) leftMouseUp after input_reset")
        check(injector.isIdle, "input_reset_clears_state", "nothing remains held")

        let secondPass = injector.reset()
        check(secondPass.isEmpty, "input_reset_is_idempotent",
              "a second input_reset produced \(secondPass.count) events")
    }

    // MARK: - Plumbing

    private func payloadAt(_ cgPoint: CGPoint) -> MouseButtonPayload {
        let bounds = injector.target.bounds
        return MouseButtonPayload(button: .left,
                                  x: Double((cgPoint.x - bounds.minX) / bounds.width),
                                  y: Double((cgPoint.y - bounds.minY) / bounds.height))
    }

    private func toCoreGraphics(_ point: CGPoint) -> CGPoint {
        CGPoint(x: point.x, y: screenFrame.height - point.y)
    }

    private func currentCursor() -> CGPoint {
        CGEvent(source: nil)?.location ?? .zero
    }

    private func moveCursor(to point: CGPoint) {
        CGWarpMouseCursorPosition(point)
    }

    private func makeWindow() {
        let frame = NSRect(x: screenFrame.midX - 300, y: screenFrame.midY - 100, width: 420, height: 220)
        let window = NSWindow(contentRect: frame,
                              styleMask: [.titled, .closable],
                              backing: .buffered, defer: false)
        window.title = "RemoteControl input self-test"
        window.isMovableByWindowBackground = false
        window.level = .floating
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        self.window = window
    }

    private func installObservationTap() {
        let mask = (1 << CGEventType.mouseMoved.rawValue)
            | (1 << CGEventType.leftMouseDown.rawValue)
            | (1 << CGEventType.leftMouseUp.rawValue)
            | (1 << CGEventType.leftMouseDragged.rawValue)
            | (1 << CGEventType.scrollWheel.rawValue)
            | (1 << CGEventType.keyDown.rawValue)
            | (1 << CGEventType.keyUp.rawValue)
            | (1 << CGEventType.flagsChanged.rawValue)
        let context = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(tap: .cgAnnotatedSessionEventTap,
                                          place: .tailAppendEventTap,
                                          options: .listenOnly,
                                          eventsOfInterest: CGEventMask(mask),
                                          callback: { _, type, event, info in
                                              guard let info else { return Unmanaged.passUnretained(event) }
                                              let test = Unmanaged<InputSelfTest>.fromOpaque(info).takeUnretainedValue()
                                              let flags = event.flags
                                              let continuous = event.getIntegerValueField(.scrollWheelEventIsContinuous)
                                              MainActor.assumeIsolated { test.note(type, flags: flags, continuous: continuous) }
                                              return Unmanaged.passUnretained(event)
                                          },
                                          userInfo: context) else {
            report("observation tap FAILED to create")
            return
        }
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        self.tap = tap
        self.tapSource = source
    }

    fileprivate func note(_ type: CGEventType, flags: CGEventFlags, continuous: Int64) {
        observed[type, default: 0] += 1
        if type == .keyDown || type == .keyUp { observedKeyFlags.append(flags) }
        if type == .scrollWheel { observedScrollContinuous.append(continuous) }
    }

    private func settle(_ seconds: Double) async {
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }

    private func check(_ condition: Bool, _ name: String, _ detail: String) {
        if condition { passes += 1 } else { failures += 1 }
        report("\(name) \(condition ? "PASS" : "FAIL") — \(detail)")
    }

    private func report(_ line: String) { InputSelfTest.report(line) }
    private static func report(_ line: String) { RCLog.info("SELFTEST \(line)") }

    private func finish() {
        report("summary \(passes) passed, \(failures) failed")
        report("end")
        if let tapSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), tapSource, .commonModes) }
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        window?.close()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            NSApp.terminate(nil)
        }
    }
}
