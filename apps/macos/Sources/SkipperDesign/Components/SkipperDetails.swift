import SwiftUI

/// The one place facts that are not for normal reading live: a quiet
/// disclosure that stays shut until the person opens it.
public struct SkipperDetails: View {

    private let label: String
    private let lines: [String]

    @State private var expanded = false

    public init(_ label: String = "Details", lines: [String]) {
        self.label = label
        self.lines = lines.filter { !$0.isEmpty }
    }

    public var body: some View {
        if !lines.isEmpty {
            VStack(alignment: .leading, spacing: SkipperSpace.xs) {
                Button {
                    withAnimation(SkipperMotion.standard) { expanded.toggle() }
                } label: {
                    HStack(spacing: SkipperSpace.xxs) {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 9, weight: .semibold))
                            .rotationEffect(.degrees(expanded ? 90 : 0))
                        Text(label)
                            .font(SkipperFont.caption)
                    }
                    .foregroundStyle(SkipperColor.textTertiary)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(expanded ? "Hide details" : "Show details")

                if expanded {
                    VStack(alignment: .leading, spacing: SkipperSpace.xxs) {
                        ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                            Text(line)
                                .font(SkipperFont.codeCaption)
                                .foregroundStyle(SkipperColor.textTertiary)
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
