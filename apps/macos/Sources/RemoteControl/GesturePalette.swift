import SwiftUI
import RemoteControlCore

/// The floating action palette (PLAN.md §2.4, mechanism 2).
///
/// **Why it exists at all.** Capture mode forwards keystrokes, but some macOS
/// actions have no key equivalent a tap could forward — Launchpad has no
/// default shortcut, and Mission Control is a trackpad gesture most people
/// never learned the key for. These are semantic commands: the controller sends
/// `gesture {name}` and the host performs the action natively.
///
/// **What it is not.** It does not synthesise multi-touch. PLAN.md §2.4 records
/// that decision: a genuine three-finger swipe needs private CoreGraphics SPI,
/// and every button here invokes the same OS action through a public API.
struct GesturePalette: View {

    @EnvironmentObject private var model: AppModel
    @Binding var isExpanded: Bool

    /// Ordered for the hand, not alphabetically: the four everyday ones first.
    private static let order: [GestureName] = [
        .missionControl, .appExpose, .showDesktop, .launchpad,
        .spotlight, .appSwitcher, .screenshotRegion, .forceQuit, .lockScreen,
    ]

    var body: some View {
        VStack(alignment: .trailing, spacing: 8) {
            if isExpanded {
                VStack(spacing: 2) {
                    ForEach(GesturePalette.order, id: \.self) { gesture in
                        GestureButton(gesture: gesture) { model.coordinator?.sendGesture(gesture) }
                    }
                }
                .padding(6)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.12))
                )
                .shadow(radius: 12, y: 4)
                .transition(.move(edge: .trailing).combined(with: .opacity))
            }

            Button {
                withAnimation(.easeOut(duration: 0.15)) { isExpanded.toggle() }
            } label: {
                Image(systemName: isExpanded ? "chevron.right.circle.fill" : "hand.tap.fill")
                    .font(.title2)
                    .padding(8)
            }
            .buttonStyle(.plain)
            .background(.regularMaterial, in: Circle())
            .shadow(radius: 8, y: 2)
            .help(isExpanded ? "Hide the gesture palette" : "Gesture palette \u{2014} Mission Control, Spotlight, Launchpad and more, performed on the other Mac")
        }
        .padding(14)
    }
}

private struct GestureButton: View {
    let gesture: GestureName
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: gesture.symbolName)
                    .frame(width: 18)
                Text(gesture.displayName)
                    .font(.callout)
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
        }
        .buttonStyle(.plain)
        .help(GesturePalette.help(for: gesture))
    }
}

extension GesturePalette {
    /// The honest description: what the host will actually do. Nothing here
    /// claims to be a trackpad gesture.
    static func help(for gesture: GestureName) -> String {
        switch GestureCatalog.action(for: gesture) {
        case .combo(let combo):
            return "Sends \(describe(combo)) on the other Mac."
        case .launchApplication(let path):
            return "Opens \((path as NSString).lastPathComponent) on the other Mac."
        }
    }

    private static func describe(_ combo: KeyCombo) -> String {
        var parts: [String] = []
        if combo.modifiers.contains(.function) { parts.append("fn") }
        if combo.modifiers.contains(.control) { parts.append("Control") }
        if combo.modifiers.contains(.option) { parts.append("Option") }
        if combo.modifiers.contains(.shift) { parts.append("Shift") }
        if combo.modifiers.contains(.command) { parts.append("Command") }
        parts.append(keyName(combo.keycode))
        return parts.joined(separator: "-")
    }

    private static func keyName(_ keycode: CGKeyCode) -> String {
        switch keycode {
        case VirtualKey.space: return "Space"
        case VirtualKey.tab: return "Tab"
        case VirtualKey.escape: return "Escape"
        case VirtualKey.q: return "Q"
        case VirtualKey.four: return "4"
        case VirtualKey.f11: return "F11"
        case VirtualKey.upArrow: return "Up Arrow"
        case VirtualKey.downArrow: return "Down Arrow"
        default: return "key \(keycode)"
        }
    }
}
