import SwiftUI
import AppKit
import RemoteControlCore
import SkipperDesign

struct HostView: View {

    @EnvironmentObject private var model: AppModel

    var body: some View {
        SkipperScreen {
            if model.sessionActive && model.coordinator?.canInjectInput == false {
                InputBlockedBanner()
            }
            if model.sessionActive {
                SessionActiveBanner()
            }

            UpdateReadyBanner()

            PermissionsBanners()

            if model.identity != nil {
                HostHero()
            }

            AccountSection()

            AccessSection()

            ScreenSharingSection()

            TrustedControllersSection()

            QualitySection()

            DeviceKeyFooter()
        }
    }
}

private struct HostHero: View {

    @EnvironmentObject private var model: AppModel
    @State private var codeVisible = false
    @State private var confirmingRefresh = false

    var body: some View {
        if let identity = model.identity {
            SkipperHero {
                HStack(alignment: .firstTextBaseline, spacing: SkipperSpace.m) {
                    VStack(alignment: .leading, spacing: SkipperSpace.xxs) {
                        Text("This Mac")
                            .font(SkipperFont.title)
                            .foregroundStyle(SkipperColor.textPrimary)
                        Text("Give these two to the Mac that will control this one.")
                            .font(SkipperFont.caption)
                            .foregroundStyle(SkipperColor.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: SkipperSpace.s)
                    StatusPill(model.connectionStatus.label, tone: model.connectionStatus.tone)
                }

                CodeDisplay(label: "Device ID", value: identity.formattedDeviceID)

                SkipperDivider()

                CodeDisplay(
                    label: "Access Code",
                    value: identity.formattedAccessCode,
                    maskedValue: revealed ? nil : "\u{2022}\u{2022}\u{2022}\u{2022}-\u{2022}\u{2022}\u{2022}\u{2022}-\u{2022}\u{2022}\u{2022}\u{2022}",
                    copyValue: identity.formattedAccessCode,
                    copyDisabled: sessionOpen,
                    copyAction: { ConcealedPasteboard.write($0) }
                ) {
                    SkipperIconButton(
                        symbol: revealed ? "eye.slash" : "eye",
                        help: revealed ? "Hide access code" : "Show access code"
                    ) {
                        withAnimation(SkipperMotion.quick) { codeVisible.toggle() }
                    }
                    .disabled(sessionOpen)
                    .opacity(sessionOpen ? 0.4 : 1)
                    SkipperIconButton(symbol: "arrow.clockwise", help: "Refresh the access code") {
                        confirmingRefresh = true
                    }
                }

                if sessionOpen {
                    SkipperNote(AccessCodeExposure.hiddenWhileSessionOpen)
                }

                SkipperNote(model.selfPresence.explanation)

                if !model.settings.unattendedAccess {
                    SkipperNote("Leaving this Mac on its own? Turn on Unattended access below so connections do not wait for someone to click Allow.")
                }

                if let refreshError = identity.lastRefreshError {
                    SkipperNote(refreshError, tone: .attention)
                }
            }
            .confirmationDialog("Refresh the access code?", isPresented: $confirmingRefresh) {
                Button("Refresh Access Code", role: .destructive) {
                    codeVisible = false
                    model.refreshAccessCode()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Any open session ends first. The current code stops working immediately, and every controller this Mac already trusts is forgotten. Any Mac that saved the old code will have to be given the new one before it can connect again.")
            }
            .onChange(of: sessionOpen) { open in
                if open { codeVisible = false }
            }
            .onChange(of: signedIn) { signedIn in
                if !signedIn { codeVisible = false }
            }
        }
    }

    private var sessionOpen: Bool { model.hostSessionIsOpen }

    private var signedIn: Bool { model.account?.state.isLinked ?? false }

    private var revealed: Bool { codeVisible && !sessionOpen }
}

private struct AccessSection: View {

    @EnvironmentObject private var model: AppModel

    var body: some View {
        SkipperCard(title: "Access") {
            SkipperToggleRow(
                title: "Unattended access",
                detail: model.settings.unattendedAccess
                    ? "Anyone with the code can connect without being asked here."
                    : "You will be asked to allow each connection.",
                isOn: Binding(
                    get: { model.settings.unattendedAccess },
                    set: { model.settings.unattendedAccess = $0 }
                )
            )

            SkipperDivider()

            SkipperToggleRow(
                title: "Clipboard sync",
                detail: "Text only, both directions, while a session is open.",
                isOn: Binding(
                    get: { model.settings.clipboardSync },
                    set: { model.settings.clipboardSync = $0 }
                )
            )

            SkipperDivider()

            SkipperToggleRow(
                title: "Launch at login",
                detail: model.launchAtLogin.statusDescription,
                isOn: Binding(
                    get: { model.launchAtLogin.isEnabled },
                    set: { model.launchAtLogin.set($0) }
                )
            )
            .disabled(!model.launchAtLogin.isAvailable)

            if let error = model.launchAtLogin.lastError {
                SkipperNote(error, tone: .attention)
            }

            SkipperDivider()

            AutomaticUpdatesRow()
        }
    }
}

private struct QualitySection: View {

    @EnvironmentObject private var model: AppModel

    var body: some View {
        SkipperCard(title: "Quality") {
            QualityPicker()
        }
    }
}

struct QualityPicker: View {

    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: SkipperSpace.s) {
            Picker("Remote desktop quality", selection: Binding(
                get: { model.settings.qualityMode },
                set: { model.settings.qualityMode = $0 }
            )) {
                ForEach(QualityMode.allCases) { mode in
                    Text(mode.displayName).tag(mode)
                        .disabled(!model.qualityModeAvailable(mode))
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            SkipperNote(model.settings.qualityMode.detail)
            if let note = model.qualityCeilingNote { SkipperNote(note) }
        }
    }
}

private struct TrustedControllersSection: View {

    @EnvironmentObject private var model: AppModel
    @State private var confirmingRevoke = false

    var body: some View {
        SkipperCard(title: "Trusted controllers") {
            if model.trustedControllers.isEmpty {
                SkipperNote("No Mac has proved this Mac's access code yet. A controller that does is remembered here, and can reconnect without the code until you refresh it.")
            } else {
                ForEach(Array(model.trustedControllers.enumerated()), id: \.element.id) { index, entry in
                    if index > 0 { SkipperDivider() }
                    SkipperRow(
                        title: entry.displayName,
                        subtitle: entry.lastSeenSentence(),
                        monospacedSubtitle: false
                    ) {
                        QuietDestructiveButton(title: "Remove") {
                            model.removeTrustedController(pubkey: entry.pubkey)
                        }
                        .help("Forgets this Mac. It has to enter this Mac's access code again before it can connect.")
                    }
                    SkipperDetails(lines: entry.detailLines)
                }
                SkipperDivider()
                HStack {
                    Spacer()
                    Button("Remove All\u{2026}") { confirmingRevoke = true }
                        .skipperButton(.destructive)
                }
                .confirmationDialog("Forget every trusted controller?", isPresented: $confirmingRevoke) {
                    Button("Remove All", role: .destructive) { model.revokeTrustedControllers() }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("Each of them has to enter this Mac's access code again before it can connect. The code itself does not change.")
                }
            }
        }
    }
}

private struct QuietDestructiveButton: View {

    let title: String
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(SkipperFont.caption.weight(.medium))
                .foregroundStyle(SkipperColor.critical)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .opacity(hovering ? 0.7 : 1)
    }
}

private struct PermissionsBanners: View {

