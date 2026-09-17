import SwiftUI

public enum SkipperButtonKind {
    case primary
    case secondary
    case quiet
    case destructive
}

public struct SkipperButtonStyle: ButtonStyle {

    public let kind: SkipperButtonKind
    @Environment(\.isEnabled) private var isEnabled

    public init(_ kind: SkipperButtonKind) {
        self.kind = kind
    }

    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(SkipperFont.bodyEmphasis)
            .foregroundStyle(foreground)
            .padding(.horizontal, SkipperSpace.m)
            .padding(.vertical, SkipperSpace.s - 1)
            .background(
                RoundedRectangle(cornerRadius: SkipperRadius.small, style: .continuous)
                    .fill(background(pressed: configuration.isPressed))
            )
            .overlay(
                RoundedRectangle(cornerRadius: SkipperRadius.small, style: .continuous)
                    .strokeBorder(stroke)
            )
            .opacity(isEnabled ? 1.0 : 0.45)
            .contentShape(Rectangle())
            .animation(SkipperMotion.quick, value: configuration.isPressed)
    }

    private var foreground: Color {
        switch kind {
        case .primary: return SkipperColor.onAccent
        case .secondary: return SkipperColor.textPrimary
        case .quiet: return SkipperColor.accent
        case .destructive: return SkipperColor.critical
        }
    }

    private func background(pressed: Bool) -> Color {
        switch kind {
        case .primary: return pressed ? SkipperColor.accentPressed : SkipperColor.accent
        case .secondary: return pressed ? SkipperColor.neutralSoft : SkipperColor.surfaceMuted
        case .quiet: return pressed ? SkipperColor.accentSoft : Color.clear
        case .destructive: return pressed ? SkipperColor.criticalSoft : Color.clear
        }
    }

    private var stroke: Color {
        switch kind {
        case .primary: return Color.clear
        case .secondary: return SkipperColor.border
        case .quiet: return Color.clear
        case .destructive: return SkipperColor.critical.opacity(0.5)
        }
    }
}

extension View {
    public func skipperButton(_ kind: SkipperButtonKind) -> some View {
        buttonStyle(SkipperButtonStyle(kind))
    }
}

public struct SkipperIconButton: View {

    private let symbol: String
    private let help: String
    private let action: () -> Void

    @State private var hovering = false

    public init(symbol: String, help: String, action: @escaping () -> Void) {
        self.symbol = symbol
        self.help = help
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(hovering ? SkipperColor.accent : SkipperColor.textSecondary)
                .frame(width: 24, height: 24)
                .background(
                    RoundedRectangle(cornerRadius: SkipperRadius.small, style: .continuous)
                        .fill(hovering ? SkipperColor.surfaceMuted : Color.clear)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
    }
}
