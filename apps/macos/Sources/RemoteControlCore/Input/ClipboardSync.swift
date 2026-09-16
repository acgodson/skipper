import Foundation
import CryptoKit
#if canImport(AppKit)
import AppKit
#endif

/// Text-only, two-way clipboard sync with the echo-loop guard PROTOCOL.md §5
/// makes mandatory.
///
/// **Why the guard is not optional.** Both Macs poll their own pasteboard. Mac A
/// copies, sends; Mac B writes it to its pasteboard, its own poll sees a change
/// and sends it straight back; Mac A writes it, sees a change, sends… The two
/// machines ping-pong the same string forever at the poll rate. The fix is one
/// remembered hash on each side, compared before both sending and applying.
///
/// This type is deliberately free of `NSPasteboard`: the loop-breaking logic is
/// the part that must be provably right, so it is asserted directly.
public final class ClipboardSyncEngine {

    /// PROTOCOL.md §5 caps the whole message at 256 KiB; this is the text
    /// budget inside that, leaving room for the envelope and JSON escaping.
    public static let maxTextBytes = 192 * 1024

    /// This Mac's deviceId — goes out as `originId`.
    public let originId: String

    /// The hash of the last text this side either put on its own pasteboard or
    /// accepted from the peer. Both directions compare against this one value,
    /// which is what makes the guard symmetric.
    public private(set) var lastHash: String?

    public private(set) var droppedEchoes = 0
    public private(set) var droppedOversize = 0

    public init(originId: String) {
        self.originId = originId
    }

    /// base64 SHA-256 of the UTF-8 text, per §5.
    public static func hash(_ text: String) -> String {
        Data(SHA256.hash(data: Data(text.utf8))).base64EncodedString()
    }

    /// The local pasteboard changed. Returns the message to send, or nil when
    /// there is nothing to send — which includes the case that matters: the
    /// change was us writing what the peer just sent.
    public func localChange(text: String) -> ClipboardTextPayload? {
        guard !text.isEmpty else { return nil }
        guard text.utf8.count <= ClipboardSyncEngine.maxTextBytes else {
            droppedOversize += 1
            // Byte count only. The contents never reach a log (§8).
            RCLog.info("clipboard: local change of \(text.utf8.count) bytes exceeds the \(ClipboardSyncEngine.maxTextBytes)-byte limit; not sent")
            return nil
        }
        let hash = ClipboardSyncEngine.hash(text)
        guard hash != lastHash else {
            droppedEchoes += 1
            return nil
        }
        lastHash = hash
        return ClipboardTextPayload(text: text, originId: originId, hash: hash)
    }

    /// A `clipboard_text` arrived. Returns the text to put on this Mac's
    /// pasteboard, or nil when the message must be dropped.
    public func receive(_ payload: ClipboardTextPayload) -> String? {
        // Our own message coming back. Cannot normally happen on a 1:1 data
        // channel, but a relayed or duplicated frame must not restart the loop.
        guard payload.originId != originId else {
            droppedEchoes += 1
            return nil
        }
        guard payload.text.utf8.count <= ClipboardSyncEngine.maxTextBytes else {
            droppedOversize += 1
            RCLog.info("clipboard: incoming \(payload.text.utf8.count) bytes exceeds the limit; dropped")
            return nil
        }
        // A hash that does not describe the text would defeat the guard
        // entirely — the next echo would carry a different hash and loop. Treat
        // it as malformed rather than trusting either field.
        let computed = ClipboardSyncEngine.hash(payload.text)
        guard computed == payload.hash else {
            RCLog.info("clipboard: incoming hash does not match its text; dropped")
            return nil
        }
        guard computed != lastHash else {
            droppedEchoes += 1
            return nil
        }
        lastHash = computed
        return payload.text
    }
}

