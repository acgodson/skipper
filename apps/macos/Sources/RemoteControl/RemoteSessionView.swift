import SwiftUI
import RemoteControlCore
import SkipperDesign

struct RemoteSessionView: View {

    @EnvironmentObject private var model: AppModel
    @State private var videoSize: CGSize = .zero
    @State private var lastPointer: RemotePointerSample?
    @State private var paletteExpanded = false
    @State private var pointerNearTop = false
    @State private var hoveringToolbar = false
    @State private var revealed = true
    @State private var hideGeneration = 0
    @State private var localControlRegions: [CGRect] = []

    private static let revealBand: CGFloat = 56

    private var hasPicture: Bool { videoSize.width > 0 && videoSize.height > 0 }

    private var toolbarPinned: Bool {
        pointerNearTop || hoveringToolbar || !hasPicture || model.isReconnecting
    }

    var body: some View {
        ZStack(alignment: .top) {
            SkipperColor.stage

            if let coordinator = model.coordinator {
                RemoteScreenView(
                    session: coordinator,
                    capturingKeyboard: model.keyboardCaptureActive,
                    localControlRegions: LocalControlRegions(localControlRegions),
                    onVideoSizeChange: { videoSize = $0 },
                    onPointerSample: { sample, _ in
                        let moved = sample.viewPoint != lastPointer?.viewPoint
                        lastPointer = sample
                        let near = sample.viewPoint.y < Self.revealBand
                        if near != pointerNearTop { pointerNearTop = near }
                        if moved { showToolbar() }
                    })
            }

            if !hasPicture {
                StageOverlayCard(
                    title: "Connected \u{2014} waiting for video\u{2026}",
                    message: "The other Mac is starting its screen capture. If this does not clear within a few seconds, check that SkipperDesk has Screen Recording permission on that Mac \u{2014} macOS can revoke it after the app is updated."
                )
                .localControlRegion()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            if model.isReconnecting {
                StageOverlayCard(
                    title: "Reconnecting\u{2026}",
                    message: "The network wobbled. The session is still open and is recovering by itself."
                )
                .localControlRegion()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .transition(.opacity)
            }

            VStack {
                Spacer()
                HStack {
                    Spacer()
                    GesturePalette(isExpanded: $paletteExpanded)
                }
            }

            if model.keyboardCaptureActive {
                RoundedRectangle(cornerRadius: 2)
                    .strokeBorder(SkipperColor.accent, lineWidth: 3)
                    .allowsHitTesting(false)
            }

            SessionToolbar(videoSize: videoSize, pointer: lastPointer)
                .localControlRegion(revealed)
                .padding(.top, SkipperSpace.m)
                .onHover { hoveringToolbar = $0 }
                .opacity(revealed ? 1 : 0)
                .offset(y: revealed ? 0 : -SkipperSpace.xl)
                .allowsHitTesting(revealed)
                .animation(SkipperMotion.toolbarReveal, value: revealed)
        }
        .sessionStage { localControlRegions = $0 }
        .frame(minWidth: 640, minHeight: 420)
        .animation(SkipperMotion.standard, value: model.isReconnecting)
        .onChange(of: toolbarPinned) { pinned in
            if pinned { revealed = true } else { scheduleHide() }
        }
        .onAppear { scheduleHide() }
    }

    private func showToolbar() {
        if !revealed { revealed = true }
        scheduleHide()
    }

    private func scheduleHide() {
        hideGeneration += 1
        let generation = hideGeneration
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(SkipperMotion.toolbarHideDelaySeconds * 1_000_000_000))
            guard generation == hideGeneration, !toolbarPinned else { return }
            revealed = false
        }
    }
}

private struct SessionToolbar: View {

    @EnvironmentObject private var model: AppModel
    let videoSize: CGSize
    let pointer: RemotePointerSample?

