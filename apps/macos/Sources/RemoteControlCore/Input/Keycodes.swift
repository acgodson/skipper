import Foundation
import CoreGraphics

/// The handful of macOS virtual keycodes (`kVK_*` from Carbon's `Events.h`) this
/// code names explicitly.
///
/// They are written out rather than imported because Carbon's `Events.h` is not
/// reachable from a SwiftPM target without a bridging header, and because these
/// nine constants are load-bearing: `spotlight` sending the wrong keycode is a
/// silent no-op on the remote machine, not a build error.
public enum VirtualKey {
    public static let tab: CGKeyCode = 48
    public static let space: CGKeyCode = 49
    public static let escape: CGKeyCode = 53
    public static let q: CGKeyCode = 12
    public static let four: CGKeyCode = 21
    public static let f11: CGKeyCode = 103
    public static let upArrow: CGKeyCode = 126
    public static let downArrow: CGKeyCode = 125

    // Modifier keys. A modifier is NOT delivered as a key-down: macOS posts
    // `kCGEventFlagsChanged` for these, and an app that receives a plain keyDown
    // with keycode 55 does not treat Command as held. Injecting the wrong event
    // type here is exactly how a Cmd key gets "stuck" from the OS's point of
    // view, so the injector branches on this set.
    public static let command: CGKeyCode = 55
    public static let rightCommand: CGKeyCode = 54
    public static let shift: CGKeyCode = 56
    public static let rightShift: CGKeyCode = 60
    public static let capsLock: CGKeyCode = 57
    public static let option: CGKeyCode = 58
    public static let rightOption: CGKeyCode = 61
    public static let control: CGKeyCode = 59
    public static let rightControl: CGKeyCode = 62
    public static let function: CGKeyCode = 63

    public static let modifierKeycodes: Set<CGKeyCode> = [
        command, rightCommand, shift, rightShift, capsLock,
        option, rightOption, control, rightControl, function,
    ]

    public static func isModifier(_ keycode: CGKeyCode) -> Bool {
        modifierKeycodes.contains(keycode)
    }

    /// Which modifier bit a modifier keycode contributes. Non-modifier keycodes
    /// contribute nothing.
    public static func modifier(for keycode: CGKeyCode) -> KeyModifiers {
        switch keycode {
        case command, rightCommand: return .command
        case shift, rightShift: return .shift
        case capsLock: return .capsLock
        case option, rightOption: return .option
        case control, rightControl: return .control
        case function: return .function
        default: return []
        }
    }
}