    @EnvironmentObject private var model: AppModel

    var body: some View {
        ForEach(model.missingPermissions) { kind in
            SkipperBanner(
                tone: .attention,
                symbol: "exclamationmark.triangle.fill",
                title: "\(kind.title) is off",
                message: kind.consequenceWhenMissing
            ) {
                PermissionActions(kind: kind)
            }
        }
    }
}

private struct PermissionActions: View {

    @EnvironmentObject private var model: AppModel
    let kind: PermissionKind

    var body: some View {
        VStack(alignment: .trailing, spacing: SkipperSpace.xs) {
            Button("Open Settings") { model.permissions.openSettings(for: kind) }
                .skipperButton(.primary)
            Button("Ask macOS") { model.permissions.request(kind) }
                .skipperButton(.quiet)
                .help("Asks macOS to show its own permission dialog.")
        }
    }
}

struct SessionActiveBanner: View {

    @EnvironmentObject private var model: AppModel

    var body: some View {
        SkipperBanner(
            tone: model.isReconnecting ? .attention : .accent,
            symbol: "dot.radiowaves.left.and.right",
            title: model.isReconnecting ? "Reconnecting\u{2026}" : "Remote session active",
            message: model.isReconnecting
                ? "The connection wobbled. The session is still open and is recovering \u{2014} no one has to re-enter the access code."
                : "Someone is viewing and controlling this Mac."
        ) {
            Button("End Session") { model.endSession() }
                .skipperButton(.secondary)
        }
    }
}

struct InputBlockedBanner: View {

