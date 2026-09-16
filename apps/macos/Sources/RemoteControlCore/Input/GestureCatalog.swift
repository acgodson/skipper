import Foundation
import CoreGraphics

/// One keyboard shortcut, expanded into the event sequence real hardware would
/// produce.
///
/// Modifiers are pressed as `flagsChanged` events before the key and released
/// after it, rather than merely being set as flags on a single key-down. That
/// matters for the two shortcuts people notice: the Cmd+Tab switcher only stays
/// up while Command is genuinely held, and Cmd+Space's Spotlight ignores a
/// key-down whose modifier the window server never saw go down.
public struct KeyCombo: Equatable {

    public let keycode: CGKeyCode
    public let modifiers: KeyModifiers

    public init(_ keycode: CGKeyCode, _ modifiers: KeyModifiers = []) {
        self.keycode = keycode
        self.modifiers = modifiers
    }

    /// Canonical press order, so the expansion is deterministic and testable.
    static let pressOrder: [(KeyModifiers, CGKeyCode)] = [
        (.function, VirtualKey.function),
        (.control, VirtualKey.control),
        (.option, VirtualKey.option),
        (.shift, VirtualKey.shift),
        (.command, VirtualKey.command),
    ]

    public var events: [InjectedEvent] {
        var events: [InjectedEvent] = []
        var held: KeyModifiers = []
        let pressed = KeyCombo.pressOrder.filter { modifiers.contains($0.0) }
        for (modifier, keycode) in pressed {
            held.insert(modifier)
            events.append(.flagsChanged(keycode: keycode, flags: held))
        }
        events.append(.key(keycode: keycode, down: true, flags: held))
        events.append(.key(keycode: keycode, down: false, flags: held))
        for (modifier, keycode) in pressed.reversed() {
            held.remove(modifier)
            events.append(.flagsChanged(keycode: keycode, flags: held))
        }
        return events
    }
}

/// What a `gesture {name}` actually does on the host.
public enum GestureAction: Equatable {
    case combo(KeyCombo)
    case launchApplication(path: String)

    public var events: [InjectedEvent] {
        switch self {
        case .combo(let combo): return combo.events
        case .launchApplication(let path): return [.launchApplication(path: path)]
        }
    }
}

/// PLAN.md §2.4, stated honestly: a genuine multi-touch trackpad gesture cannot
/// be synthesised without private CoreGraphics SPI, which this project does not
/// ship. Every entry below invokes the SAME OS action through its public
/// keyboard equivalent (or, for Launchpad, by opening the system app), which is
/// what the user actually wants — the desktop raises — without code that breaks
/// on the next OS update.
///
/// The switch is exhaustive with no `default`, and `GestureName` is
/// `CaseIterable`, so a new gesture with no action is a compile error here and a
/// test failure in `gestureSuite` — never a button that silently does nothing.
public enum GestureCatalog {

    public static let launchpadPath = "/System/Applications/Launchpad.app"

    public static func action(for gesture: GestureName) -> GestureAction {
        switch gesture {
        case .missionControl:
            // Control+Up Arrow. The default macOS binding, and the same action
            // the three-finger swipe up produces.
            return .combo(KeyCombo(VirtualKey.upArrow, [.control]))
        case .appExpose:
            return .combo(KeyCombo(VirtualKey.downArrow, [.control]))
        case .showDesktop:
            // fn+F11 is the shipped default; F11 alone is only correct when the
            // user has ticked "Use F1, F2… as standard function keys", so the
            // fn flag is sent explicitly.
            return .combo(KeyCombo(VirtualKey.f11, [.function]))
        case .launchpad:
            // Launchpad has NO default key equivalent on a current macOS, so
            // this is the one gesture that cannot be a key combo at all.
            return .launchApplication(path: launchpadPath)
        case .spotlight:
            return .combo(KeyCombo(VirtualKey.space, [.command]))
        case .appSwitcher:
            // Cmd+Tab as a complete press-and-release: switches to the previous
            // application. Holding the switcher open would require the palette
            // to own the Command key for as long as the user hovers, which it
            // cannot — the toggle-style capture mode is the way to do that.
            return .combo(KeyCombo(VirtualKey.tab, [.command]))
        case .screenshotRegion:
            return .combo(KeyCombo(VirtualKey.four, [.command, .shift]))
        case .forceQuit:
            return .combo(KeyCombo(VirtualKey.escape, [.command, .option]))
        case .lockScreen:
            return .combo(KeyCombo(VirtualKey.q, [.control, .command]))
        }
    }

    public static func events(for gesture: GestureName) -> [InjectedEvent] {
        action(for: gesture).events
    }
}
