import Foundation
import CoreGraphics
import ApplicationServices
#if canImport(AppKit)
import AppKit
#endif

public protocol InputEventSink: AnyObject {
    func post(_ events: [InjectedEvent])
}

public extension InputEventSink {
    func post(_ event: InjectedEvent) { post([event]) }
}

public final class RecordingEventSink: InputEventSink {
    public private(set) var events: [InjectedEvent] = []
    public init() {}
    public func post(_ events: [InjectedEvent]) { self.events.append(contentsOf: events) }
    public func clear() { events.removeAll() }
}

public final class CGEventSink: InputEventSink {

    public var onAccessibilityChange: ((Bool) -> Void)?

    public private(set) var postedEvents = 0
    public private(set) var lastAccessibilityState: Bool?

    private let source: CGEventSource?
    private let tap: CGEventTapLocation

    public init(source: CGEventSource? = nil, tap: CGEventTapLocation = .cghidEventTap) {
        self.source = source
        self.tap = tap
    }

    public var hasAccessibilityPermission: Bool { AXIsProcessTrusted() }

    public func post(_ events: [InjectedEvent]) {
        guard !events.isEmpty else { return }
        let trusted = hasAccessibilityPermission
        if trusted != lastAccessibilityState {
            lastAccessibilityState = trusted
            onAccessibilityChange?(trusted)
            if !trusted {
                RCLog.error("input: Accessibility is NOT granted — injected events will be discarded by the window server")
            }
        }
        guard trusted else { return }
        var location = tap
        for event in events {
            if case .postingTap(let requested) = event {
                location = requested.location
                continue
            }
            postOne(event, to: location)
        }
    }

    public func makeEvent(_ event: InjectedEvent) -> CGEvent? {
        switch event {
        case .mouse(let mouse):
            guard let cgEvent = CGEvent(mouseEventSource: source,
                                        mouseType: mouse.cgType,
                                        mouseCursorPosition: mouse.point,
                                        mouseButton: mouse.button.cgButton) else { return nil }
            cgEvent.flags = mouse.flags.cgFlags
            if mouse.clickCount > 0 {
                cgEvent.setIntegerValueField(.mouseEventClickState, value: Int64(mouse.clickCount))
            }
            if mouse.button == .middle {
                cgEvent.setIntegerValueField(.mouseEventButtonNumber,
                                             value: Int64(mouse.button.cgButton.rawValue))
            }
            return cgEvent

        case .scroll(let scroll):
            guard let wheel1 = WireBounds.int32(scroll.dy),
                  let wheel2 = WireBounds.int32(scroll.dx),
                  let cgEvent = CGEvent(scrollWheelEvent2Source: source,
                                        units: .pixel,
                                        wheelCount: 2,
                                        wheel1: wheel1,
                                        wheel2: wheel2,
                                        wheel3: 0) else { return nil }
            cgEvent.flags = scroll.flags.cgFlags
            cgEvent.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
            if scroll.cgScrollPhase != 0 {
                cgEvent.setIntegerValueField(.scrollWheelEventScrollPhase, value: scroll.cgScrollPhase)
            }
            if scroll.cgMomentumPhase != 0 {
                cgEvent.setIntegerValueField(.scrollWheelEventMomentumPhase, value: scroll.cgMomentumPhase)
            }
            return cgEvent

        case .key(let keycode, let down, let flags):
            guard let cgEvent = CGEvent(keyboardEventSource: source,
                                        virtualKey: keycode,
                                        keyDown: down) else { return nil }
            cgEvent.flags = flags.cgFlags
            return cgEvent

        case .flagsChanged(let keycode, let flags):
            guard let cgEvent = CGEvent(keyboardEventSource: source,
                                        virtualKey: keycode,
                                        keyDown: true) else { return nil }
            cgEvent.type = .flagsChanged
            cgEvent.flags = flags.cgFlags
            return cgEvent

        case .launchApplication, .postingTap:
            return nil
        }
    }

    private func postOne(_ event: InjectedEvent, to location: CGEventTapLocation) {
        if case .launchApplication(let path) = event {
            #if canImport(AppKit)
            let url = URL(fileURLWithPath: path)
            guard FileManager.default.fileExists(atPath: path) else {
                RCLog.error("input: \(path) is not present on this Mac; gesture ignored")
                return
            }
            NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration()) { _, error in
                if let error { RCLog.error("input: could not open \(path): \(error.localizedDescription)") }
            }
            #endif
            postedEvents += 1
            return
        }
        guard let cgEvent = makeEvent(event) else { return }
        cgEvent.post(tap: location)
        postedEvents += 1
    }

}