#if canImport(AppKit)
/// Polls `NSPasteboard.changeCount` — the only way macOS offers to notice a
/// copy; there is no notification.
///
/// Text only, by design (PLAN.md §7 puts image and file clipboard out of scope).
/// Reading only `.string` also means an image or a file promise on the
/// pasteboard is left completely alone rather than being flattened.
@MainActor
public final class ClipboardMonitor {

    public let engine: ClipboardSyncEngine
    /// Set false by the "Clipboard Sync" setting; polling stops entirely.
    public var isEnabled = true {
        didSet {
            guard isEnabled != oldValue else { return }
            // Re-baseline so switching the setting on does not immediately send
            // whatever happened to be copied while it was off.
            lastChangeCount = pasteboard.changeCount
        }
    }
    public var onOutgoing: ((ClipboardTextPayload) -> Void)?

    private let pasteboard: NSPasteboard
    private let interval: TimeInterval
    private var timer: DispatchSourceTimer?
    private var lastChangeCount: Int

    /// `RC_PASTEBOARD_NAME`, when set, uses a NAMED pasteboard instead of the
    /// general one.
    ///
    /// Same purpose as `RC_IDENTITY_DIR` and `RC_SETTINGS_SUITE`: two instances
    /// on one Mac otherwise share `NSPasteboard.general`, so an integration test
    /// of clipboard sync would be testing one pasteboard talking to itself and
    /// could not tell a working echo guard from a broken one. Unset on a real
    /// install, where two Macs already have two pasteboards.
    nonisolated public static func environmentPasteboard() -> NSPasteboard {
        guard let name = ProcessInfo.processInfo.environment["RC_PASTEBOARD_NAME"], !name.isEmpty else {
            return .general
        }
        return NSPasteboard(name: NSPasteboard.Name(name))
    }

    public init(engine: ClipboardSyncEngine,
                pasteboard: NSPasteboard = ClipboardMonitor.environmentPasteboard(),
                interval: TimeInterval = 0.6) {
        self.engine = engine
        self.pasteboard = pasteboard
        self.interval = interval
        self.lastChangeCount = pasteboard.changeCount
    }

    deinit { timer?.cancel() }

    /// A DISPATCH timer, not a `Timer`.
    ///
    /// `RunLoop.main` timers only fire while something is running a CFRunLoop.
    /// The .app does (SwiftUI's event loop), but `rc-node` — the headless driver
    /// the integration scripts run — parks on `dispatchMain()`, which services
    /// the main dispatch queue and never spins a run loop. With a `Timer` the
    /// pasteboard poll silently never ran there: the copy happened, and nothing
    /// was ever sent. A dispatch source fires under both.
    public func start() {
        stop()
        lastChangeCount = pasteboard.changeCount
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + interval, repeating: interval)
        // NOT `MainActor.assumeIsolated`: a dispatch timer handler runs on the
        // main QUEUE, which the Swift runtime does not accept as the MainActor
        // executor when nothing is running a run loop — it traps. Hopping with
        // a Task is correct in both hosts.
        timer.setEventHandler { [weak self] in Task { @MainActor in self?.poll() } }
        timer.resume()
        self.timer = timer
    }

    public func stop() {
        timer?.cancel()
        timer = nil
    }

    public func poll() {
        guard isEnabled else { return }
        let count = pasteboard.changeCount
        guard count != lastChangeCount else { return }
        lastChangeCount = count
        guard let text = pasteboard.string(forType: .string) else { return }
        guard let payload = engine.localChange(text: text) else { return }
        onOutgoing?(payload)
    }

    /// Applies an incoming `clipboard_text`. Returns true when the pasteboard
    /// was actually written.
    @discardableResult
    public func apply(_ payload: ClipboardTextPayload) -> Bool {
        guard isEnabled else { return false }
        guard let text = engine.receive(payload) else { return false }
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        // Writing bumps changeCount. Absorbing it here is the second half of
        // the echo guard: without it the next poll would read our own write.
        lastChangeCount = pasteboard.changeCount
        return true
    }
}
#endif
