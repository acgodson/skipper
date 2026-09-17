import SwiftUI

public struct StatusPill: View {

    private let text: String
    private let tone: SkipperTone
    private let showsDot: Bool

    public init(_ text: String, tone: SkipperTone, showsDot: Bool = true) {
        self.text = text
        self.tone = tone
        self.showsDot = showsDot
    }

    public var body: some View {
        HStack(spacing: SkipperSpace.s - 2) {
            if showsDot {
                Circle()
                    .fill(tone.foreground)
                    .frame(width: 7, height: 7)
            }
            Text(text)
                .font(SkipperFont.caption.weight(.semibold))
                .foregroundStyle(tone.foreground)
                .fixedSize()
        }
        .padding(.horizontal, SkipperSpace.m - 2)
        .padding(.vertical, SkipperSpace.xs + 1)
        .background(
            Capsule(style: .continuous).fill(tone.background)
        )
        .animation(SkipperMotion.standard, value: text)
    }
}

public struct PresenceDot: View {

    private let tone: SkipperTone
    private let label: String

    public init(tone: SkipperTone, label: String) {
        self.tone = tone
        self.label = label
    }

    public var body: some View {
        HStack(spacing: SkipperSpace.s - 2) {
            Circle()
                .fill(tone.foreground)
                .frame(width: 8, height: 8)
            Text(label)
                .font(SkipperFont.callout)
                .foregroundStyle(SkipperColor.textSecondary)
                .fixedSize()
        }
    }
}
