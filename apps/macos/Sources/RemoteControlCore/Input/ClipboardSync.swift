import Foundation
import CryptoKit
#if canImport(AppKit)
import AppKit
#endif

public final class ClipboardSyncEngine {

    public static let maxTextBytes = 192 * 1024

    public let originId: String

    public private(set) var lastHash: String?

    public private(set) var droppedEchoes = 0
    public private(set) var droppedOversize = 0
    public private(set) var droppedPrivate = 0

    private let secrets: ClipboardSecrets

    public init(originId: String, secrets: ClipboardSecrets = .shared) {
        self.originId = originId
        self.secrets = secrets
    }

    public static func hash(_ text: String) -> String {
        Data(SHA256.hash(data: Data(text.utf8))).base64EncodedString()
    }

    public func localChange(text: String, pasteboardTypes: [String] = []) -> ClipboardTextPayload? {
        guard !text.isEmpty else { return nil }
        guard !PasteboardMarker.isPrivate(pasteboardTypes), !secrets.contains(in: text) else {
            droppedPrivate += 1
            RCLog.info("clipboard: local change is marked private or holds this Mac's access code; not sent")
            return nil
        }
        guard text.utf8.count <= ClipboardSyncEngine.maxTextBytes else {
            droppedOversize += 1
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

    public func receive(_ payload: ClipboardTextPayload) -> String? {
        guard payload.originId != originId else {
            droppedEchoes += 1
            return nil
        }
        guard payload.text.utf8.count <= ClipboardSyncEngine.maxTextBytes else {
            droppedOversize += 1
            RCLog.info("clipboard: incoming \(payload.text.utf8.count) bytes exceeds the limit; dropped")
            return nil
        }
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
@MainActor
public final class ClipboardMonitor {

    public let engine: ClipboardSyncEngine
    public var isEnabled = true {
        didSet {
            guard isEnabled != oldValue else { return }
            lastChangeCount = pasteboard.changeCount
        }
    }
    public var onOutgoing: ((ClipboardTextPayload) -> Void)?

    private let pasteboard: NSPasteboard
    private let interval: TimeInterval
    private var timer: DispatchSourceTimer?
    private var lastChangeCount: Int

    nonisolated public static func environmentPasteboard() -> NSPasteboard {
        guard let name = DevelopmentHooks.value(.pasteboardName) else {
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

    public func start() {
        stop()
        lastChangeCount = pasteboard.changeCount
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + interval, repeating: interval)
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
        let types = pasteboard.types?.map(\.rawValue) ?? []
        guard let payload = engine.localChange(text: text, pasteboardTypes: types) else { return }
        onOutgoing?(payload)
    }

    @discardableResult
    public func apply(_ payload: ClipboardTextPayload) -> Bool {
        guard isEnabled else { return false }
        guard let text = engine.receive(payload) else { return false }
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        lastChangeCount = pasteboard.changeCount
        return true
    }
}
#endif