    @EnvironmentObject private var model: AppModel

    var body: some View {
        SkipperBanner(
            tone: .critical,
            symbol: "hand.raised.fill",
            title: "Remote input is being ignored",
            message: "The other Mac can see this screen but cannot click or type on it: SkipperDesk does not have Accessibility permission, so macOS discards every event it posts."
        ) {
            Button("Open Settings") { model.permissions.openSettings(for: .accessibility) }
                .skipperButton(.primary)
        }
    }
}

struct DeviceKeyFooter: View {

    @EnvironmentObject private var model: AppModel

    var body: some View {
        if let identity = model.identity {
            let protection = identity.keyProtection
            VStack(alignment: .leading, spacing: SkipperSpace.xs) {
                if let sentence = protection.sentence {
                    HStack(spacing: SkipperSpace.s) {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.system(size: 10))
                            .foregroundStyle(SkipperColor.attention)
                        Text(sentence)
                            .font(SkipperFont.caption)
                            .foregroundStyle(SkipperColor.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                SkipperDetails(lines: protection.details)

                if let warning = identity.permissionWarning {
                    SkipperNote(warning, tone: .attention)
                }
            }
            .padding(.horizontal, SkipperSpace.xs)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct ScreenSharingSection: View {

    @EnvironmentObject private var model: AppModel

    private var state: CaptureState { model.coordinator?.captureState ?? .idle }

    var body: some View {
        SkipperCard(title: "Screen sharing") {
            switch state {
            case .idle:
                HStack(spacing: SkipperSpace.s) {
                    StatusPill("Idle", tone: .neutral)
                    Text("Capture starts when a controller connects.")
                        .font(SkipperFont.body)
                        .foregroundStyle(SkipperColor.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

            case .starting:
                HStack(spacing: SkipperSpace.s) {
                    ProgressView().controlSize(.small)
                    Text("Starting screen capture\u{2026}")
                        .font(SkipperFont.body)
                        .foregroundStyle(SkipperColor.textPrimary)
                }

            case .running(let width, let height, let fps):
                VStack(alignment: .leading, spacing: SkipperSpace.s) {
                    HStack(spacing: SkipperSpace.s) {
                        StatusPill("Sharing", tone: .positive)
                        Text("This Mac's screen is being shared.")
                            .font(SkipperFont.body)
                            .foregroundStyle(SkipperColor.textPrimary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if RCLog.enabled {
                        SkipperNote("\(width)\u{00D7}\(height), up to \(fps) fps. The frame rate drops automatically while the screen is still.")
                    }
                }

            case .failed(let failure):
                VStack(alignment: .leading, spacing: SkipperSpace.s) {
                    SkipperBanner(
                        tone: .critical,
                        symbol: "exclamationmark.triangle.fill",
                        title: "Screen sharing stopped",
                        message: failure.localizedDescription
                    ) {
                        if failure.isPermissionProblem {
                            PermissionActions(kind: .screenRecording)
                        }
                    }
                    if failure.isPermissionProblem {
                        SkipperNote("macOS ties this permission to the app's code signature, so updating SkipperDesk can revoke it even though System Settings still lists the app. Turn it off and on again there if it looks granted. Sharing resumes on its own within a few seconds of the grant returning \u{2014} no need to reconnect.")
                    }
                }
            }
        }
    }
}
