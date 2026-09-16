import SwiftUI
import AppKit
import RemoteControlCore

@main
struct RemoteControlApp: App {

    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = AppModel()

    var body: some Scene {
        Window("RemoteControl", id: WindowID.main) {
            ContentView()
                .environmentObject(model)
                .frame(minWidth: 520, minHeight: 460)
        }
        // Landscape by default. Every screen this app shows is either a short form
        // or a 16:10 desktop, and a tall narrow window letterboxed the remote
        // screen into a thin strip — the setup forms are centred and width-capped
        // instead, so a wide window costs them nothing.
        .defaultSize(width: 1000, height: 660)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }

        // Menu-bar residency: closing the window leaves the app running and
        // reachable, which is the whole point of unattended access.
        MenuBarExtra {
            MenuBarContent()
                .environmentObject(model)
        } label: {
            Image(systemName: model.sessionActive ? "display.and.arrow.down" : "display")
        }
    }
}

enum WindowID {
    static let main = "main"
}

/// Delivers `skipperdesk://` URLs from LaunchServices to whoever is interested.
///
/// It is a bus rather than a direct call because the two ends cannot reach each
/// other: the URL arrives at the `NSApplicationDelegate`, and the object that
/// knows what to do with it is the `AppModel` the SwiftUI scene owns. It also
/// buffers, because a URL that launches the app arrives before the model is
/// built and must not be dropped.
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

    /// Keep the process alive when the last window closes — the menu-bar item
    /// remains, and a host must stay reachable with no window on screen.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    /// Held for the life of the run when RC_INPUT_SELFTEST=1.
    private var inputSelfTest: InputSelfTest?

    /// The `skipperdesk` scheme is declared in the bundle's `CFBundleURLTypes`
    /// (scripts/build.sh), so LaunchServices turns `open "skipperdesk://link?…"`
    /// into this call — the browser's half of the API.md §1.1 handoff.
    func application(_ application: NSApplication, open urls: [URL]) {
        urls.forEach { URLCallbackBus.shared.receive($0) }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        // OS-level input verification, run inside the bundle so the app's own
        // Accessibility grant applies (see InputSelfTest). Off unless asked for;
        // it terminates the app when it finishes.
        if InputSelfTest.isRequested {
            let test = InputSelfTest()
            inputSelfTest = test
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { test.run() }
        }
        #if DEBUG
        dumpWindowIfRequested()
        #endif
    }

    #if DEBUG
    /// Debug builds only. `open RemoteControl.app --args -RCDumpUI /path/out.png`
    /// renders the main window to a PNG from inside the process, which needs no
    /// Screen Recording permission. Exists so the UI can be eyeballed on a
    /// machine where the terminal has not been granted screen capture.
    private func dumpWindowIfRequested() {
        guard let path = UserDefaults.standard.string(forKey: "RCDumpUI") else { return }
        var attempt = 0
        func note(_ message: String) {
            try? message.appending("\n").data(using: .utf8)?
                .write(to: URL(fileURLWithPath: path + ".log"),
                       options: attempt == 1 ? [] : [])
        }
        /// Finds the first NSScrollView in the hierarchy. The main content is a
        /// SwiftUI ScrollView, and macOS clamps a window to the screen height, so
        /// capturing the window can never show the whole page. The scroll view's
        /// documentView is laid out at full content height, so rendering *that*
        /// is the only way to get everything — including the storage footer — in
        /// one image.
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
                // Full-page capture next to the window capture, when there is a
                // scroll view to take it from.
                if let document = findScrollView(view)?.documentView {
                    _ = render(document, to: (path as NSString).deletingPathExtension + ".full.png")
                }
                if render(view, to: path) { return }
            }
            if attempt < 8 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { attemptDump() }
            }
        }
        // `-RCDumpUIDelay <seconds>` waits before the first attempt. Without it
        // the dump always catches the launch state, which is exactly the screen
        // you do not want a picture of when you are trying to show a live
        // session rendering.
        // `double(forKey:)`, not `object(forKey:) as? Double`: a value that came
        // from the command line is a STRING, so the cast silently fails and the
        // delay silently reverts to 2 s — which looks exactly like the flag
        // being ignored.
        let requested = UserDefaults.standard.double(forKey: "RCDumpUIDelay")
        let delay = requested > 0 ? requested : 2.0
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { attemptDump() }
    }
    #endif
}
