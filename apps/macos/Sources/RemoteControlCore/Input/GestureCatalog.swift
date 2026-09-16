import Foundation
import CoreGraphics

public struct KeyCombo: Equatable {

    public let keycode: CGKeyCode
    public let modifiers: KeyModifiers

    public init(_ keycode: CGKeyCode, _ modifiers: KeyModifiers = []) {
        self.keycode = keycode
        self.modifiers = modifiers
    }

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

public enum GestureCatalog {

    public static let launchpadPath = "/System/Applications/Launchpad.app"

    public static func action(for gesture: GestureName) -> GestureAction {
        switch gesture {
        case .missionControl:
            return .combo(KeyCombo(VirtualKey.upArrow, [.control]))
        case .appExpose:
            return .combo(KeyCombo(VirtualKey.downArrow, [.control]))
        case .showDesktop:
            return .combo(KeyCombo(VirtualKey.f11, [.function]))
        case .launchpad:
            return .launchApplication(path: launchpadPath)
        case .spotlight:
            return .combo(KeyCombo(VirtualKey.space, [.command]))
        case .appSwitcher:
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
