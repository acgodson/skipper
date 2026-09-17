import SwiftUI
import AppKit
import RemoteControlCore
import SkipperDesign

struct MenuBarContent: View {

    @EnvironmentObject private var model: AppModel
    @Environment(\.openWindow) private var openWindow

    private var status: ConnectionStatus {
        model.settings.role == .host ? model.connectionStatus : controllerStatus
    }

    private var controllerStatus: ConnectionStatus {
        if model.isReconnecting { return .reconnecting }
        if model.sessionActive { return .sessionActive }
        if model.isConnecting { return .connecting }
        return model.coordinator?.signalingState.isAuthenticated == true ? .online : .offline
    }

    @ViewBuilder
    private var accountRows: some View {
        switch model.account?.state ?? .unlinked {
        case .linked(let accountLabel, _):
            HStack(spacing: SkipperSpace.s) {
                AccountAvatar(name: accountLabel ?? "Signed in", size: 24)
                Text(accountLabel ?? "Signed in")
                    .font(SkipperFont.body)
                    .foregroundStyle(SkipperColor.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            SkipperMenuAction(title: "Sign Out\u{2026}", symbol: "rectangle.portrait.and.arrow.right") {
                AccountActions.confirmSignOut(model)
            }
        case .linking:
            SkipperNote("Continue in your browser\u{2026}")
        case .unlinked, .error:
            SkipperMenuAction(title: "Sign In\u{2026}", symbol: "person.crop.circle") {
                model.linkAccount()
            }
        }
    }

    var body: some View {
        SkipperMenuPanel {
            HStack(alignment: .firstTextBaseline) {
                Text("SkipperDesk")
                    .font(SkipperFont.heading)
                    .foregroundStyle(SkipperColor.textPrimary)
                Spacer(minLength: SkipperSpace.s)
                StatusPill(status.label, tone: status.tone)
            }

            if let identity = model.identity {
                VStack(alignment: .leading, spacing: SkipperSpace.xxs) {
                    SkipperFieldLabel("Device ID")
                    Text(identity.formattedDeviceID)
                        .font(SkipperFont.code)
                        .foregroundStyle(SkipperColor.textPrimary)
                        .textSelection(.enabled)
                }
            }

            if let request = model.consentRequest {
                ConsentPromptView(request: request, style: .menu)
            } else if model.sessionActive {
                SkipperNote("Remote session active")
            }

            SkipperDivider()

            accountRows

            SkipperDivider()

            VStack(spacing: SkipperSpace.xxs) {
                SkipperMenuAction(title: "Open SkipperDesk", symbol: "macwindow") {
                    NSApp.setActivationPolicy(.regular)
                    openWindow(id: WindowID.main)
                    NSApp.activate(ignoringOtherApps: true)
                }
                .keyboardShortcut("o")

                SkipperMenuAction(title: "Disconnect Session", symbol: "xmark.circle") {
                    model.endSession()
                }
                .disabled(!model.sessionActive)

                CheckForUpdatesMenuItem()

                SkipperMenuAction(title: "Quit SkipperDesk", symbol: "power") {
                    NSApp.terminate(nil)
                }
                .keyboardShortcut("q")
            }
        }
    }
}
