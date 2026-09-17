import SwiftUI

public enum SkipperConsentPromptStyle {
    case window
    case menu
}

public struct SkipperConsentPrompt: View {

    private let title: String
    private let message: String
    private let notice: String?
    private let details: [String]
    private let countdown: String
    private let style: SkipperConsentPromptStyle
    private let allowEnabled: Bool
    private let allow: () -> Void
    private let decline: () -> Void

    public init(
        title: String,
        message: String,
        notice: String? = nil,
        details: [String] = [],
        countdown: String,
        style: SkipperConsentPromptStyle = .window,
        allowEnabled: Bool = true,
        allow: @escaping () -> Void,
        decline: @escaping () -> Void
    ) {
        self.title = title
        self.message = message
        self.notice = notice
        self.details = details
        self.countdown = countdown
        self.style = style
        self.allowEnabled = allowEnabled
        self.allow = allow
        self.decline = decline
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: style == .window ? SkipperSpace.l : SkipperSpace.s) {
            HStack(alignment: .top, spacing: SkipperSpace.m) {
                Image(systemName: "hand.raised.fill")
                    .font(.system(size: style == .window ? 20 : 15, weight: .medium))
                    .foregroundStyle(SkipperColor.accent)
                    .padding(.top, 1)
                VStack(alignment: .leading, spacing: SkipperSpace.xs) {
                    Text(title)
                        .font(style == .window ? SkipperFont.heading : SkipperFont.bodyEmphasis)
                        .foregroundStyle(SkipperColor.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                    if let notice {
                        Text(notice)
                            .font(SkipperFont.caption.weight(.semibold))
                            .foregroundStyle(SkipperColor.attention)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Text(message)
                        .font(SkipperFont.caption)
                        .foregroundStyle(SkipperColor.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    ForEach(details, id: \.self) { detail in
                        Text(detail)
                            .font(SkipperFont.codeCaption)
                            .foregroundStyle(SkipperColor.textTertiary)
                    }
                }
            }

            HStack(spacing: SkipperSpace.s) {
                StatusPill(countdown, tone: .attention)
                Spacer(minLength: SkipperSpace.s)
                Button("Decline", action: decline)
                    .skipperButton(.secondary)
                    .keyboardShortcut(.cancelAction)
                Button("Allow", action: allow)
                    .skipperButton(.primary)
                    .disabled(!allowEnabled)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(style == .window ? SkipperSpace.xl : SkipperSpace.m)
        .background(
            RoundedRectangle(cornerRadius: SkipperRadius.large, style: .continuous)
                .fill(style == .window ? SkipperColor.surface : SkipperColor.accentSoft)
        )
        .overlay(
            RoundedRectangle(cornerRadius: SkipperRadius.large, style: .continuous)
                .strokeBorder(SkipperColor.accent.opacity(0.35))
        )
        .skipperElevation(style == .window ? .high : .none)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(title)
    }
}
