import SwiftUI
import RemoteControlCore
import SkipperCore

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
        VStack(alignment: .leading, spacing: 14) {

            if model.settings.hasSavedPeer {
                SectionCard(title: "Saved Mac") {
                    HStack(spacing: 10) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(model.settings.savedPeerLabel.isEmpty ? "Unlabelled Mac" : model.settings.savedPeerLabel)
                                .font(.body.weight(.medium))
                            Text(DeviceID.formatted(model.settings.savedPeerDeviceID))
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        PresenceDot(state: model.presence.state)
                    }
                    Text(model.presence.explanation)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    HStack {
                        Button("Use This Mac") {
                            deviceIDField = DeviceID.formatted(model.settings.savedPeerDeviceID)
                            labelField = model.settings.savedPeerLabel
                            if model.settings.rememberPeerCode {
                                accessCodeField = AccessCode.formatted(
                                    model.rememberedPeerCode(forHost: model.settings.savedPeerDeviceID))
                                remember = true
                            }
                        }
                        Button("Forget") {
                            model.forgetPeerCode(forHost: model.settings.savedPeerDeviceID)
                            model.settings.forgetPeer()
                            model.presence.stopWatching()
                        }
                    }
                }
            }

            SectionCard(title: "Connect To A Mac") {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Label (optional)").font(.caption).foregroundStyle(.secondary)
                    TextField("Studio Mac", text: $labelField)
                        .textFieldStyle(.roundedBorder)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("Device ID").font(.caption).foregroundStyle(.secondary)
                    TextField("482 719 351", text: $deviceIDField)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.body, design: .monospaced))
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("Access Code").font(.caption).foregroundStyle(.secondary)
                    SecureField("K7FM-3Q8P-W2XY", text: $accessCodeField)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.body, design: .monospaced))
                }

                Toggle("Remember this code", isOn: $remember)
                Text("Stored on this Mac only, in an owner-only file (0600) alongside the identity file.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)

                HStack {
                    Button("Connect") {
                        model.connect(
                            deviceID: deviceIDField,
                            accessCode: accessCodeField,
                            remember: remember,
                            label: labelField
                        )
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canConnect)

                    if model.isConnecting {
                        ProgressView().controlSize(.small)
                    }
                    Spacer()
                    Text(model.isReconnecting ? "Reconnecting\u{2026}" : model.sessionState.summary)
                        .font(.caption)
                        .foregroundStyle(model.isReconnecting ? .orange : .secondary)
                    if RCLog.enabled, let rtt = model.lastRoundTripMs, model.sessionState.isActive {
                        Text("\(rtt) ms")
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                }

                if model.isReconnecting {
                    Text("The network wobbled. The session is still open and is recovering by itself \u{2014} you will not be asked for the access code again.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Text(model.signalingSummary)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if model.sessionState.isActive {
                    Button("End Session") { model.endSession() }
                }

                if let error = model.connectError {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
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
        }
        .onAppear {
            if deviceIDField.isEmpty, model.settings.hasSavedPeer {
                deviceIDField = DeviceID.formatted(model.settings.savedPeerDeviceID)
                labelField = model.settings.savedPeerLabel
                remember = model.settings.rememberPeerCode
                if remember {
                    accessCodeField = AccessCode.formatted(
                        model.rememberedPeerCode(forHost: model.settings.savedPeerDeviceID))
                }
            }
        }
    }
}
