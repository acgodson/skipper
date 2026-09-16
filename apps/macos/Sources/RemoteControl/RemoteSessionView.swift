import SwiftUI
import RemoteControlCore

/// The controller's session screen: the remote desktop, full window.
///
/// This replaces the connect form entirely while a session is live. Before
/// Phase 4 the app stayed on the settings form after connecting, which read as
/// "nothing happened" — the single most confusing thing about the app. A live
/// session now looks like a live session, and the way back is one button.
struct RemoteSessionView: View {

    @EnvironmentObject private var model: AppModel
    @State private var videoSize: CGSize = .zero
    @State private var lastPointer: RemotePointerSample?
    @State private var paletteExpanded = false

    private var hasPicture: Bool { videoSize.width > 0 && videoSize.height > 0 }

    var body: some View {
        VStack(spacing: 0) {
            SessionToolbar(videoSize: videoSize, pointer: lastPointer)
            Divider()
            ZStack {
                Color.black
                if let coordinator = model.coordinator {
                    RemoteScreenView(
                        session: coordinator,
                        capturingKeyboard: model.keyboardCaptureActive,
                        onVideoSizeChange: { videoSize = $0 },
                        // These samples are already in the remote display's
                        // coordinate space. The view hands the full event
                        // straight to the input sender; this copy only drives
                        // the toolbar read-out.
                        onPointerSample: { sample, _ in lastPointer = sample })
                }
                if !hasPicture {
                    WaitingForVideoOverlay()
                }
                if model.isReconnecting {
                    ReconnectingOverlay(overPicture: hasPicture)
                }

                // The floating palette sits over the picture, bottom-right, out
                // of the way of a menu bar or a Dock on the remote screen.
                VStack {
                    Spacer()
                    HStack {
                        Spacer()
                        GesturePalette(isExpanded: $paletteExpanded)
                    }
                }

                // Where are my keystrokes going? This is the whole answer, and
                // it is drawn ON the picture rather than tucked into a toolbar,
                // because being wrong about it is genuinely disorienting.
                if model.keyboardCaptureActive {
                    RoundedRectangle(cornerRadius: 2)
                        .strokeBorder(Color.accentColor, lineWidth: 3)
                        .allowsHitTesting(false)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 640, minHeight: 420)
        .background(Color.black)
    }
}

private struct SessionToolbar: View {

    @EnvironmentObject private var model: AppModel
    let videoSize: CGSize
    let pointer: RemotePointerSample?

    private var title: String {
        let label = model.settings.savedPeerLabel
        if !label.isEmpty { return label }
        let id = model.settings.savedPeerDeviceID
        return id.isEmpty ? "Remote Mac" : DeviceID.formatted(id)
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "display")
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.body.weight(.medium))
                Text(statusLine)
                    .font(.caption2)
                    .foregroundStyle(model.isReconnecting ? Color.orange : Color.secondary)
            }

            Spacer()

            if let pointer {
                // Live proof that view→remote conversion is running, and the
                // readout Phase 5 will debug against.
                Text(String(format: "%.0f, %.0f", pointer.remotePixel.x, pointer.remotePixel.y))
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(pointer.insideVideo ? Color.secondary : Color.orange)
                    .help("Pointer position on the remote display, in its own pixels.")
            }

            if let rtt = model.lastRoundTripMs {
                Text("\(rtt) ms")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
            }

            Picker("Quality", selection: Binding(
                get: { model.settings.qualityMode },
                set: { model.settings.qualityMode = $0 }
            )) {
                ForEach(QualityMode.allCases) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .frame(width: 150)
            .help("Sent to the other Mac, which changes what it encodes.")

            KeyboardCaptureToggle()

            Button("Disconnect") { model.endSession() }
                .keyboardShortcut(".", modifiers: .command)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
    }

    private var statusLine: String {
        if model.isReconnecting { return "Reconnecting\u{2026} the session is still open" }
        if let display = model.coordinator?.remoteDisplay {
            let scale = display.scale == rint(display.scale) ? String(Int(display.scale)) : String(format: "%.1f", display.scale)
            return "Live \u{2014} remote display \(display.w)\u{00D7}\(display.h) @\(scale)x"
        }
        if videoSize.width > 0 {
            return "Live \u{2014} \(Int(videoSize.width))\u{00D7}\(Int(videoSize.height))"
        }
        return "Connected"
    }
}

/// PLAN.md 2.4: the toggle that decides whether Cmd+Space opens the local or
/// the remote Spotlight. Its state has to be unmistakable — the user must never
/// be unsure where their typing is going — so it is a filled, tinted control
/// when on, and the video gets a matching accent border.
private struct KeyboardCaptureToggle: View {

    @EnvironmentObject private var model: AppModel

    var body: some View {
        Button {
            model.captureKeyboard.toggle()
        } label: {
            HStack(spacing: 5) {
                Image(systemName: model.keyboardCaptureActive ? "keyboard.fill" : "keyboard")
                Text(model.keyboardCaptureActive ? "Keys \u{2192} Remote" : "Keys \u{2192} This Mac")
                    .font(.caption.weight(.medium))
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(model.keyboardCaptureActive ? Color.accentColor : Color.secondary.opacity(0.18)))
            .foregroundStyle(model.keyboardCaptureActive ? Color.white : Color.primary)
        }
        .buttonStyle(.plain)
        .help(helpText)
    }

    private var helpText: String {
        if let problem = model.keyboardCaptureProblem { return problem }
        if model.keyboardCaptureActive {
            return "Every keystroke goes to the other Mac, including Cmd-Space and Cmd-Tab. Press "
                + KeyboardCaptureTap.escapeHatchDescription
                + " to turn this off — that combination is never forwarded."
        }
        return "Keystrokes stay on this Mac. Turn this on to send them to the other Mac instead, so Cmd-Space opens its Spotlight rather than yours."
    }
}

/// A black window with no explanation is indistinguishable from a crash. This
/// states what is happening and what the likely cause is if it persists.
private struct WaitingForVideoOverlay: View {
    var body: some View {
        VStack(spacing: 10) {
            ProgressView().controlSize(.small)
            Text("Connected \u{2014} waiting for video\u{2026}")
                .font(.headline)
                .foregroundStyle(.white)
            Text("The other Mac is starting its screen capture. If this does not clear within a few seconds, check that RemoteControl has Screen Recording permission on that Mac \u{2014} macOS can revoke it after the app is updated.")
                .font(.caption)
                .foregroundStyle(.white.opacity(0.7))
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(24)
    }
}

/// PLAN.md §2.1: over the last frame, never instead of it.
private struct ReconnectingOverlay: View {
    let overPicture: Bool

    var body: some View {
        VStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text("Reconnecting\u{2026}").font(.headline).foregroundStyle(.white)
            Text("The network wobbled. The session is still open and is recovering by itself.")
                .font(.caption)
                .foregroundStyle(.white.opacity(0.8))
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
        }
        .padding(20)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.black.opacity(overPicture ? 0.65 : 0.0))
        )
    }
}
