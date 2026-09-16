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

            AccountSection()

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

/// This Mac's link to a SkipperDesk account (protocol/API.md §1).
///
/// Host only: a controller connects with a Device ID and an access code and
/// never signs in (docs/SCOPE.md §3.1). Four states, one screen each, and no
/// number that moves on its own — what the server says about the entitlement is
/// rendered, never computed here (API.md §4.2).
struct AccountSection: View {

    @EnvironmentObject private var model: AppModel
    @State private var confirmingUnlink = false

    var body: some View {
        SectionCard(title: "Account") {
            switch model.account?.state ?? .unlinked {

            case .unlinked:
                Button("Link this Mac") { model.linkAccount() }
                Text("Hosting needs an account. This opens your browser to sign in; SkipperDesk never sees your password.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

            case .linking:
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Finish signing in in your browser").font(.callout)
                    Spacer()
                    Button("Cancel") { model.cancelAccountLink() }
                }

            case .linked(let accountLabel, let device):
                LabeledContent {
                    Text(accountLabel ?? "Signed in").textSelection(.enabled)
                } label: {
                    Text("Account")
                }
                LabeledContent {
                    Text(device.label.isEmpty ? DeviceID.formatted(device.deviceId) : device.label)
                        .textSelection(.enabled)
                } label: {
                    Text("This Mac")
                }
                if let entitlement = model.account?.entitlement?.value {
                    LabeledContent {
                        Text(entitlement.status.rawValue.capitalized)
                    } label: {
                        Text("Plan")
                    }
                }
                HStack {
                    Spacer()
                    Button("Unlink\u{2026}", role: .destructive) { confirmingUnlink = true }
                }
                .confirmationDialog("Unlink this Mac?", isPresented: $confirmingUnlink) {
                    Button("Unlink", role: .destructive) { model.unlinkAccount() }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("This Mac stops being able to host sessions until it is linked again. Its Device ID and access code do not change.")
                }

            case .error(let message):
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    Button("Try Again") { model.retryAccount() }
                    Button("Link this Mac") { model.linkAccount() }
                }
            }
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

/// Says where this Mac's private key is kept, and nothing more.
///
/// One line, three possible values, no path and no jargon. It matters because
/// the three are genuinely different promises — the Secure Enclave never lets
/// the key leave the chip, the Keychain encrypts it at rest, a file is
/// permissions only — and because the wording must never claim the strongest
/// one when the build fell back to a weaker one.
///
/// Still surfaces a problem with the identity file when there is one.
struct DeviceKeyFooter: View {

    @EnvironmentObject private var model: AppModel

    var body: some View {
        if let identity = model.identity {
            VStack(alignment: .leading, spacing: 6) {
                Text("Key: \(identity.keyStorageLabel)")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if let note = identity.keyStorageNote {
                    Text(note)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if let warning = identity.permissionWarning {
                    Label(warning, systemImage: "exclamationmark.triangle.fill")
                        .font(.callout)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
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
