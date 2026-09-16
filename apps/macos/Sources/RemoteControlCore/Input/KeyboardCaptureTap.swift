#if canImport(AppKit)
import Foundation
import AppKit
import CoreGraphics
import ApplicationServices

@MainActor
public final class KeyboardCaptureTap {

    public var onKey: ((_ down: Bool, _ keycode: CGKeyCode, _ modifiers: KeyModifiers) -> Void)?
    public var onEscapeHatch: (() -> Void)?
    public var onProblem: ((String) -> Void)?

    public var isCapturing = false

    public private(set) var isInstalled = false
    public private(set) var swallowedEvents = 0
    public private(set) var forwardedEvents = 0

    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var lastFlags: CGEventFlags = []

    public static let escapeHatchKeycode: CGKeyCode = 40
    public static let escapeHatchModifiers: KeyModifiers = [.control, .option, .command]
    public static let escapeHatchDescription = "Control-Option-Command-K"

    public init() {}

    deinit {
        if let runLoopSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes) }
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
    }

    public var hasAccessibilityPermission: Bool { AXIsProcessTrusted() }

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
                                          options: .defaultTap,
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
            return nil
        }
    }
}
#endif
