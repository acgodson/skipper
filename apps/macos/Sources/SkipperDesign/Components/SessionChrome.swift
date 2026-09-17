import SwiftUI

public struct StageOverlayCard: View {

    private let title: String
    private let message: String
    private let showsProgress: Bool

    public init(title: String, message: String, showsProgress: Bool = true) {
        self.title = title
        self.message = message
        self.showsProgress = showsProgress
    }

    public var body: some View {
        VStack(spacing: SkipperSpace.s) {
            if showsProgress {
                ProgressView()
                    .controlSize(.small)
                    .tint(SkipperColor.onStage)
            }
            Text(title)
                .font(SkipperFont.heading)
                .foregroundStyle(SkipperColor.onStage)
            Text(message)
                .font(SkipperFont.caption)
                .foregroundStyle(SkipperColor.onStage.opacity(0.75))
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(SkipperSpace.xl)
        .background(
            RoundedRectangle(cornerRadius: SkipperRadius.large, style: .continuous)
                .fill(SkipperColor.scrim)
        )
        .overlay(
            RoundedRectangle(cornerRadius: SkipperRadius.large, style: .continuous)
                .strokeBorder(SkipperColor.onStage.opacity(0.12))
        )
        .skipperElevation(.high)
    }
}

public struct SessionToolbarBar<Content: View>: View {

    private let content: Content

    public init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    public var body: some View {
        HStack(spacing: SkipperSpace.m) {
            content
        }
        .padding(.horizontal, SkipperSpace.l)
        .padding(.vertical, SkipperSpace.s)
        .background(.ultraThinMaterial, in: Capsule(style: .continuous))
        .overlay(
            Capsule(style: .continuous)
                .strokeBorder(SkipperColor.onStage.opacity(0.10))
        )
        .skipperElevation(.high)
    }
}

public struct SessionToolbarButton: View {

    private let title: String
    private let symbol: String
    private let isActive: Bool
    private let tone: SkipperTone
    private let help: String
    private let action: () -> Void

    @State private var hovering = false

    public init(
        title: String,
        symbol: String,
        isActive: Bool = false,
        tone: SkipperTone = .neutral,
        help: String,
        action: @escaping () -> Void
    ) {
        self.title = title
        self.symbol = symbol
        self.isActive = isActive
        self.tone = tone
        self.help = help
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            HStack(spacing: SkipperSpace.s - 2) {
                Image(systemName: symbol)
                    .font(.system(size: 11, weight: .medium))
                Text(title)
                    .font(SkipperFont.caption.weight(.medium))
                    .fixedSize()
            }
            .foregroundStyle(foreground)
            .padding(.horizontal, SkipperSpace.m - 2)
            .padding(.vertical, SkipperSpace.xs + 1)
            .background(
                Capsule(style: .continuous).fill(background)
            )
            .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
        .animation(SkipperMotion.quick, value: isActive)
    }

    private var foreground: Color {
        if isActive { return SkipperColor.onAccent }
        if tone == .critical { return SkipperColor.critical }
        return SkipperColor.textPrimary
    }

    private var background: Color {
        if isActive { return SkipperColor.accent }
        if hovering { return SkipperColor.surfaceMuted }
        return Color.clear
    }
}
