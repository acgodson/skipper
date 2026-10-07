import SwiftUI
import AppKit
import RemoteControlCore
import SkipperDesign

struct AccountSection: View {

    @EnvironmentObject private var model: AppModel

    var body: some View {
        SkipperCard(title: "Account") {
            switch model.account?.state ?? .unlinked {

            case .unlinked:
                VStack(alignment: .leading, spacing: SkipperSpace.s) {
                    Button("Sign in to SkipperDesk") { model.linkAccount() }
                        .skipperButton(.primary)
                    SkipperNote("Sign in to host this Mac and manage your plan.")
                }

            case .linking:
                HStack(spacing: SkipperSpace.s) {
                    ProgressView().controlSize(.small)
                    Text("Continue in your browser\u{2026}")
                        .font(SkipperFont.body)
                        .foregroundStyle(SkipperColor.textPrimary)
                    Spacer(minLength: SkipperSpace.s)
                    Button("Cancel") { model.cancelAccountLink() }
                        .skipperButton(.quiet)
                }

            case .linked(let accountLabel, let device):
                SignedInRow(
                    accountLabel: accountLabel,
                    deviceName: device.label.isEmpty ? DeviceID.formatted(device.deviceId) : device.label
                )

            case .error(let message):
                HStack(spacing: SkipperSpace.m) {
                    Text(message)
                        .font(SkipperFont.body)
                        .foregroundStyle(SkipperColor.critical)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: SkipperSpace.s)
                    Button("Try again") { model.retryAccount() }
                        .skipperButton(.secondary)
                }
            }
        }
        .onAppear {
            guard model.account?.entitlement?.isStale == true else { return }
            Task { await model.account?.refreshEntitlement() }
        }
    }
}

private struct SignedInRow: View {

    @EnvironmentObject private var model: AppModel
    let accountLabel: String?
    let deviceName: String

    private var name: String { accountLabel ?? "Signed in" }

    var body: some View {
        HStack(alignment: .center, spacing: SkipperSpace.m) {
            AccountAvatar(name: name)

            VStack(alignment: .leading, spacing: SkipperSpace.xxs) {
                Text(name)
                    .font(SkipperFont.bodyEmphasis)
                    .foregroundStyle(SkipperColor.textPrimary)
                    .textSelection(.enabled)
                if let entitlement = model.account?.entitlement?.value {
                    Text(EntitlementPresentation.statusLine(for: entitlement))
                        .font(SkipperFont.callout)
                        .foregroundStyle(SkipperColor.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text("This Mac appears in your account as \(deviceName)")
                    .font(SkipperFont.caption)
                    .foregroundStyle(SkipperColor.textTertiary)
            }

            Spacer(minLength: SkipperSpace.s)

            if model.account?.entitlement?.value.status == .exhausted {
                Button("Top Up\u{2026}") { AccountActions.openOnTheWeb(EntitlementPresentation.topUpURL) }
                    .skipperButton(.primary)
            }

            Menu {
                Button("Account on the web\u{2026}") {
                    AccountActions.openOnTheWeb(EntitlementPresentation.accountURL)
                }
                Button("Add credit\u{2026}") {
                    AccountActions.openOnTheWeb(EntitlementPresentation.topUpURL)
                }
                Divider()
                Button("Sign Out\u{2026}") { AccountActions.confirmSignOut(model) }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .foregroundStyle(SkipperColor.textSecondary)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Account actions")
        }
    }
}

struct AccountAvatar: View {

    let name: String
    var size: CGFloat = 36

    private var initial: String {
        name.first(where: { $0.isLetter || $0.isNumber }).map { String($0).uppercased() } ?? "?"
    }

    var body: some View {
        Text(initial)
            .font(.system(size: size * 0.44, weight: .semibold))
            .foregroundStyle(SkipperColor.onAccent)
            .frame(width: size, height: size)
            .background(Circle().fill(SkipperColor.accent))
    }
}

enum AccountActions {

    static func openOnTheWeb(_ page: (URL) -> URL) {
        NSWorkspace.shared.open(page(AccountLinker.defaultWebBaseURL()))
    }

    @MainActor
    static func confirmSignOut(_ model: AppModel) {
        let alert = NSAlert()
        alert.messageText = "Sign out of SkipperDesk?"
        alert.informativeText = "This Mac stops accepting remote sessions until you sign in again. Its Device ID and access code stay the same."
        alert.addButton(withTitle: "Sign Out")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.hasDestructiveAction = true
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            model.unlinkAccount()
        }
    }
}

final class AccountBrowserOpener {

    func open(_ url: URL) {
        NSWorkspace.shared.open(url)
    }
}
