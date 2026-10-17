import CoreGraphics
import Foundation
import RCTestKit
import RemoteControlCore

private struct Counters {
    var hides = 0
    var unhides = 0
}

@MainActor
private func ownership() -> (CursorOwnership, () -> Counters) {
    final class Box { var counters = Counters() }
    let box = Box()
    let owner = CursorOwnership(
        hide: { box.counters.hides += 1 },
        unhide: { box.counters.unhides += 1 })
    return (owner, { box.counters })
}

@MainActor
private func liveOverPicture(_ owner: CursorOwnership) {
    owner.update { conditions in
        conditions.attached = true
        conditions.windowActive = true
        conditions.hasPicture = true
        conditions.pointerInsideView = true
        conditions.pointerOverPicture = true
    }
}

public let cursorOwnershipSuite = TestSuite("cursor/ownership", [

    TestCase("a live picture under the pointer takes the cursor, and takes it once") {
        let (owner, counters) = ownership()
        try expectEqual(owner.owner, .local)
        liveOverPicture(owner)
        try expectEqual(owner.owner, .remote)
        try expect(owner.isNativeCursorHidden)
        liveOverPicture(owner)
        try expectEqual(counters().hides, 1, "a repeated condition must not hide the cursor twice")
        try expectEqual(counters().unhides, 0)
    },

    TestCase("moving onto local controller UI hands the pointer back, balanced") {
        let (owner, counters) = ownership()
        liveOverPicture(owner)
        owner.update { $0.overLocalControl = true }
        try expectEqual(owner.owner, .local)
        try expectFalse(owner.isNativeCursorHidden)
        try expectEqual(counters().hides, 1)
        try expectEqual(counters().unhides, 1)
        owner.update { $0.overLocalControl = false }
        try expectEqual(owner.owner, .remote)
        try expectEqual(counters().hides, 2)
        try expectEqual(counters().unhides, 1)
    },

    TestCase("a control appearing under a stationary pointer hands the pointer back") {
        let (owner, _) = ownership()
        liveOverPicture(owner)
        let before = owner.conditions
        owner.update { $0.overLocalControl = true }
        try expectEqual(owner.owner, .local)
        try expectEqual(owner.conditions.pointerInsideView, before.pointerInsideView,
                        "nothing about the pointer itself moved")
    },

    TestCase("the letterbox margin is this Mac's, not the remote Mac's") {
        let (owner, _) = ownership()
        liveOverPicture(owner)
        owner.update { $0.pointerOverPicture = false }
        try expectEqual(owner.owner, .local)
    },

    TestCase("an attached track with no picture yet keeps the native cursor") {
        let (owner, counters) = ownership()
        owner.update { conditions in
            conditions.attached = true
            conditions.windowActive = true
            conditions.pointerInsideView = true
            conditions.pointerOverPicture = true
        }
        try expectEqual(owner.owner, .local)
        try expectEqual(counters().hides, 0, "nothing is drawn yet, so nothing may be hidden")
        owner.update { $0.hasPicture = true }
        try expectEqual(owner.owner, .remote)
    },

    TestCase("losing the key window, the app, or the track hands the pointer back") {
        for surrender in [{ (c: inout CursorConditions) in c.windowActive = false },
                          { (c: inout CursorConditions) in c.attached = false },
                          { (c: inout CursorConditions) in c.hasPicture = false },
                          { (c: inout CursorConditions) in c.pointerInsideView = false }] {
            let (owner, counters) = ownership()
            liveOverPicture(owner)
            owner.update(surrender)
            try expectEqual(owner.owner, .local)
            try expectEqual(counters().hides, counters().unhides, "every hide is paired")
        }
    },

    TestCase("a menu or popover owns the pointer while it is tracking") {
        let (owner, _) = ownership()
        liveOverPicture(owner)
        owner.update { $0.menuTracking = true }
        try expectEqual(owner.owner, .local)
        owner.update { $0.menuTracking = false }
        try expectEqual(owner.owner, .remote)
    },

    TestCase("a remote drag keeps the pointer even across local UI and outside the view") {
        let (owner, _) = ownership()
        liveOverPicture(owner)
        owner.update { $0.remoteDragInProgress = true }
        owner.update { conditions in
            conditions.overLocalControl = true
            conditions.pointerOverPicture = false
            conditions.pointerInsideView = false
        }
        try expectEqual(owner.owner, .remote, "the drag belongs to the remote Mac until the button is let go")
        owner.update { $0.remoteDragInProgress = false }
        try expectEqual(owner.owner, .local)
    },

    TestCase("a disconnect mid-drag still hands the pointer back") {
        let (owner, counters) = ownership()
        liveOverPicture(owner)
        owner.update { $0.remoteDragInProgress = true }
        owner.update { $0.attached = false }
        try expectEqual(owner.owner, .local)
        try expectEqual(counters().hides, counters().unhides)
    },

    TestCase("teardown surrenders the cursor, and surrendering twice is harmless") {
        let (owner, counters) = ownership()
        liveOverPicture(owner)
        owner.surrender()
        owner.surrender()
        try expectEqual(owner.owner, .local)
        try expectEqual(counters().hides, 1)
        try expectEqual(counters().unhides, 1)
    },

    TestCase("the owner is announced on transitions only") {
        let (owner, _) = ownership()
        var announced: [CursorOwner] = []
        owner.onChange = { announced.append($0) }
        liveOverPicture(owner)
        liveOverPicture(owner)
        owner.update { $0.overLocalControl = true }
        owner.update { $0.menuTracking = true }
        owner.update { $0.overLocalControl = false }
        try expectEqual(announced, [.remote, .local])
    },

    TestCase("local control regions are hit by point, and empty ones are dropped") {
        let regions = LocalControlRegions([
            CGRect(x: 100, y: 0, width: 200, height: 40),
            CGRect(x: 10, y: 10, width: 0, height: 0),
        ])
        try expectEqual(regions.rects.count, 1, "an empty rect would swallow nothing but noise")
        try expect(regions.contains(CGPoint(x: 150, y: 20)))
        try expectFalse(regions.contains(CGPoint(x: 150, y: 60)))
        try expectFalse(regions.contains(CGPoint(x: 99, y: 20)))
        try expect(LocalControlRegions().isEmpty)
        try expectFalse(LocalControlRegions().contains(.zero))
    },

    TestCase("handing the pointer back releases what the remote Mac was holding") {
        let sender = RemoteInputSender()
        var sent: [OutboundInput] = []
        sender.send = { sent.append($0) }

        try expectFalse(sender.releaseHeld(), "nothing held, nothing to say")
        try expectEqual(sent.count, 0)

        sender.handle(RemotePointerEvent(
            sample: RemotePointerSample(viewPoint: .zero, remotePixel: .zero,
                                        normalized: CGPoint(x: 0.5, y: 0.5), insideVideo: true),
            kind: .down))
        sender.key(down: true, keycode: 49, modifiers: [.command])
        try expect(sender.releaseHeld())
        guard case .reset = sent.last else { throw fail("expected a reset, got \(String(describing: sent.last))") }
        try expectEqual(sender.heldButtons.count, 0)
        try expectEqual(sender.heldKeycodes.count, 0)
        try expectFalse(sender.releaseHeld(), "a second release has nothing left to let go of")
    },
])
