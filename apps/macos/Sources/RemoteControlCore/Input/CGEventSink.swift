import Foundation
import CoreGraphics
import ApplicationServices
#if canImport(AppKit)
import AppKit
#endif

/// Where `InjectedEvent`s go.
public protocol InputEventSink: AnyObject {
    func post(_ events: [InjectedEvent])
}

public extension InputEventSink {
    func post(_ event: InjectedEvent) { post([event]) }
}

/// Records instead of posting. Used by the unit suite and by `rc-node`, so an
/// integration run can assert on the exact event stream a real session produced
/// without needing an Accessibility grant.
public final class RecordingEventSink: InputEventSink {
    public private(set) var events: [InjectedEvent] = []
    public init() {}
    public func post(_ events: [InjectedEvent]) { self.events.append(contentsOf: events) }
    public func clear() { events.removeAll() }
}

/// The real thing: OS-level `CGEvent` injection.
///
/// This is the whole product constraint in one file (AGENT.md "Browser and
/// Network Isolation"): input is posted to the window server as if it came from
/// the hardware. There is no browser automation, no injected script, no
/// accessibility-API app driving, and nothing that knows or cares what
/// application is in front.
public final class CGEventSink: InputEventSink {

    /// Fired the first time a post is attempted without the Accessibility
    /// grant, and again after it flips back. Never silent: an ungranted host
    /// looks exactly like a frozen one from the controller's side.
    public var onAccessibilityChange: ((Bool) -> Void)?

    public private(set) var postedEvents = 0
    public private(set) var lastAccessibilityState: Bool?

    /// A nil source means the combined session state, which is what makes
    /// injected modifier flags compose with any the user is physically holding
    /// on the host machine.
    private let source: CGEventSource?
    private let tap: CGEventTapLocation

    public init(source: CGEventSource? = nil, tap: CGEventTapLocation = .cghidEventTap) {
        self.source = source
        self.tap = tap
    }

    /// `AXIsProcessTrusted()` — a read-only probe that never raises a dialog.
    /// Without it `CGEvent.post` succeeds and the event is discarded, so
    /// checking is the only way to tell "nothing happened" from "not allowed".
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
        for event in events { postOne(event) }
    }

    /// Builds the `CGEvent` for one `InjectedEvent`, WITHOUT posting it.
    ///
    /// Separate from `postOne` on purpose: posting needs the Accessibility
    /// grant, but building does not, so the unit suite can assert that a drag
    /// really produces a `kCGEventLeftMouseDragged` with the right click state,
    /// and that a scroll really carries pixel units, on a machine where nothing
    /// is granted. `.launchApplication` has no CGEvent and returns nil.
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
            // Middle-click carries its button number in a field of its own; the
            // `otherMouse*` types say nothing about WHICH other button it was.
            if mouse.button == .middle {
                cgEvent.setIntegerValueField(.mouseEventButtonNumber,
                                             value: Int64(mouse.button.cgButton.rawValue))
            }
            return cgEvent

        case .scroll(let scroll):
            // PIXEL units, not lines. This is what makes remote scrolling feel
            // like a trackpad instead of a notched wheel (PLAN.md §2.6).
            guard let cgEvent = CGEvent(scrollWheelEvent2Source: source,
                                        units: .pixel,
                                        wheelCount: 2,
                                        wheel1: Int32(clamping: Int(scroll.dy.rounded())),
                                        wheel2: Int32(clamping: Int(scroll.dx.rounded())),
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
            // There is no `CGEvent(flagsChangedEventSource:)`. Build a keyboard
            // event and retype it: the window server reads the keycode field and
            // the flags, which is all a modifier transition carries.
            guard let cgEvent = CGEvent(keyboardEventSource: source,
                                        virtualKey: keycode,
                                        keyDown: true) else { return nil }
            cgEvent.type = .flagsChanged
            cgEvent.flags = flags.cgFlags
            return cgEvent

        case .launchApplication:
            return nil
        }
    }

    private func postOne(_ event: InjectedEvent) {
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
        cgEvent.post(tap: tap)
        postedEvents += 1
    }

}
