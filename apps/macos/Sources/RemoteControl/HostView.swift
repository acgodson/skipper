import SwiftUI
import AppKit
import RemoteControlCore

struct HostView: View {

    @EnvironmentObject private var model: AppModel
    @State private var codeVisible = false
    @State private var confirmingRefresh = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {

            if model.sessionActive && model.coordinator?.canInjectInput == false {
                InputBlockedBanner()
            }
            if model.sessionActive {
                SessionActiveBanner()
            }

            if let identity = model.identity {
                SectionCard(title: "Remote Access") {
                    LabeledContent {
                        Text(identity.formattedDeviceID)
                            .font(.system(.title3, design: .monospaced))
                            .textSelection(.enabled)
                    } label: {
                        Text("Device ID")
                    }

                    Divider()

                    LabeledContent {
                        HStack(spacing: 8) {
                            if codeVisible {
                                Text(identity.formattedAccessCode)
                                    .font(.system(.title3, design: .monospaced))
                                    .textSelection(.enabled)
                            } else {
                                Text("\u{2022}\u{2022}\u{2022}\u{2022}-\u{2022}\u{2022}\u{2022}\u{2022}-\u{2022}\u{2022}\u{2022}\u{2022}")
                                    .font(.system(.title3, design: .monospaced))
                            }
                            Button {
                                codeVisible.toggle()
                            } label: {
                                Image(systemName: codeVisible ? "eye.slash" : "eye")
                            }
                            .buttonStyle(.borderless)
                            .help(codeVisible ? "Hide access code" : "Show access code")
                        }
                    } label: {
                        Text("Access Code")
                    }

                    HStack {
                        Button("Refresh Access Code\u{2026}") { confirmingRefresh = true }
                        Spacer()
                        PresenceDot(state: model.selfPresence.state)
                    }
                    Text(model.selfPresence.explanation)
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    if let refreshError = identity.lastRefreshError {
                        Text(refreshError)
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }
                .confirmationDialog(
                    "Refresh the access code?",
                    isPresented: $confirmingRefresh
                ) {
                    Button("Refresh Access Code", role: .destructive) {
                        model.refreshAccessCode()
                        codeVisible = true
                    }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("The current code stops working immediately. Any Mac that has saved it will have to be given the new code before it can connect again.")
                }
            }

            SectionCard(title: "Access") {
                Toggle("Unattended Access", isOn: Binding(
                    get: { model.settings.unattendedAccess },
                    set: { model.settings.unattendedAccess = $0 }
                ))
                Text("Allows a controller with the correct code to connect while nobody is at this Mac.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Divider()

                Toggle("Clipboard Sync", isOn: Binding(
                    get: { model.settings.clipboardSync },
                    set: { model.settings.clipboardSync = $0 }
                ))
                Text("Text only, both directions, while a session is open.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            ScreenSharingSection()

            PermissionsSection()

            SectionCard(title: "Startup") {
                Toggle("Launch at Login", isOn: Binding(
                    get: { model.launchAtLogin.isEnabled },
                    set: { model.launchAtLogin.set($0) }
                ))
                .disabled(!model.launchAtLogin.isAvailable)
                Text(model.launchAtLogin.statusDescription)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let error = model.launchAtLogin.lastError {
                    Text(error).font(.caption).foregroundStyle(.orange)
                }
            }

            SectionCard(title: "Quality") {
                Picker("Remote Desktop Quality", selection: Binding(
                    get: { model.settings.qualityMode },
                    set: { model.settings.qualityMode = $0 }
                )) {
                    ForEach(QualityMode.allCases) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                .pickerStyle(.radioGroup)
                Text(model.settings.qualityMode.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            DeviceKeyFooter()

            #if DEBUG
            SectionCard(title: "Preview only (debug builds)") {
                Toggle("Show the \u{201C}Remote session active\u{201D} banner", isOn: $model.previewSessionBanner)
                Text("Renders the banner state. There is no real session \u{2014} the transport is a stub until Phase 3.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            #endif
        }
    }
}

/// AGENT.md: during a session the host must visibly indicate it. Not covert.
struct SessionActiveBanner: View {

    @EnvironmentObject private var model: AppModel

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "dot.radiowaves.left.and.right")
            VStack(alignment: .leading, spacing: 2) {
                Text(model.isReconnecting ? "Reconnecting\u{2026}" : "Remote session active")
                    .font(.headline)
                // "Reconnecting" is a different statement from "Disconnected":
                // the session is still alive and will resume by itself.
                Text(model.isReconnecting
                     ? "The connection wobbled. The session is still open and is recovering \u{2014} no one has to re-enter the access code."
                     : "Someone is viewing and controlling this Mac.")
                    .font(.caption)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Button("End Session") { model.endSession() }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.accentColor.opacity(0.18))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color.accentColor)
        )
    }
}

/// The specific, named failure PLAN.md 5 warns about: a live session in which
/// the far end can see this screen and click on it to no effect whatsoever.
///
/// It is its own banner rather than a row in `PermissionsSection` because it
/// only appears when it is ACTUALLY happening — a session is live and the
/// window server is discarding the events we post — and at that moment the
/// generic "Accessibility: not granted" row is far too quiet.
struct InputBlockedBanner: View {

    @EnvironmentObject private var model: AppModel

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text("Remote input is being ignored")
                    .font(.headline)
                Text("The other Mac can see this screen but cannot click or type on it: RemoteControl does not have Accessibility permission, so macOS discards every event it posts.")
                    .font(.caption)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Button("Open Settings") {
                model.permissions.openSettings(for: .accessibility)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.orange.opacity(0.18)))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color.orange))
    }
}

