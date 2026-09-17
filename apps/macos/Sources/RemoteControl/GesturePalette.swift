import SwiftUI
import RemoteControlCore
import SkipperDesign

struct GesturePalette: View {

    @EnvironmentObject private var model: AppModel
    @Binding var isExpanded: Bool

    private static let order: [GestureName] = [
        .missionControl, .appExpose, .showDesktop, .launchpad,
        .spotlight, .appSwitcher, .screenshotRegion, .forceQuit, .lockScreen,
    ]

    var body: some View {
        VStack(alignment: .trailing, spacing: SkipperSpace.s) {
            if isExpanded {
                VStack(spacing: SkipperSpace.xxs) {
                    ForEach(GesturePalette.order, id: \.self) { gesture in
                        GestureButton(gesture: gesture) { model.coordinator?.sendGesture(gesture) }
                    }
                }
                .padding(SkipperSpace.s - 2)
                .frame(width: 210)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: SkipperRadius.large, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: SkipperRadius.large, style: .continuous)
                        .strokeBorder(SkipperColor.onStage.opacity(0.12))
                )
                .skipperElevation(.high)
                .transition(.move(edge: .trailing).combined(with: .opacity))
            }

            Button {
                withAnimation(SkipperMotion.standard) { isExpanded.toggle() }
            } label: {
                Image(systemName: isExpanded ? "xmark" : "hand.tap.fill")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(SkipperColor.onAccent)
                    .frame(width: 40, height: 40)
                    .background(Circle().fill(SkipperColor.accent))
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .skipperElevation(.high)
            .help(isExpanded ? "Hide the gesture palette" : "Gesture palette \u{2014} Mission Control, Spotlight, Launchpad and more, performed on the other Mac")
        }
        .padding(SkipperSpace.l)
    }
}

private struct GestureButton: View {
    let gesture: GestureName
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: SkipperSpace.s) {
                Image(systemName: gesture.symbolName)
                    .frame(width: 18)
                    .foregroundStyle(hovering ? SkipperColor.accent : SkipperColor.textSecondary)
                Text(gesture.displayName)
                    .font(SkipperFont.callout)
                    .foregroundStyle(SkipperColor.textPrimary)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, SkipperSpace.s)
            .padding(.vertical, SkipperSpace.s - 3)
            .background(
                RoundedRectangle(cornerRadius: SkipperRadius.small, style: .continuous)
                    .fill(hovering ? SkipperColor.surfaceMuted : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(GesturePalette.help(for: gesture))
    }
}

extension GesturePalette {
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
