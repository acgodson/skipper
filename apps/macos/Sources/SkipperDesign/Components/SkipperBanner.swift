import SwiftUI

public struct SkipperBanner<Trailing: View>: View {

    private let tone: SkipperTone
    private let symbol: String
    private let title: String
    private let message: String?
    private let trailing: Trailing

    public init(
        tone: SkipperTone,
        symbol: String,
        title: String,
        message: String? = nil,
        @ViewBuilder trailing: () -> Trailing
    ) {
        self.tone = tone
        self.symbol = symbol
        self.title = title
        self.message = message
        self.trailing = trailing()
    }

    public var body: some View {
        HStack(alignment: .top, spacing: SkipperSpace.m) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(tone.foreground)
                .padding(.top, 1)

            VStack(alignment: .leading, spacing: SkipperSpace.xs) {
                Text(title)
                    .font(SkipperFont.bodyEmphasis)
                    .foregroundStyle(SkipperColor.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                if let message {
                    Text(message)
                        .font(SkipperFont.caption)
                        .foregroundStyle(SkipperColor.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Spacer(minLength: SkipperSpace.s)
            trailing
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(SkipperSpace.m)
        .background(
            RoundedRectangle(cornerRadius: SkipperRadius.medium, style: .continuous)
                .fill(tone.background)
        )
        .overlay(
            RoundedRectangle(cornerRadius: SkipperRadius.medium, style: .continuous)
                .strokeBorder(tone.foreground.opacity(0.35))
        )
    }
}

extension SkipperBanner where Trailing == EmptyView {
    public init(tone: SkipperTone, symbol: String, title: String, message: String? = nil) {
        self.init(tone: tone, symbol: symbol, title: title, message: message) { EmptyView() }
    }
}