/// States plainly where the identity lives and what protects it.
///
/// Deliberately understated: this is POSIX file permissions plus FileVault at
/// rest. It is NOT hardware-backed and NOT the Secure Enclave (which needs a
/// paid Apple Developer account and a provisioning profile this build does not
/// have), so the wording must not imply either. It gets a real SectionCard
/// rather than faint footer text because a claim about where the user's private
/// key lives should be readable.
/// Surfaces a problem with the identity file, and NOTHING when there isn't one.
///
/// This used to be an "Identity Storage" card showing the file path, the key
/// type and a public-key prefix. That is implementation detail: the user cannot
/// act on it, it is the same on every launch, and it pushed the controls that
/// matter further down the window. The facts still live in PLAN.md and the file
/// is still exactly where it was — the UI simply stops narrating it.
struct DeviceKeyFooter: View {

    @EnvironmentObject private var model: AppModel

    var body: some View {
        if let warning = model.identity?.permissionWarning {
            SectionCard(title: "Identity File") {
                Label(warning, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}


/// What the capture pipeline is actually doing on this Mac.
///
/// Distinct from the Screen Recording row in `PermissionsSection`, which reports
/// what TCC *says*. This reports what happened when we last tried to capture —
/// and those two can disagree. TCC binds the grant to the code signature, and an
/// ad-hoc signed build gets a new signature on every rebuild, so a grant that
/// System Settings still lists can fail at `SCStream.startCapture`. When that
/// happens the controller must not just see a black screen: it is stated here,
/// with the deep link, and the host retries by itself once the grant is back.
struct ScreenSharingSection: View {

    @EnvironmentObject private var model: AppModel

    private var state: CaptureState { model.coordinator?.captureState ?? .idle }

    var body: some View {
        SectionCard(title: "Screen Sharing") {
            switch state {
            case .idle:
                Label("Idle \u{2014} capture starts when a controller connects.",
                      systemImage: "pause.circle")
                    .font(.callout)
                    .foregroundStyle(.secondary)

            case .starting:
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Starting screen capture\u{2026}").font(.callout)
                }

            case .running(let width, let height, let fps):
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Sharing this Mac's screen").font(.callout.weight(.medium))
                        // Numbers that move on their own are diagnostics, not product
                        // UI: a fluctuating resolution/fps readout reads as instability
                        // to someone who cannot act on it. State here; figures under
                        // RC_DEBUG=1 when we actually need them.
                        if RCLog.enabled {
                            Text("\(width)\u{00D7}\(height), up to \(fps) fps. The frame rate drops automatically while the screen is still.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                } icon: {
                    Image(systemName: "record.circle").foregroundStyle(.green)
                }

            case .failed(let failure):
                VStack(alignment: .leading, spacing: 8) {
                    Label(failure.localizedDescription, systemImage: "exclamationmark.triangle.fill")
                        .font(.callout)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                    if failure.isPermissionProblem {
                        HStack(spacing: 8) {
                            Button("Open Screen Recording Settings\u{2026}") {
                                model.permissions.openSettings(for: .screenRecording)
                            }
                            Button("Request\u{2026}") {
                                model.permissions.request(.screenRecording)
                            }
                        }
                        Text("macOS ties this permission to the app's code signature, so updating RemoteControl can revoke it even though System Settings still lists the app. Turn it off and on again there if it looks granted. Sharing resumes on its own within a few seconds of the grant returning \u{2014} no need to reconnect.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }
}
