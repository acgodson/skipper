import SwiftUI
import AppKit
import UserNotifications
import RemoteControlCore
import SkipperDesign

struct ConsentPromptView: View {

    @EnvironmentObject private var model: AppModel
    let request: ConsentRequest
    let style: SkipperConsentPromptStyle

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            SkipperConsentPrompt(
                title: request.title,
                message: ConsentRequest.message,
                detail: request.controllerDeviceID.map { "Device ID \(DeviceID.formatted($0))" },
                countdown: request.countdown(now: context.date),
                style: style,
                allow: { model.answerConsent(allow: true) },
                decline: { model.answerConsent(allow: false) }
            )
        }
    }
}

struct ConsentOverlay: View {

    @EnvironmentObject private var model: AppModel

    var body: some View {
        if let request = model.consentRequest {
            ZStack {
                SkipperColor.scrim
                    .ignoresSafeArea()
                ConsentPromptView(request: request, style: .window)
                    .frame(maxWidth: 440)
                    .padding(SkipperSpace.xl)
            }
            .transition(.opacity)
        }
    }
}

@MainActor
final class ConsentNotifier {

    private static let identifier = "skipperdesk.consent"
    private var authorizationRequested = false

    private var center: UNUserNotificationCenter? {
        guard Bundle.main.bundleURL.pathExtension == "app" else { return nil }
        return UNUserNotificationCenter.current()
    }

    func bringForward() {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        NSApp.windows
            .first { $0.identifier?.rawValue.hasPrefix(WindowID.main) == true }?
            .makeKeyAndOrderFront(nil)
    }

    func post(_ request: ConsentRequest) {
        guard !NSApp.isActive, let center else { return }
        let content = UNMutableNotificationContent()
        content.title = request.title
        content.body = "Open SkipperDesk to allow or decline. \(request.countdown())."
        content.interruptionLevel = .timeSensitive
        let note = UNNotificationRequest(identifier: Self.identifier, content: content, trigger: nil)
        guard !authorizationRequested else {
            center.add(note)
            return
        }
        authorizationRequested = true
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }
            center.add(note)
        }
    }

    func withdraw() {
        center?.removeDeliveredNotifications(withIdentifiers: [Self.identifier])
        center?.removePendingNotificationRequests(withIdentifiers: [Self.identifier])
    }
}
