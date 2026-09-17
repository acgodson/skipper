import SwiftUI
import AppKit
import RemoteControlCore
import SkipperDesign

@main
struct RemoteControlApp: App {

    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = AppModel()

    var body: some Scene {
        Window("SkipperDesk", id: WindowID.main) {
            ContentView()
                .environmentObject(model)
                .frame(minWidth: SkipperLayout.minWindowWidth, minHeight: SkipperLayout.minWindowHeight)
                .tint(SkipperColor.accent)
        }
        .defaultSize(width: SkipperLayout.windowWidth, height: SkipperLayout.windowHeight)
        .windowResizability(.contentMinSize)
        .windowToolbarStyle(.unified(showsTitle: false))
        .commands {
            CommandGroup(replacing: .newItem) {}
        }

        MenuBarExtra {
            MenuBarContent()
                .environmentObject(model)
                .tint(SkipperColor.accent)
        } label: {
            MenuBarLabel()
                .environmentObject(model)
        }
        .menuBarExtraStyle(.window)
    }
}

private struct MenuBarLabel: View {

    @EnvironmentObject private var model: AppModel

    var body: some View {
        Image(systemName: symbol)
    }

    private var symbol: String {
        if model.consentRequest != nil { return "hand.raised.fill" }
        return model.sessionActive ? "display.and.arrow.down" : "display"
    }
}

enum WindowID {
    static let main = "main"
}

@MainActor
final class URLCallbackBus {

    static let shared = URLCallbackBus()

    private var pending: [URL] = []

    var handler: ((URL) -> Void)? {
        didSet {
            guard handler != nil, !pending.isEmpty else { return }
            let queued = pending
            pending = []
            queued.forEach { handler?($0) }
        }
    }

    func receive(_ url: URL) {
        RCLog.info("url: opened \(url.scheme ?? "?")://\(url.host ?? "?")")
        guard let handler else {
            pending.append(url)
            return
        }
        handler(url)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    private var inputSelfTest: InputSelfTest?

    func application(_ application: NSApplication, open urls: [URL]) {
        urls.forEach { URLCallbackBus.shared.receive($0) }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        if InputSelfTest.isRequested {
            let test = InputSelfTest()
            inputSelfTest = test
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { test.run() }
        }
        #if DEBUG
        applyRequestedAppearance()
        dumpWindowIfRequested()
        #endif
    }

    #if DEBUG
    private func applyRequestedAppearance() {
        switch UserDefaults.standard.string(forKey: "RCAppearance") {
        case "dark": NSApp.appearance = NSAppearance(named: .darkAqua)
        case "light": NSApp.appearance = NSAppearance(named: .aqua)
        default: break
        }
    }
    #endif

    #if DEBUG
    private func dumpWindowIfRequested() {
        guard let path = UserDefaults.standard.string(forKey: "RCDumpUI") else { return }
        var attempt = 0
        func note(_ message: String) {
            try? message.appending("\n").data(using: .utf8)?
                .write(to: URL(fileURLWithPath: path + ".log"),
                       options: attempt == 1 ? [] : [])
        }
        func findScrollView(_ view: NSView) -> NSScrollView? {
            if let scrollView = view as? NSScrollView { return scrollView }
            for subview in view.subviews {
                if let found = findScrollView(subview) { return found }
            }
            return nil
        }

        func render(_ view: NSView, to path: String) -> Bool {
            guard view.bounds.width > 1, view.bounds.height > 1,
                  let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return false }
            view.cacheDisplay(in: view.bounds, to: rep)
            guard let data = rep.representation(using: .png, properties: [:]) else { return false }
            try? data.write(to: URL(fileURLWithPath: path))
            return true
        }

        func attemptDump() {
            attempt += 1
            let windows = NSApp.windows.map { "\($0.className) visible=\($0.isVisible) frame=\($0.frame)" }
            note("attempt \(attempt): \(windows.joined(separator: " | "))")
            if let window = NSApp.windows.first(where: { $0.isVisible && $0.frame.width > 200 }),
               let view = window.contentView {
                if let document = findScrollView(view)?.documentView {
                    _ = render(document, to: (path as NSString).deletingPathExtension + ".full.png")
                }
                if render(view, to: path) { return }
            }
            if attempt < 8 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { attemptDump() }
            }
        }
        let requested = UserDefaults.standard.double(forKey: "RCDumpUIDelay")
        let delay = requested > 0 ? requested : 2.0
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { attemptDump() }
    }
    #endif
}
