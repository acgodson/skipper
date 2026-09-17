import SwiftUI

public struct SkipperTextField: View {

    private let label: String
    private let placeholder: String
    private let text: Binding<String>
    private let monospaced: Bool
    private let secure: Bool
    private let note: String?

    @FocusState private var focused: Bool

    public init(
        label: String,
        placeholder: String,
        text: Binding<String>,
        monospaced: Bool = false,
        secure: Bool = false,
        note: String? = nil
    ) {
        self.label = label
        self.placeholder = placeholder
        self.text = text
        self.monospaced = monospaced
        self.secure = secure
        self.note = note
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: SkipperSpace.xs) {
            SkipperFieldLabel(label)
            Group {
                if secure {
                    SecureField(placeholder, text: text)
                } else {
                    TextField(placeholder, text: text)
                }
            }
            .textFieldStyle(.plain)
            .font(monospaced ? SkipperFont.code : SkipperFont.body)
            .foregroundStyle(SkipperColor.textPrimary)
            .focused($focused)
            .padding(.horizontal, SkipperSpace.m - 2)
            .padding(.vertical, SkipperSpace.s)
            .background(
                RoundedRectangle(cornerRadius: SkipperRadius.small, style: .continuous)
                    .fill(SkipperColor.surfaceMuted)
            )
            .overlay(
                RoundedRectangle(cornerRadius: SkipperRadius.small, style: .continuous)
                    .strokeBorder(focused ? SkipperColor.accent : SkipperColor.border,
                                  lineWidth: focused ? 2 : 1)
            )
            .animation(SkipperMotion.quick, value: focused)

            if let note {
                SkipperNote(note)
            }
        }
    }
}

public struct SkipperToggleRow: View {

    private let title: String
    private let detail: String?
    private let isOn: Binding<Bool>

    public init(title: String, detail: String? = nil, isOn: Binding<Bool>) {
        self.title = title
        self.detail = detail
        self.isOn = isOn
    }

    public var body: some View {
        HStack(alignment: .top, spacing: SkipperSpace.m) {
            VStack(alignment: .leading, spacing: SkipperSpace.xxs) {
                Text(title)
                    .font(SkipperFont.bodyEmphasis)
                    .foregroundStyle(SkipperColor.textPrimary)
                if let detail {
                    Text(detail)
                        .font(SkipperFont.caption)
                        .foregroundStyle(SkipperColor.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: SkipperSpace.s)
            Toggle("", isOn: isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .tint(SkipperColor.accent)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