    var body: some View {
        SessionToolbarBar {
            VStack(alignment: .leading, spacing: 0) {
                Text(model.otherMacLabel)
                    .font(SkipperFont.bodyEmphasis)
                    .foregroundStyle(SkipperColor.textPrimary)
                    .fixedSize()
                Text(statusLine)
                    .font(SkipperFont.caption)
                    .foregroundStyle(model.isReconnecting ? SkipperColor.attention : SkipperColor.textSecondary)
                    .fixedSize()
            }

            if RCLog.enabled {
                diagnostics
            }

            Rectangle()
                .fill(SkipperColor.border)
                .frame(width: 1, height: 20)

            KeyboardCaptureToggle()

            QualityMenu()

            SessionToolbarButton(
                title: "Disconnect",
                symbol: "xmark.circle",
                tone: .critical,
                help: "End the session (\u{2318}.)"
            ) {
                model.endSession()
            }
            .keyboardShortcut(".", modifiers: .command)
        }
    }

    @ViewBuilder
    private var diagnostics: some View {
        if let pointer {
            Text(String(format: "%.0f, %.0f", pointer.remotePixel.x, pointer.remotePixel.y))
                .font(SkipperFont.codeCaption)
                .foregroundStyle(pointer.insideVideo ? SkipperColor.textSecondary : SkipperColor.attention)
                .help("Pointer position on the remote display, in its own pixels.")
        }
        if let rtt = model.lastRoundTripMs {
            Text("\(rtt) ms")
                .font(SkipperFont.codeCaption)
                .foregroundStyle(SkipperColor.textSecondary)
        }
    }

    private var statusLine: String {
        if model.isReconnecting { return "Reconnecting\u{2026}" }
        guard RCLog.enabled else { return videoSize.width > 0 ? "Live" : "Connected" }
        if let display = model.coordinator?.remoteDisplay,
           WireBounds.accepts(display.scale, in: WireBounds.displayScale) {
            let whole = display.scale == rint(display.scale) ? WireBounds.int(display.scale) : nil
            let scale = whole.map(String.init) ?? String(format: "%.1f", display.scale)
            return "Live \u{2014} remote display \(display.w)\u{00D7}\(display.h) @\(scale)x"
        }
        if videoSize.width > 0 {
            return "Live \u{2014} \(Int(videoSize.width))\u{00D7}\(Int(videoSize.height))"
        }
        return "Connected"
    }
}

private struct QualityMenu: View {

    @EnvironmentObject private var model: AppModel

    var body: some View {
        Menu {
            Picker("Quality", selection: Binding(
                get: { model.settings.qualityMode },
                set: { model.settings.qualityMode = $0 }
            )) {
                ForEach(QualityMode.allCases) { mode in
                    Text(mode.displayName).tag(mode)
                        .disabled(!model.qualityModeAvailable(mode))
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
            if let note = model.qualityCeilingNote { Text(note) }
        } label: {
            Label(model.settings.qualityMode.displayName, systemImage: "slider.horizontal.3")
                .font(SkipperFont.caption.weight(.medium))
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Changes how sharply the other Mac sends its screen.")
    }
}

private struct KeyboardCaptureToggle: View {

    @EnvironmentObject private var model: AppModel

    var body: some View {
        SessionToolbarButton(
            title: "Send shortcuts to \(model.otherMacLabel)",
            symbol: "keyboard",
            isActive: model.keyboardCaptureActive,
            help: helpText
        ) {
            model.captureKeyboard.toggle()
        }
        .keyboardShortcut("k", modifiers: [.control, .option, .command])
    }

    private var helpText: String {
        if let problem = model.keyboardCaptureProblem { return problem }
        if model.keyboardCaptureActive {
            return "\u{2318}Space, \u{2318}Tab and other shortcuts go to the remote Mac. Press \u{2303}\u{2325}\u{2318}K to stop."
        }
        return "Send shortcuts like \u{2318}Space and \u{2318}Tab to \(model.otherMacLabel) instead of this Mac. \u{2303}\u{2325}\u{2318}K turns this on and off."
    }
}
