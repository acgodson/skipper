#if canImport(AppKit)
import AppKit

// NSCursor.currentSystem hands back a fresh object on every call, so shapes are
// recognised by image size and hot spot, and by rendered pixels when those two
// are shared (open/closed hand, the two resize arrows). Public API has no busy
// or diagonal-resize cursor on macOS 14, so a Mac host never reports those.
@MainActor
public final class SystemCursorObserver {

    public static let minimumPollInterval: TimeInterval = 0.05
    public static let settleDelay: UInt64 = 60_000_000

    public var onChange: ((CursorShape) -> Void)?
    public private(set) var current: CursorShape?

    private var lastPoll = Date.distantPast
    private var trailingPoll: Task<Void, Never>?
    private lazy var references: [Reference] = Self.makeReferences()

    public init() {}

    public func reset() {
        current = nil
        trailingPoll?.cancel()
        trailingPoll = nil
    }

    public func poll(force: Bool = false, now: Date = Date()) {
        guard force || now.timeIntervalSince(lastPoll) >= Self.minimumPollInterval else {
            pollAfterInput()
            return
        }
        lastPoll = now
        guard let cursor = NSCursor.currentSystem else { return }
        let shape = classify(cursor)
        guard shape != current else { return }
        current = shape
        onChange?(shape)
    }

    public func pollAfterInput() {
        guard trailingPoll == nil else { return }
        trailingPoll = Task { [weak self] in
            try? await Task.sleep(nanoseconds: Self.settleDelay)
            guard let self, !Task.isCancelled else { return }
            self.trailingPoll = nil
            self.poll(force: true)
        }
    }

    public func classify(_ cursor: NSCursor) -> CursorShape {
        let signature = Signature(cursor)
        let candidates = references.filter { $0.signature == signature }
        guard !candidates.isEmpty else { return .arrow }
        if let pixels = Self.pixels(of: cursor),
           let exact = candidates.first(where: { $0.pixels == pixels }) {
            return exact.shape
        }
        return candidates.count == 1 ? candidates[0].shape : .arrow
    }

    public var recognisedShapes: [CursorShape] { references.map(\.shape) }

    public func referenceCursor(for shape: CursorShape) -> NSCursor? {
        Self.systemCursors.first { $0.shape == shape }?.cursor
    }

    // MARK: - Internals

    private struct Signature: Equatable {
        let width: Int
        let height: Int
        let hotX: Int
        let hotY: Int

        init(_ cursor: NSCursor) {
            width = Int((cursor.image.size.width * 2).rounded())
            height = Int((cursor.image.size.height * 2).rounded())
            hotX = Int((cursor.hotSpot.x * 2).rounded())
            hotY = Int((cursor.hotSpot.y * 2).rounded())
        }
    }

    private struct Reference {
        let shape: CursorShape
        let signature: Signature
        let pixels: Data?
    }

    private static var systemCursors: [(shape: CursorShape, cursor: NSCursor)] {
        [
            (.arrow, .arrow),
            (.iBeam, .iBeam),
            (.crosshair, .crosshair),
            (.pointingHand, .pointingHand),
            (.openHand, .openHand),
            (.closedHand, .closedHand),
            (.resizeLeftRight, .resizeLeftRight),
            (.resizeUpDown, .resizeUpDown),
            (.notAllowed, .operationNotAllowed),
        ]
    }

    private static func makeReferences() -> [Reference] {
        _ = NSApplication.shared
        return systemCursors
            .filter { $0.cursor.image.size.width > 0 && $0.cursor.image.size.height > 0 }
            .map { Reference(shape: $0.shape, signature: Signature($0.cursor), pixels: pixels(of: $0.cursor)) }
    }

    private static func pixels(of cursor: NSCursor) -> Data? {
        let size = cursor.image.size
        let width = Int((size.width * 2).rounded()), height = Int((size.height * 2).rounded())
        guard width > 0, height > 0,
              let context = CGContext(data: nil, width: width, height: height,
                                      bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        var rect = CGRect(x: 0, y: 0, width: width, height: height)
        guard let image = cursor.image.cgImage(forProposedRect: &rect, context: nil, hints: nil) else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let bytes = context.data else { return nil }
        return Data(bytes: bytes, count: width * height * 4)
    }
}
#endif
