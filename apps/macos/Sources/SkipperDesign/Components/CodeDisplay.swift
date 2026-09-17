import SwiftUI
import AppKit

public struct CodeDisplay<Trailing: View>: View {

    private let label: String
    private let value: String
    private let maskedValue: String?
    private let copyValue: String
    private let copyAction: ((String) -> Void)?
    private let copyDisabled: Bool
    private let trailing: Trailing

    @State private var copied = false

    public init(
        label: String,
        value: String,
        maskedValue: String? = nil,
        copyValue: String? = nil,
        copyDisabled: Bool = false,
        copyAction: ((String) -> Void)? = nil,
        @ViewBuilder trailing: () -> Trailing
    ) {
        self.label = label
        self.value = value
        self.maskedValue = maskedValue
        self.copyValue = copyValue ?? value
        self.copyDisabled = copyDisabled
        self.copyAction = copyAction
        self.trailing = trailing()
    }

    private var isMasked: Bool { maskedValue != nil }

    public var body: some View {
        VStack(alignment: .leading, spacing: SkipperSpace.xs) {
            HStack(spacing: SkipperSpace.s) {
                SkipperFieldLabel(label)
                if copied {
                    Text("Copied")
                        .font(SkipperFont.caption)
                        .foregroundStyle(SkipperColor.positive)
                        .transition(.opacity)
                }
            }

            HStack(alignment: .center, spacing: SkipperSpace.m) {
                Group {
                    if isMasked {
                        Text(maskedValue ?? value).textSelection(.disabled)
                    } else {
                        Text(value).textSelection(.enabled)
                    }
                }
                    .font(SkipperFont.codeHero)
                    .foregroundStyle(SkipperColor.textPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                    .fixedSize(horizontal: false, vertical: true)

                Spacer(minLength: SkipperSpace.s)

                HStack(spacing: SkipperSpace.xs) {
                    SkipperIconButton(symbol: "doc.on.doc", help: "Copy \(label)") { copy() }
                        .disabled(copyDisabled)
                        .opacity(copyDisabled ? 0.4 : 1)
                    trailing
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func copy() {
        guard !copyDisabled else { return }
        if let copyAction {
            copyAction(copyValue)
        } else {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(copyValue, forType: .string)
        }
        withAnimation(SkipperMotion.quick) { copied = true }
        Task {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            withAnimation(SkipperMotion.standard) { copied = false }
        }
    }
}

extension CodeDisplay where Trailing == EmptyView {
    public init(label: String, value: String, maskedValue: String? = nil, copyValue: String? = nil) {
        self.init(label: label, value: value, maskedValue: maskedValue, copyValue: copyValue) { EmptyView() }
    }
}
