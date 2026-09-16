#if canImport(AppKit)
import Foundation
import AppKit
import CoreGraphics
import ApplicationServices

/// "Capture keyboard" (PLAN.md §2.4, mechanism 1).
///
/// **The problem it solves.** Shortcuts typed on the controller are consumed by
/// the *controller's* macOS long before any application sees them: Cmd+Space
/// opens the LOCAL Spotlight, Cmd+Tab switches LOCAL apps. No amount of
/// `NSResponder` handling changes that — the window server has already acted.
///
/// **The mechanism.** A `CGEventTap` inserted at the head of the session tap,
/// as an active (not listen-only) tap, so its callback can return nil and the
/// event is destroyed before the system acts on it. The keystroke is forwarded
/// to the host instead. This needs the Accessibility grant, the same one the
/// host needs to inject.
///
/// **The escape hatch.** While this is on, essentially every shortcut — Cmd+Q
/// included — goes to the other Mac. `Control+Option+Command+K` is reserved: it
/// is never forwarded and always turns capture off locally, so a user cannot
/// trap themselves. It is stated in the UI, not just here.
@MainActor
public final class KeyboardCaptureTap {

    /// A key went down or up. Modifier transitions arrive here too, already
    /// resolved into a down/up by comparing the flags.
    public var onKey: ((_ down: Bool, _ keycode: CGKeyCode, _ modifiers: KeyModifiers) -> Void)?
    /// The reserved local combo was pressed: turn capture off.
    public var onEscapeHatch: (() -> Void)?
    /// The tap was disabled by the system (timeout) and has been re-enabled, or
    /// could not be created at all.
    public var onProblem: ((String) -> Void)?

    /// Set by the UI: true only while the session window is key AND the toggle
    /// is on. When false the tap stays installed but swallows nothing, so
    /// switching windows behaves completely normally.
    public var isCapturing = false

    public private(set) var isInstalled = false
    /// Counters the UI and the integration test can read. A capture toggle that
    /// silently does nothing is the failure mode here.
    public private(set) var swallowedEvents = 0
    public private(set) var forwardedEvents = 0

    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var lastFlags: CGEventFlags = []

    public static let escapeHatchKeycode: CGKeyCode = 40   // kVK_ANSI_K
    public static let escapeHatchModifiers: KeyModifiers = [.control, .option, .command]
    public static let escapeHatchDescription = "Control-Option-Command-K"

    public init() {}

    deinit {
        if let runLoopSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes) }
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
    }

    public var hasAccessibilityPermission: Bool { AXIsProcessTrusted() }

    /// Installs the tap. Returns false (and reports why) when the Accessibility
    /// grant is missing — never silently.
    @discardableResult
    public func install() -> Bool {
        guard !isInstalled else { return true }
        guard hasAccessibilityPermission else {
            onProblem?("Accessibility permission is required to capture the keyboard.")
            return false
        }
        let mask = (1 << CGEventType.keyDown.rawValue)
            | (1 << CGEventType.keyUp.rawValue)
            | (1 << CGEventType.flagsChanged.rawValue)
        let context = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap,
                                          place: .headInsertEventTap,
                                          options: .defaultTap,        // active: may swallow
                                          eventsOfInterest: CGEventMask(mask),
                                          callback: keyboardCaptureCallback,
                                          userInfo: context) else {
            onProblem?("The keyboard event tap could not be created.")
            return false
        }
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        self.tap = tap
        self.runLoopSource = source
        self.isInstalled = true
        RCLog.info("keyboard capture tap installed")
        return true
    }

    public func uninstall() {
        isCapturing = false
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
            self.runLoopSource = nil
        }
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
            self.tap = nil
        }
        isInstalled = false
    }

    fileprivate func reEnable() {
        guard let tap else { return }
        CGEvent.tapEnable(tap: tap, enable: true)
        onProblem?("The keyboard tap was disabled by the system and has been re-enabled.")
    }

    /// The decision, extracted so it can be reasoned about (and tested) apart
    /// from the C callback plumbing.
    fileprivate func handle(type: CGEventType, keycode: CGKeyCode, flags: CGEventFlags) -> TapDecision {
        guard isCapturing else { return .passThrough }
        let modifiers = KeyModifiers(cgFlags: flags)

        switch type {
        case .keyDown:
            if keycode == KeyboardCaptureTap.escapeHatchKeycode,
               modifiers.isSuperset(of: KeyboardCaptureTap.escapeHatchModifiers) {
                swallowedEvents += 1
                return .escapeHatch
            }
            forwardedEvents += 1
            swallowedEvents += 1
            return .forward(down: true, keycode: keycode, modifiers: modifiers)
        case .keyUp:
            if keycode == KeyboardCaptureTap.escapeHatchKeycode,
               modifiers.isSuperset(of: KeyboardCaptureTap.escapeHatchModifiers) {
                swallowedEvents += 1
                return .swallowOnly
            }
            forwardedEvents += 1
            swallowedEvents += 1
            return .forward(down: false, keycode: keycode, modifiers: modifiers)
        case .flagsChanged:
            // macOS does not say whether a modifier went down or up; it reports
            // the new state. The bit for THIS key being set means it went down.
            let bit = VirtualKey.modifier(for: keycode)
            let down = !bit.isEmpty && modifiers.contains(bit)
            forwardedEvents += 1
            swallowedEvents += 1
            return .forward(down: down, keycode: keycode, modifiers: modifiers)
        default:
            return .passThrough
        }
    }

    fileprivate enum TapDecision: Equatable {
        case passThrough
        case swallowOnly
        case escapeHatch
        case forward(down: Bool, keycode: CGKeyCode, modifiers: KeyModifiers)
    }
}

/// C callback: runs on the main run loop (the source is added to it), so
/// touching the main-actor object is safe. `MainActor.assumeIsolated` states
/// that rather than hopping — the decision has to be made synchronously,
/// because returning from this function is what swallows the event.
private func keyboardCaptureCallback(proxy: CGEventTapProxy,
                                     type: CGEventType,
                                     event: CGEvent,
                                     userInfo: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    guard let userInfo else { return Unmanaged.passUnretained(event) }
    let capture = Unmanaged<KeyboardCaptureTap>.fromOpaque(userInfo).takeUnretainedValue()

    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        MainActor.assumeIsolated { capture.reEnable() }
        return nil
    }

    let keycode = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))
    let flags = event.flags

    return MainActor.assumeIsolated { () -> Unmanaged<CGEvent>? in
        switch capture.handle(type: type, keycode: keycode, flags: flags) {
        case .passThrough:
            return Unmanaged.passUnretained(event)
        case .swallowOnly:
            return nil
        case .escapeHatch:
            capture.onEscapeHatch?()
            return nil
        case .forward(let down, let keycode, let modifiers):
            capture.onKey?(down, keycode, modifiers)
            return nil      // swallowed locally: it belongs to the other Mac
        }
    }
}
#endif
