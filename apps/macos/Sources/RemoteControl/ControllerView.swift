import SwiftUI
import RemoteControlCore
import SkipperCore
import SkipperDesign

struct ControllerView: View {

    @EnvironmentObject private var model: AppModel

    @State private var deviceIDField = ""
    @State private var accessCodeField = ""
    @State private var labelField = ""
    @State private var remember = false

    private var canConnect: Bool {
        DeviceID.canonicalize(deviceIDField) != nil
            && AccessCode.canonicalize(accessCodeField) != nil
            && !model.isConnecting
    }

    var body: some View {
        SkipperScreen {
            connectCard

            if model.settings.hasSavedPeer {
                savedDevicesCard
            }

            SkipperCard(title: "Quality") {
                QualityPicker()
            }
        }
        .onAppear {
            if deviceIDField.isEmpty, model.settings.hasSavedPeer {
                useSavedPeer(syncRemember: true)
            }
        }
    }

    private var connectCard: some View {
        SkipperHero {
            VStack(alignment: .leading, spacing: SkipperSpace.xxs) {
                Text("Connect to a Mac")
                    .font(SkipperFont.title)
                    .foregroundStyle(SkipperColor.textPrimary)
                Text("Enter the Device ID and access code shown on the other Mac.")
                    .font(SkipperFont.caption)
                    .foregroundStyle(SkipperColor.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(alignment: .top, spacing: SkipperSpace.m) {
                SkipperTextField(
                    label: "Device ID",
                    placeholder: "482 719 351",
                    text: $deviceIDField,
                    monospaced: true
                )
                SkipperTextField(
                    label: "Access Code",
                    placeholder: "K7FM-3Q8P-W2XY",
                    text: $accessCodeField,
                    monospaced: true,
                    secure: true
                )
            }

            SkipperTextField(
                label: "Label (optional)",
                placeholder: "Studio Mac",
                text: $labelField
            )

            SkipperToggleRow(
                title: "Remember this code",
                detail: "Kept on this Mac only, so you are not asked again for this Mac.",
                isOn: $remember
            )

            SkipperDivider()

            HStack(spacing: SkipperSpace.m) {
                Button {
                    model.connect(
                        deviceID: deviceIDField,
                        accessCode: accessCodeField,
                        remember: remember,
                        label: labelField
                    )
                } label: {
                    Text("Connect").frame(minWidth: 88)
                }
                .skipperButton(.primary)
                .keyboardShortcut(.defaultAction)
                .disabled(!canConnect)

                if model.isConnecting {
                    ProgressView().controlSize(.small)
                }

                if model.sessionState.isActive {
                    Button("End Session") { model.endSession() }
                        .skipperButton(.secondary)
                }

                Spacer(minLength: SkipperSpace.s)

                if RCLog.enabled, let rtt = model.lastRoundTripMs, model.sessionState.isActive {
                    Text("\(rtt) ms")
                        .font(SkipperFont.codeCaption)
                        .foregroundStyle(SkipperColor.textTertiary)
                }

                StatusPill(sessionLabel, tone: sessionTone)
            }

            if model.isReconnecting {
                SkipperNote("The network wobbled. The session is still open and is recovering by itself \u{2014} you will not be asked for the access code again.")
            }

            if let error = model.connectError {
                SkipperBanner(
                    tone: .critical,
                    symbol: "exclamationmark.circle.fill",
                    title: error
                )
            }

            SkipperNote(model.signalingSummary)
        }
    }

    private var failedToConnect: Bool {
        model.connectError != nil && !model.sessionState.isActive && !model.isConnecting
    }

    private var sessionLabel: String {
        if model.isReconnecting { return "Reconnecting\u{2026}" }
        if failedToConnect { return "Not connected" }
        return model.sessionState.summary
    }

    private var sessionTone: SkipperTone {
        if model.isReconnecting { return .attention }
        if model.sessionState.isActive { return .accent }
        if model.isConnecting { return .attention }
        if failedToConnect { return .critical }
        return .neutral
    }

    private var savedDevicesCard: some View {
        SkipperCard(title: "Saved devices") {
            SkipperRow(
                title: model.settings.savedPeerLabel.isEmpty ? "Unnamed Mac" : model.settings.savedPeerLabel,
                subtitle: DeviceID.formatted(model.settings.savedPeerDeviceID),
                monospacedSubtitle: true
            ) {
                HStack(spacing: SkipperSpace.m) {
                    PresenceDot(tone: model.presence.state.tone, label: model.presence.state.label)
                    Button("Use") { useSavedPeer(syncRemember: false) }
                        .skipperButton(.secondary)
                    Button("Forget") {
                        model.forgetPeerCode(forHost: model.settings.savedPeerDeviceID)
                        model.settings.forgetPeer()
                        model.presence.stopWatching()
                    }
                    .skipperButton(.destructive)
                }
            }
            SkipperNote(model.presence.explanation)
        }
    }

    private func useSavedPeer(syncRemember: Bool) {
        deviceIDField = DeviceID.formatted(model.settings.savedPeerDeviceID)
        labelField = model.settings.savedPeerLabel
        if syncRemember { remember = model.settings.rememberPeerCode }
        if model.settings.rememberPeerCode {
            remember = true
            accessCodeField = AccessCode.formatted(
                model.rememberedPeerCode(forHost: model.settings.savedPeerDeviceID))
        }
    }
}
