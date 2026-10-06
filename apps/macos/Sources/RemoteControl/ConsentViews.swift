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
        TimelineView(.periodic(from: .now, by: 0.25)) { context in
            SkipperConsentPrompt(
                title: request.title,
                message: ConsentRequest.message,
                notice: request.notice,
                details: [request.deviceIDLine].compactMap { $0 },
                moreDetails: [request.fingerprintLine].compactMap { $0 },
                countdown: request.countdown(now: context.date),
                style: style,
                allowEnabled: request.allowEnabled(now: context.date),
                allow: { model.answerConsent(allow: true, promptID: request.promptID) },
                decline: { model.answerConsent(allow: false, promptID: request.promptID) }
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

/// Tells the owner a Mac is asking without taking focus from whatever they
/// are doing: the prompt itself lives in the window and the menu-bar panel.
@MainActor
final class ConsentNotifier {

    private static let identifier = "skipperdesk.consent"
    private static let category = "skipperdesk.consent.request"
    private var authorizationRequested = false

    private var center: UNUserNotificationCenter? {
        guard Bundle.main.bundleURL.pathExtension == "app" else { return nil }
        return UNUserNotificationCenter.current()
    }

    func post() {
        guard let center else { return }
        let content = UNMutableNotificationContent()
        content.title = "SkipperDesk"
        content.body = ConsentRequest.notificationBody
        content.categoryIdentifier = Self.category
        content.interruptionLevel = .timeSensitive
        let note = UNNotificationRequest(identifier: Self.identifier, content: content, trigger: nil)
        guard !authorizationRequested else {
            center.add(note)
            return
        }
        authorizationRequested = true
        center.setNotificationCategories([
            UNNotificationCategory(identifier: Self.category, actions: [], intentIdentifiers: [],
                                   hiddenPreviewsBodyPlaceholder: ConsentRequest.notificationBody,
                                   options: [])
        ])
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
