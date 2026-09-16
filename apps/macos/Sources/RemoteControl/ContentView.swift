import SwiftUI
import RemoteControlCore

struct ContentView: View {

    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            if model.showsRemoteScreen {
                // A live controller session takes the whole window. The connect
                // form is not "behind" it — it is not the right screen any more.
                RemoteSessionView()
            } else if let error = model.identityError {
                IdentityFailureView(
                    message: error,
                    canReset: model.identityErrorIsResettable,
                    reset: { model.resetIdentity() }
                )
            } else {
                Picker("", selection: Binding(
                    get: { model.settings.role },
                    set: { model.settings.role = $0 }
                )) {
                    ForEach(AppRole.allCases) { role in
                        Text(role.displayName).tag(role)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .padding(12)

                Divider()

                ScrollView {
                    Group {
                        switch model.settings.role {
                        case .host: HostView()
                        case .controller: ControllerView()
                        }
                    }
                    .padding(16)
                    // Cap and centre the forms. The window is landscape so the
                    // remote desktop is not squeezed into a strip, but a text
                    // field stretched to 1000pt is unreadable and looks broken.
                    .frame(maxWidth: 620)
                    .frame(maxWidth: .infinity)
                }
            }
        }
    }
}

/// Shown when the identity file cannot be read. We do not carry on with a
/// half-initialised identity, and we deliberately do NOT quietly mint a new one:
/// that would change this Mac's Device ID and access code behind the user's
/// back, and the peer Mac's saved entry would simply stop working.
struct IdentityFailureView: View {
    let message: String
    let canReset: Bool
    let reset: () -> Void

    @State private var confirmingReset = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Device identity unavailable", systemImage: "exclamationmark.triangle.fill")
                .font(.headline)
                .foregroundStyle(.orange)
            Text("RemoteControl could not read its identity file, so it has no Device ID or access code. Nothing will connect until this is resolved. Your existing identity has not been changed or deleted.")
                .font(.callout)
            Text(message)
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if canReset {
                Button("Reset Identity\u{2026}", role: .destructive) { confirmingReset = true }
                    .confirmationDialog("Reset this Mac's identity?", isPresented: $confirmingReset) {
                        Button("Reset Identity", role: .destructive, action: reset)
                        Button("Cancel", role: .cancel) {}
                    } message: {
                        Text("This discards the damaged file and generates a brand-new Device ID, access code and device key. Any Mac that saved the old Device ID or code will have to be given the new ones. This cannot be undone.")
                    }
                Text("If the file might be recoverable, restore it from a Time Machine backup first \u{2014} resetting is not reversible.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(20)
    }
}

// MARK: - Shared building blocks

struct SectionCard<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title.uppercased())
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color(nsColor: .separatorColor))
        )
    }
}

struct PresenceDot: View {
    let state: PresenceState

    private var color: Color {
        switch state {
        case .online: return .green
        case .offline: return .secondary
        case .unknown: return .orange
        }
    }

    var body: some View {
        HStack(spacing: 5) {
            Text(state.indicator).foregroundStyle(color)
            Text(state.label)
        }
        .font(.callout)
    }
}
