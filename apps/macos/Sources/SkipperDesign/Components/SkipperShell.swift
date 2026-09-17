import SwiftUI

public struct SkipperScreen<Content: View>: View {

    private let content: Content

    public init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: SkipperSpace.l) {
                content
            }
            .padding(.horizontal, SkipperSpace.xl)
            .padding(.vertical, SkipperSpace.xl)
            .frame(maxWidth: SkipperLayout.contentMaxWidth, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .background(SkipperColor.canvas)
    }
}

public struct SkipperHero<Content: View>: View {

    private let content: Content

    public init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: SkipperSpace.l) {
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(SkipperSpace.xl)
        .background(
            RoundedRectangle(cornerRadius: SkipperRadius.large, style: .continuous)
                .fill(SkipperColor.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: SkipperRadius.large, style: .continuous)
                .strokeBorder(SkipperColor.accent.opacity(0.35))
        )
        .skipperElevation(.low)
    }
}

public struct SkipperMenuPanel<Content: View>: View {

    private let content: Content

    public init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: SkipperSpace.m) {
            content
        }
        .padding(SkipperSpace.l)
        .frame(width: 280, alignment: .leading)
        .background(SkipperColor.surface)
    }
}

public struct SkipperMenuAction: View {

    private let title: String
    private let symbol: String
    private let action: () -> Void

    @Environment(\.isEnabled) private var isEnabled
    @State private var hovering = false

    public init(title: String, symbol: String, action: @escaping () -> Void) {
        self.title = title
        self.symbol = symbol
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            HStack(spacing: SkipperSpace.s) {
                Image(systemName: symbol)
                    .font(.system(size: 12, weight: .medium))
                    .frame(width: 16)
                Text(title)
                    .font(SkipperFont.body)
                Spacer(minLength: 0)
            }
            .foregroundStyle(isEnabled ? SkipperColor.textPrimary : SkipperColor.textTertiary)
            .padding(.horizontal, SkipperSpace.s)
            .padding(.vertical, SkipperSpace.s - 2)
            .background(
                RoundedRectangle(cornerRadius: SkipperRadius.small, style: .continuous)
                    .fill(hovering && isEnabled ? SkipperColor.surfaceMuted : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}
