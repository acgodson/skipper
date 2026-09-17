import SwiftUI
import RemoteControlCore
import SkipperDesign

struct ContentView: View {

    @EnvironmentObject private var model: AppModel

    var body: some View {
        Group {
            if model.showsRemoteScreen {
                RemoteSessionView()
            } else if let error = model.identityError {
                IdentityFailureView(
                    message: error,
                    canReset: model.identityErrorIsResettable,
                    reset: { model.resetIdentity() }
                )
            } else {
                switch model.settings.role {
                case .host: HostView()
                case .controller: ControllerView()
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(model.showsRemoteScreen ? SkipperColor.stage : SkipperColor.canvas)
        .toolbar {
            ToolbarItem(placement: .principal) {
                if !model.showsRemoteScreen && model.identityError == nil {
                    RoleSwitch()
                }
            }
        }
    }
}

private struct RoleSwitch: View {

    @EnvironmentObject private var model: AppModel

    var body: some View {
        Picker("Role", selection: Binding(
            get: { model.settings.role },
            set: { model.settings.role = $0 }
        )) {
            ForEach(AppRole.allCases) { role in
                Text(role.displayName).tag(role)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .frame(width: 340)
        .help("Host shares this Mac. Controller drives another one.")
    }
}

struct IdentityFailureView: View {

    let message: String
    let canReset: Bool
    let reset: () -> Void

    @State private var confirmingReset = false

    var body: some View {
        SkipperScreen {
            SkipperBanner(
                tone: .critical,
                symbol: "exclamationmark.triangle.fill",
                title: "Device identity unavailable",
                message: "SkipperDesk could not read this Mac's identity, so it has no Device ID or access code. Nothing will connect until this is resolved. Your existing identity has not been changed or deleted."
            )

            SkipperCard(title: "What happened") {
                Text(message)
                    .font(SkipperFont.code)
                    .foregroundStyle(SkipperColor.textSecondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)

                if canReset {
                    SkipperDivider()
                    Button("Reset Identity\u{2026}") { confirmingReset = true }
                        .skipperButton(.destructive)
                        .confirmationDialog("Reset this Mac's identity?", isPresented: $confirmingReset) {
                            Button("Reset Identity", role: .destructive, action: reset)
                            Button("Cancel", role: .cancel) {}
                        } message: {
                            Text("This discards the damaged file and gives this Mac a brand-new Device ID and access code. Any Mac that saved the old Device ID or code will have to be given the new ones. This cannot be undone.")
                        }
                    SkipperNote("If the file might be recoverable, restore it from a Time Machine backup first \u{2014} resetting is not reversible.")
                }
            }
        }
    }
}
