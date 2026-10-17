import CoreGraphics
import Foundation
#if canImport(AppKit)
import AppKit
#endif

// Who owns the pointer during a session: the remote Mac, which means the native cursor is
// hidden and the drawn one stands in for it, or this Mac, which means the native cursor is
// visible and nothing is forwarded. Every hide is paired with exactly one unhide here —
// `NSCursor.hide()` is counted, and nothing else in the app may call it.

public enum CursorOwner: String, Equatable, Sendable {
    case local
    case remote
}

public struct CursorConditions: Equatable, Sendable {

    public var attached = false
    public var windowActive = false
    public var hasPicture = false
    public var pointerInsideView = false
    public var pointerOverPicture = false
    public var overLocalControl = false
    public var menuTracking = false
    public var remoteDragInProgress = false

    public init() {}

    public var owner: CursorOwner {
        guard attached, windowActive, hasPicture, !menuTracking else { return .local }
        if remoteDragInProgress { return .remote }
        guard pointerInsideView, pointerOverPicture, !overLocalControl else { return .local }
        return .remote
    }
}

@MainActor
public final class CursorOwnership {

    public private(set) var conditions = CursorConditions()
    public private(set) var owner: CursorOwner = .local
    public var onChange: ((CursorOwner) -> Void)?

    private let hideNativeCursor: () -> Void
    private let unhideNativeCursor: () -> Void
    private var nativeCursorHidden = false

    public init(hide: @escaping () -> Void, unhide: @escaping () -> Void) {
        hideNativeCursor = hide
        unhideNativeCursor = unhide
    }

    public var isNativeCursorHidden: Bool { nativeCursorHidden }

    public func update(_ change: (inout CursorConditions) -> Void) {
        var next = conditions
        change(&next)
        apply(next)
    }

    public func surrender() {
        apply(CursorConditions())
    }

    private func apply(_ next: CursorConditions) {
        conditions = next
        let resolved = next.owner
        setNativeCursor(hidden: resolved == .remote)
        guard resolved != owner else { return }
        owner = resolved
        onChange?(resolved)
    }

    private func setNativeCursor(hidden: Bool) {
        guard hidden != nativeCursorHidden else { return }
        nativeCursorHidden = hidden
        if hidden { hideNativeCursor() } else { unhideNativeCursor() }
    }
}

#if canImport(AppKit)
public extension CursorOwnership {
    convenience init() {
        self.init(hide: { NSCursor.hide() }, unhide: { NSCursor.unhide() })
    }
}
#endif

// The parts of the video view that local controller UI is drawn over, in the view's own
// coordinates. The overlays are SwiftUI siblings, so the view cannot find them by hit-testing
// itself; they hand their geometry down instead.

public struct LocalControlRegions: Equatable, Sendable {

    public private(set) var rects: [CGRect]

    public init(_ rects: [CGRect] = []) {
        self.rects = rects.filter { !$0.isEmpty }
    }

    public var isEmpty: Bool { rects.isEmpty }

    public func contains(_ point: CGPoint) -> Bool {
        rects.contains { $0.contains(point) }
    }
}
