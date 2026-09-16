import Foundation
import CoreGraphics
#if canImport(AppKit)
import AppKit
#endif

public enum MouseButton: Int, CaseIterable, Codable, Equatable, Hashable, Sendable {
    case left = 0
    case right = 1
    case middle = 2

    public init?(wire: Int) {
        guard let button = MouseButton(rawValue: wire) else { return nil }
        self = button
    }

    public var cgButton: CGMouseButton {
        switch self {
        case .left: return .left
        case .right: return .right
        case .middle: return .center
        }
    }
}

public struct KeyModifiers: OptionSet, Codable, Equatable, Hashable, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    public static let shift    = KeyModifiers(rawValue: 1)
    public static let control  = KeyModifiers(rawValue: 2)
    public static let option   = KeyModifiers(rawValue: 4)
    public static let command  = KeyModifiers(rawValue: 8)
    public static let capsLock = KeyModifiers(rawValue: 16)
    public static let function = KeyModifiers(rawValue: 32)

    public static let all: KeyModifiers = [.shift, .control, .option, .command, .capsLock, .function]

    public init(wire: Int) { self.init(rawValue: wire & KeyModifiers.all.rawValue) }

    public var cgFlags: CGEventFlags {
        var flags: CGEventFlags = []
        if contains(.shift)    { flags.insert(.maskShift) }
        if contains(.control)  { flags.insert(.maskControl) }
        if contains(.option)   { flags.insert(.maskAlternate) }
        if contains(.command)  { flags.insert(.maskCommand) }
        if contains(.capsLock) { flags.insert(.maskAlphaShift) }
        if contains(.function) { flags.insert(.maskSecondaryFn) }
        return flags
    }

#if canImport(AppKit)
    public init(appKitFlags: NSEvent.ModifierFlags) {
        var mods: KeyModifiers = []
        if appKitFlags.contains(.shift) { mods.insert(.shift) }
        if appKitFlags.contains(.control) { mods.insert(.control) }
        if appKitFlags.contains(.option) { mods.insert(.option) }
        if appKitFlags.contains(.command) { mods.insert(.command) }
        if appKitFlags.contains(.capsLock) { mods.insert(.capsLock) }
        if appKitFlags.contains(.function) { mods.insert(.function) }
        self = mods
    }
#endif

    public init(cgFlags: CGEventFlags) {
        var mods: KeyModifiers = []
        if cgFlags.contains(.maskShift)       { mods.insert(.shift) }
        if cgFlags.contains(.maskControl)     { mods.insert(.control) }
        if cgFlags.contains(.maskAlternate)   { mods.insert(.option) }
        if cgFlags.contains(.maskCommand)     { mods.insert(.command) }
        if cgFlags.contains(.maskAlphaShift)  { mods.insert(.capsLock) }
        if cgFlags.contains(.maskSecondaryFn) { mods.insert(.function) }
        self = mods
    }
}

public enum ScrollPhase: String, CaseIterable, Codable, Equatable, Sendable {
    case begin
    case changed
    case end
    case momentum

    public init(wire: String) { self = ScrollPhase(rawValue: wire.lowercased()) ?? .changed }
}

public enum GestureName: String, CaseIterable, Codable, Equatable, Sendable {
    case missionControl = "mission_control"
    case appExpose = "app_expose"
    case showDesktop = "show_desktop"
    case launchpad
    case spotlight
    case appSwitcher = "app_switcher"
    case screenshotRegion = "screenshot_region"
    case forceQuit = "force_quit"
    case lockScreen = "lock_screen"

    public init?(wire: String) {
        guard let name = GestureName(rawValue: wire) else { return nil }
        self = name
    }

    public var displayName: String {
        switch self {
        case .missionControl: return "Mission Control"
        case .appExpose: return "App Exposé"
        case .showDesktop: return "Show Desktop"
        case .launchpad: return "Launchpad"
        case .spotlight: return "Spotlight"
        case .appSwitcher: return "App Switcher"
        case .screenshotRegion: return "Screenshot Region"
        case .forceQuit: return "Force Quit"
        case .lockScreen: return "Lock Screen"
        }
    }

    public var symbolName: String {
        switch self {
        case .missionControl: return "square.grid.3x2"
        case .appExpose: return "rectangle.stack"
        case .showDesktop: return "menubar.dock.rectangle"
        case .launchpad: return "square.grid.3x3.fill"
        case .spotlight: return "magnifyingglass"
        case .appSwitcher: return "command"
        case .screenshotRegion: return "camera.viewfinder"
        case .forceQuit: return "xmark.octagon"
        case .lockScreen: return "lock.fill"
        }
    }
}

// MARK: - Payloads

public struct MouseButtonPayload: Codable, Equatable {
    public var button: Int
    public var x: Double
    public var y: Double
    public init(button: MouseButton, x: Double, y: Double) {
        self.button = button.rawValue; self.x = x; self.y = y
    }
    public init(button: Int, x: Double, y: Double) {
        self.button = button; self.x = x; self.y = y
    }
    public var mouseButton: MouseButton? { MouseButton(wire: button) }
    public var normalized: CGPoint { CGPoint(x: x, y: y) }
}

public struct ClickPayload: Codable, Equatable {
    public var button: Int
    public var x: Double
    public var y: Double
    public var count: Int
    public init(button: MouseButton, x: Double, y: Double, count: Int) {
        self.button = button.rawValue; self.x = x; self.y = y; self.count = count
    }
    public var mouseButton: MouseButton? { MouseButton(wire: button) }
    public var normalized: CGPoint { CGPoint(x: x, y: y) }
    public var clampedCount: Int { min(max(count, 1), 3) }
}

public struct KeyPayload: Codable, Equatable {
    public var keycode: Int
    public var mods: Int
    public var chars: String?
    public init(keycode: Int, mods: KeyModifiers, chars: String? = nil) {
        self.keycode = keycode; self.mods = mods.rawValue; self.chars = chars
    }
    public var modifiers: KeyModifiers { KeyModifiers(wire: mods) }
    public var virtualKey: CGKeyCode? {
        guard keycode >= 0, keycode <= 0xFFFF else { return nil }
        return CGKeyCode(keycode)
    }
}

public struct ScrollPayload: Codable, Equatable {
    public var dx: Double
    public var dy: Double
    public var phase: String
    public init(dx: Double, dy: Double, phase: ScrollPhase) {
        self.dx = dx; self.dy = dy; self.phase = phase.rawValue
    }
    public var scrollPhase: ScrollPhase { ScrollPhase(wire: phase) }
}

public struct GesturePayload: Codable, Equatable {
    public var name: String
    public init(_ name: GestureName) { self.name = name.rawValue }
    public init(name: String) { self.name = name }
    public var gesture: GestureName? { GestureName(wire: name) }
}

public struct ClipboardTextPayload: Codable, Equatable, CustomStringConvertible {
    public var text: String
    public var originId: String
    public var hash: String

    public init(text: String, originId: String, hash: String) {
        self.text = text; self.originId = originId; self.hash = hash
    }

    public var description: String {
        "clipboard_text(originId: \(originId), hash: \(hash.prefix(8))…, \(text.utf8.count) bytes, text: <redacted>)"
    }
}
