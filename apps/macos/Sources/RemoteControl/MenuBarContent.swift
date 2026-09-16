import SwiftUI
import AppKit
import RemoteControlCore

struct MenuBarContent: View {

    @EnvironmentObject private var model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        if let identity = model.identity {
            Text("Device ID \(identity.formattedDeviceID)")
        }
        Text(model.sessionActive ? "Remote session active" : model.sessionState.summary)

        Divider()

        Button("Open RemoteControl") {
            NSApp.setActivationPolicy(.regular)
            openWindow(id: WindowID.main)
            NSApp.activate(ignoringOtherApps: true)
        }
        .keyboardShortcut("o")

        Button("Disconnect Session") {
            model.endSession()
        }
        .disabled(!model.sessionActive)

        Divider()

        Button("Quit RemoteControl") {
            NSApp.terminate(nil)
        }
        .keyboardShortcut("q")
    }
}
