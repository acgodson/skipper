import SwiftUI

public struct SkipperCard<Content: View>: View {

    private let title: String?
    private let accessory: AnyView?
    private let content: Content

    public init(
        title: String? = nil,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.accessory = nil
        self.content = content()
    }

    public init<Accessory: View>(
        title: String?,
        @ViewBuilder accessory: () -> Accessory,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.accessory = AnyView(accessory())
        self.content = content()
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: SkipperSpace.m) {
            if title != nil || accessory != nil {
                HStack(alignment: .firstTextBaseline, spacing: SkipperSpace.s) {
                    if let title {
                        Text(title.uppercased())
                            .font(SkipperFont.sectionLabel)
                            .tracking(0.6)
                            .foregroundStyle(SkipperColor.textTertiary)
                    }
                    Spacer(minLength: 0)
                    accessory
                }
            }
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(SkipperSpace.l)
        .background(
            RoundedRectangle(cornerRadius: SkipperRadius.large, style: .continuous)
                .fill(SkipperColor.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: SkipperRadius.large, style: .continuous)
                .strokeBorder(SkipperColor.border)
        )
        .skipperElevation(.low)
    }
}

public struct SkipperDivider: View {
    public init() {}
    public var body: some View {
        Rectangle()
            .fill(SkipperColor.border)
            .frame(height: 1)
    }
}

public struct SkipperRow<Trailing: View>: View {

    private let title: String
    private let subtitle: String?
    private let monospacedSubtitle: Bool
    private let trailing: Trailing

    public init(
        title: String,
        subtitle: String? = nil,
        monospacedSubtitle: Bool = false,
        @ViewBuilder trailing: () -> Trailing
    ) {
        self.title = title
        self.subtitle = subtitle
        self.monospacedSubtitle = monospacedSubtitle
        self.trailing = trailing()
    }

    public var body: some View {
        HStack(alignment: .center, spacing: SkipperSpace.m) {
            VStack(alignment: .leading, spacing: SkipperSpace.xxs) {
                Text(title)
                    .font(SkipperFont.bodyEmphasis)
                    .foregroundStyle(SkipperColor.textPrimary)
                if let subtitle {
                    Text(subtitle)
                        .font(monospacedSubtitle ? SkipperFont.codeCaption : SkipperFont.caption)
                        .foregroundStyle(SkipperColor.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: SkipperSpace.s)
            trailing
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

public struct SkipperFieldLabel: View {

    private let text: String

    public init(_ text: String) {
        self.text = text
    }

    public var body: some View {
        Text(text)
            .font(SkipperFont.caption)
            .foregroundStyle(SkipperColor.textSecondary)
    }
}

public struct SkipperNote: View {

    private let text: String
    private let tone: SkipperTone

    public init(_ text: String, tone: SkipperTone = .neutral) {
        self.text = text
        self.tone = tone
    }

    public var body: some View {
        Text(text)
            .font(SkipperFont.caption)
            .foregroundStyle(tone == .neutral ? SkipperColor.textSecondary : tone.foreground)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}
