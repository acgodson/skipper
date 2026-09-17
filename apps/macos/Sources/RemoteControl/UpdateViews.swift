import AppKit
import SwiftUI
import RemoteControlCore
import SkipperDesign

struct UpdateReadyBanner: View {

    @EnvironmentObject private var model: AppModel

    var body: some View {
        if let staged = model.updates.status.staged, let title = model.updates.status.sentence {
            SkipperBanner(
                tone: staged.critical ? .attention : .accent,
                symbol: "arrow.down.circle.fill",
                title: title,
                message: message(critical: staged.critical)
            ) {
                Button("Restart to Update") { model.restartToUpdate() }
                    .skipperButton(.primary)
                    .disabled(model.sessionActive)
            }
        } else if model.updates.status == .needsReinstall {
            SkipperBanner(
                tone: .attention,
                symbol: "exclamationmark.arrow.circlepath",
                title: UpdateStatus.reinstallSentence
            ) {
                Button("Open skipperdesk.app") {
                    NSWorkspace.shared.open(AccountLinker.defaultWebBaseURL())
                }
                .skipperButton(.secondary)
            }
        }
    }

    private func message(critical: Bool) -> String? {
        if model.sessionActive {
            return "You can restart once the remote session ends."
        }
        return critical ? "This update fixes a security problem. Restart when it is convenient." : nil
    }
}

struct AutomaticUpdatesRow: View {

    @EnvironmentObject private var model: AppModel

    var body: some View {
        SkipperToggleRow(
            title: "Install updates automatically",
            detail: model.updates.isEnabled
                ? "Installs when SkipperDesk quits, or between 3 and 5 a.m. while no one is connected."
                : UpdateAvailability.disabledSentence,
            isOn: Binding(
                get: { model.settings.installUpdatesAutomatically },
                set: { model.settings.installUpdatesAutomatically = $0 }
            )
        )
        .disabled(!model.updates.isEnabled)
    }
}

struct CheckForUpdatesMenuItem: View {

    @EnvironmentObject private var model: AppModel
    @State private var requested = false

    var body: some View {
        SkipperMenuAction(title: "Check for Updates\u{2026}", symbol: "arrow.triangle.2.circlepath") {
            requested = true
            model.checkForUpdates()
        }
        .disabled(model.updates.status == .checking)

        if let sentence = model.updates.status.sentence, requested || model.updates.status.staged != nil {
            SkipperNote(sentence)
        }
    }
}
