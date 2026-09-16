import Foundation
import CoreGraphics
import RCTestKit
import RemoteControlCore

public let videoGeometrySuite = TestSuite("VideoGeometry", [

    TestCase("aspect fit: identical aspect ratios fill the container exactly") {
        let rect = RemoteDisplayGeometry.aspectFit(content: CGSize(width: 1600, height: 900),
                                                   within: CGSize(width: 800, height: 450))
        try expectClose(rect, CGRect(x: 0, y: 0, width: 800, height: 450))
    },

    TestCase("aspect fit: content wider than the container leaves bars top and bottom") {
        let rect = RemoteDisplayGeometry.aspectFit(content: CGSize(width: 1600, height: 900),
                                                   within: CGSize(width: 800, height: 600))
        try expectClose(rect, CGRect(x: 0, y: 75, width: 800, height: 450))
    },

    TestCase("aspect fit: content taller than the container leaves bars left and right") {
        let rect = RemoteDisplayGeometry.aspectFit(content: CGSize(width: 900, height: 1600),
                                                   within: CGSize(width: 800, height: 600))
        try expectClose(rect, CGRect(x: 231.25, y: 0, width: 337.5, height: 600))
    },

    TestCase("aspect fit: a degenerate size produces an empty rect, never a NaN") {
        try expectEqual(RemoteDisplayGeometry.aspectFit(content: .zero,
                                                        within: CGSize(width: 100, height: 100)), .zero)
        try expectEqual(RemoteDisplayGeometry.aspectFit(content: CGSize(width: 100, height: 100),
                                                        within: .zero), .zero)
    },

    TestCase("no letterbox: corners and centre map to exact remote pixels") {
        let geometry = RemoteDisplayGeometry(remoteSize: CGSize(width: 1600, height: 900),
                                             viewSize: CGSize(width: 800, height: 450))
        try expectClose(geometry.scale, 2.0)
        try expectClose(try expectNotNil(geometry.remotePixel(fromView: CGPoint(x: 0, y: 0))),
                        CGPoint(x: 0, y: 0))
        try expectClose(try expectNotNil(geometry.remotePixel(fromView: CGPoint(x: 800, y: 450))),
                        CGPoint(x: 1600, y: 900))
        try expectClose(try expectNotNil(geometry.remotePixel(fromView: CGPoint(x: 400, y: 225))),
                        CGPoint(x: 800, y: 450))
        try expectClose(try expectNotNil(geometry.normalized(fromView: CGPoint(x: 400, y: 225))),
                        CGPoint(x: 0.5, y: 0.5))
        try expectClose(try expectNotNil(geometry.normalized(fromView: CGPoint(x: 200, y: 45))),
                        CGPoint(x: 0.25, y: 0.1))
    },

    TestCase("horizontal bars: the bar offset is subtracted before scaling") {
        let geometry = RemoteDisplayGeometry(remoteSize: CGSize(width: 1600, height: 900),
                                             viewSize: CGSize(width: 800, height: 600))
        try expectClose(geometry.videoRect, CGRect(x: 0, y: 75, width: 800, height: 450))
        try expectClose(geometry.scale, 2.0)
        try expectClose(try expectNotNil(geometry.remotePixel(fromView: CGPoint(x: 0, y: 75))),
                        CGPoint(x: 0, y: 0))
        try expectClose(try expectNotNil(geometry.remotePixel(fromView: CGPoint(x: 800, y: 525))),
                        CGPoint(x: 1600, y: 900))
        try expectClose(try expectNotNil(geometry.remotePixel(fromView: CGPoint(x: 400, y: 300))),
                        CGPoint(x: 800, y: 450))
        try expectClose(try expectNotNil(geometry.remotePixel(fromView: CGPoint(x: 100, y: 225))),
                        CGPoint(x: 200, y: 300))
    },

    TestCase("vertical bars: the bar offset is subtracted before scaling") {
        let geometry = RemoteDisplayGeometry(remoteSize: CGSize(width: 900, height: 1600),
                                             viewSize: CGSize(width: 800, height: 600))
        try expectClose(geometry.videoRect, CGRect(x: 231.25, y: 0, width: 337.5, height: 600))
        try expectClose(geometry.scale, 900.0 / 337.5, tolerance: 1e-12)
        try expectClose(try expectNotNil(geometry.remotePixel(fromView: CGPoint(x: 231.25, y: 0))),
                        CGPoint(x: 0, y: 0))
        try expectClose(try expectNotNil(geometry.remotePixel(fromView: CGPoint(x: 568.75, y: 600))),
                        CGPoint(x: 900, y: 1600), tolerance: 1e-9)
        try expectClose(try expectNotNil(geometry.normalized(fromView: CGPoint(x: 400, y: 300))),
                        CGPoint(x: 0.5, y: 0.5), tolerance: 1e-12)
    },

    TestCase("a point in a letterbox bar maps to nil, on both axes") {
        let horizontal = RemoteDisplayGeometry(remoteSize: CGSize(width: 1600, height: 900),
                                               viewSize: CGSize(width: 800, height: 600))
        try expectNil(horizontal.remotePixel(fromView: CGPoint(x: 400, y: 74.9)),
                      "a point above the video is not on the remote screen")
        try expectNil(horizontal.remotePixel(fromView: CGPoint(x: 400, y: 525.1)))
        try expectNil(horizontal.normalized(fromView: CGPoint(x: 400, y: 0)))

        let vertical = RemoteDisplayGeometry(remoteSize: CGSize(width: 900, height: 1600),
                                             viewSize: CGSize(width: 800, height: 600))
        try expectNil(vertical.remotePixel(fromView: CGPoint(x: 231.24, y: 300)))
        try expectNil(vertical.remotePixel(fromView: CGPoint(x: 568.76, y: 300)))
        try expectNil(vertical.remotePixel(fromView: CGPoint(x: -5, y: -5)))
        try expectNil(vertical.remotePixel(fromView: CGPoint(x: 5000, y: 5000)))
    },

    TestCase("clamping pins a point to the video edge with exact values") {
        let geometry = RemoteDisplayGeometry(remoteSize: CGSize(width: 1600, height: 900),
                                             viewSize: CGSize(width: 800, height: 600))
        try expectClose(geometry.clampedNormalized(fromView: CGPoint(x: 400, y: 0)),
                        CGPoint(x: 0.5, y: 0.0))
        try expectClose(geometry.clampedNormalized(fromView: CGPoint(x: 400, y: 600)),
                        CGPoint(x: 0.5, y: 1.0))
        try expectClose(geometry.clampedNormalized(fromView: CGPoint(x: -900, y: -900)),
                        CGPoint(x: 0.0, y: 0.0))
        try expectClose(geometry.clampedNormalized(fromView: CGPoint(x: 9000, y: 9000)),
                        CGPoint(x: 1.0, y: 1.0))
        try expectClose(geometry.clampedNormalized(fromView: CGPoint(x: 200, y: 300)),
                        CGPoint(x: 0.25, y: 0.5))
    },

    TestCase("sample(): a move outside the video is nil, a drag outside is clamped") {
        let geometry = RemoteDisplayGeometry(remoteSize: CGSize(width: 1600, height: 900),
                                             viewSize: CGSize(width: 800, height: 600))
        try expectNil(geometry.sample(atView: CGPoint(x: 400, y: 10), clamp: false))

        let dragged = try expectNotNil(geometry.sample(atView: CGPoint(x: 400, y: 10), clamp: true))
        try expectFalse(dragged.insideVideo, "the sample must admit it was clamped")
        try expectClose(dragged.normalized, CGPoint(x: 0.5, y: 0.0))
        try expectClose(dragged.remotePixel, CGPoint(x: 800, y: 0))

        let inside = try expectNotNil(geometry.sample(atView: CGPoint(x: 400, y: 300), clamp: false))
        try expect(inside.insideVideo)
        try expectClose(inside.remotePixel, CGPoint(x: 800, y: 450))
        try expectClose(inside.normalized, CGPoint(x: 0.5, y: 0.5))
    },

    TestCase("view -> remote -> view round-trips") {
        let geometry = RemoteDisplayGeometry(remoteSize: CGSize(width: 3024, height: 1964),
                                             viewSize: CGSize(width: 1280, height: 1000))
        let start = CGPoint(x: 700, y: 480)
        let normalized = try expectNotNil(geometry.normalized(fromView: start))
        try expectClose(geometry.viewPoint(fromNormalized: normalized), start, tolerance: 1e-9)
        let pixel = try expectNotNil(geometry.remotePixel(fromView: start))
        try expectClose(geometry.viewPoint(fromRemotePixel: pixel), start, tolerance: 1e-9)
    },

    TestCase("a view delta becomes remote pixels at the same scale (scroll units)") {
        let geometry = RemoteDisplayGeometry(remoteSize: CGSize(width: 1600, height: 900),
                                             viewSize: CGSize(width: 800, height: 600))
        let delta = geometry.remoteDelta(fromViewDelta: CGSize(width: 10, height: -20))
        try expectClose(Double(delta.width), 20)
        try expectClose(Double(delta.height), -40)
    },

    TestCase("resizing the controller window does not change the remote coordinate space") {
        let small = RemoteDisplayGeometry(remoteSize: CGSize(width: 1600, height: 900),
                                          viewSize: CGSize(width: 400, height: 300))
        let large = RemoteDisplayGeometry(remoteSize: CGSize(width: 1600, height: 900),
                                          viewSize: CGSize(width: 1600, height: 1200))
        let smallPoint = CGPoint(x: small.videoRect.minX + small.videoRect.width * 0.3,
                                 y: small.videoRect.minY + small.videoRect.height * 0.7)
        let largePoint = CGPoint(x: large.videoRect.minX + large.videoRect.width * 0.3,
                                 y: large.videoRect.minY + large.videoRect.height * 0.7)
        try expectClose(try expectNotNil(small.normalized(fromView: smallPoint)),
                        CGPoint(x: 0.3, y: 0.7), tolerance: 1e-12)
        try expectClose(try expectNotNil(large.normalized(fromView: largePoint)),
                        CGPoint(x: 0.3, y: 0.7), tolerance: 1e-12)
    },

    TestCase("an unusable geometry converts to nil rather than to NaN") {
        let noVideo = RemoteDisplayGeometry(remoteSize: .zero, viewSize: CGSize(width: 800, height: 600))
        try expectFalse(noVideo.isValid)
        try expectNil(noVideo.remotePixel(fromView: CGPoint(x: 10, y: 10)))
        try expectNil(noVideo.normalized(fromView: CGPoint(x: 10, y: 10)))
        try expectNil(noVideo.sample(atView: CGPoint(x: 10, y: 10), clamp: true))
        try expectEqual(noVideo.clampedNormalized(fromView: CGPoint(x: 10, y: 10)), .zero)
        try expectEqual(noVideo.viewPoint(fromNormalized: CGPoint(x: 0.5, y: 0.5)), .zero)

        let noWindow = RemoteDisplayGeometry(remoteSize: CGSize(width: 1600, height: 900), viewSize: .zero)
        try expectFalse(noWindow.isValid)
        try expectNil(noWindow.normalized(fromView: .zero))
    },

    TestCase("only an in-progress gesture clamps outside the video") {
        try expectFalse(PointerEventKind.move.clampsOutsideVideo)
        try expectFalse(PointerEventKind.down.clampsOutsideVideo, "a click on a black bar is not a remote click")
        try expect(PointerEventKind.drag.clampsOutsideVideo, "a drag must continue along the edge")
        try expect(PointerEventKind.up.clampsOutsideVideo, "the button must be released even outside")
        try expect(PointerEventKind.scroll.clampsOutsideVideo)
    },
])

public let qualitySuite = TestSuite("Quality", [

    TestCase("the UI's three labels map onto the protocol's three strategies") {
        try expectEqual(QualityMode.best.wireMode, .sharp)
        try expectEqual(QualityMode.balanced.wireMode, .auto)
        try expectEqual(QualityMode.lowBandwidth.wireMode, .smooth)
    },

    TestCase("an unknown wire mode degrades to auto instead of failing the session") {
        try expectEqual(QualityWireMode(wire: "sharp"), .sharp)
        try expectEqual(QualityWireMode(wire: "SMOOTH"), .smooth)
        try expectEqual(QualityWireMode(wire: "turbo"), .auto)
        try expectEqual(QualityWireMode(wire: ""), .auto)
    },

    TestCase("sharp caps the long edge at 2560, never native 5K") {
        let profile = QualityProfile.profile(for: .sharp, displayWidth: 3024, displayHeight: 1964)
        try expectClose(profile.scaleResolutionDownBy, 3024.0 / 2560.0, tolerance: 1e-12)
        try expectEqual(profile.encodeWidth, 2560)
        try expectEqual(profile.encodeHeight, 1662)
        try expectEqual(profile.maxFramerate, 30)
    },

    TestCase("auto caps the long edge at 1920 and keeps the aspect ratio") {
        let profile = QualityProfile.profile(for: .auto, displayWidth: 3024, displayHeight: 1964)
        try expectClose(profile.scaleResolutionDownBy, 3024.0 / 1920.0, tolerance: 1e-12)
        try expectEqual(profile.encodeWidth, 1920)
        try expectEqual(profile.encodeHeight, 1246)
        try expectClose(Double(profile.encodeWidth) / Double(profile.encodeHeight),
                        3024.0 / 1964.0, tolerance: 0.002)
    },

    TestCase("smooth caps the long edge at 1280") {
        let profile = QualityProfile.profile(for: .smooth, displayWidth: 3024, displayHeight: 1964)
        try expectClose(profile.scaleResolutionDownBy, 3024.0 / 1280.0, tolerance: 1e-12)
        try expectEqual(profile.encodeWidth, 1280)
        try expectEqual(profile.encodeHeight, 832)
    },

    TestCase("a display already below the cap is never upscaled") {
        for mode in QualityWireMode.allCases {
            let profile = QualityProfile.profile(for: mode, displayWidth: 1280, displayHeight: 800)
            try expectEqual(profile.scaleResolutionDownBy, 1.0, "\(mode) must not upscale")
            try expectEqual(profile.encodeWidth, 1280)
            try expectEqual(profile.encodeHeight, 800)
        }
    },

    TestCase("every mode keeps the 8 Mbps burst ceiling (PLAN.md §5)") {
        for mode in QualityWireMode.allCases {
            let profile = QualityProfile.profile(for: mode, displayWidth: 3024, displayHeight: 1964)
            try expectEqual(profile.maxBitrateBps, 8_000_000,
                            "\(mode) must not hard-cap below the burst; BWE picks the steady rate")
            try expectEqual(profile.minBitrateBps, 400_000)
        }
    },

    TestCase("encode dimensions are always even (H.264 4:2:0)") {
        let odd = QualityProfile.profile(for: .sharp, displayWidth: 1365, displayHeight: 767)
        try expectEqual(odd.encodeWidth % 2, 0)
        try expectEqual(odd.encodeHeight % 2, 0)
        let scaled = QualityProfile.profile(for: .smooth, displayWidth: 2049, displayHeight: 1153)
        try expectEqual(scaled.encodeWidth % 2, 0)
        try expectEqual(scaled.encodeHeight % 2, 0)
    },

    TestCase("a zero-sized display produces a safe profile rather than a divide by zero") {
        let profile = QualityProfile.profile(for: .auto, displayWidth: 0, displayHeight: 0)
        try expectEqual(profile.encodeWidth, 0)
        try expectEqual(profile.scaleResolutionDownBy, 1.0)
        try expectEqual(profile.maxBitrateBps, 8_000_000)
    },

    TestCase("the adaptive frame rate drops to 5 fps idle and 1 fps deep idle") {
        let policy = AdaptiveFrameRatePolicy()
        try expectEqual(policy.targetFPS(secondsSinceLastFrame: 0), 30)
        try expectEqual(policy.targetFPS(secondsSinceLastFrame: 1.999), 30)
        try expectEqual(policy.targetFPS(secondsSinceLastFrame: 2.0), 5)
        try expectEqual(policy.targetFPS(secondsSinceLastFrame: 9.999), 5)
        try expectEqual(policy.targetFPS(secondsSinceLastFrame: 10.0), 1)
        try expectEqual(policy.targetFPS(secondsSinceLastFrame: 600), 1)
    },

    TestCase("the stream is only reconfigured when the target actually changes") {
        let policy = AdaptiveFrameRatePolicy()
        try expectFalse(policy.shouldReconfigure(currentFPS: 30, secondsSinceLastFrame: 0.5))
        try expect(policy.shouldReconfigure(currentFPS: 30, secondsSinceLastFrame: 3))
        try expectFalse(policy.shouldReconfigure(currentFPS: 5, secondsSinceLastFrame: 3))
        try expect(policy.shouldReconfigure(currentFPS: 5, secondsSinceLastFrame: 20))
        try expect(policy.shouldReconfigure(currentFPS: 1, secondsSinceLastFrame: 0),
                   "the first frame after an idle period must restore full rate")
    },
])

public let mediaProtocolSuite = TestSuite("MediaProtocol", [

    TestCase("display_info round-trips through the ctrl envelope") {
        let sent = DisplayInfoPayload(w: 3024, h: 1964, scale: 2.0)
        let data = try Envelope.encode(type: CtrlType.displayInfo, payload: sent)
        let envelope = try Envelope.decode(data)
        try expectEqual(envelope.type, "display_info")
        try expectEqual(envelope.v, 2)
        let decoded = try envelope.decodePayload(DisplayInfoPayload.self)
        try expectEqual(decoded, sent)
        try expectEqual(decoded.w, 3024)
        try expectEqual(decoded.h, 1964)
        try expectClose(decoded.scale, 2.0)
    },

    TestCase("display_info keeps a non-integer backing scale") {
        let sent = DisplayInfoPayload(w: 1512, h: 982, scale: 1.5)
        let decoded = try Envelope.decode(try Envelope.encode(type: CtrlType.displayInfo, payload: sent))
            .decodePayload(DisplayInfoPayload.self)
        try expectClose(decoded.scale, 1.5)
        try expectEqual(decoded, sent)
    },

    TestCase("display_info survives unknown fields from a newer peer") {
        let json = Data("""
        {"v":2,"type":"display_info","ts":1755600000000,
         "payload":{"w":2560,"h":1600,"scale":2,"hdr":true,"refreshHz":120}}
        """.utf8)
        let decoded = try Envelope.decode(json).decodePayload(DisplayInfoPayload.self)
        try expectEqual(decoded, DisplayInfoPayload(w: 2560, h: 1600, scale: 2))
    },

    TestCase("quality round-trips and carries the wire strategy") {
        for mode in QualityWireMode.allCases {
            let data = try Envelope.encode(type: CtrlType.quality, payload: QualityPayload(mode))
            let envelope = try Envelope.decode(data)
            try expectEqual(envelope.type, "quality")
            let decoded = try envelope.decodePayload(QualityPayload.self)
            try expectEqual(decoded.mode, mode.rawValue)
            try expectEqual(decoded.wireMode, mode)
        }
    },

    TestCase("an unrecognised quality mode from the wire is treated as auto") {
        let json = Data("""
        {"v":2,"type":"quality","payload":{"mode":"cinema"}}
        """.utf8)
        let decoded = try Envelope.decode(json).decodePayload(QualityPayload.self)
        try expectEqual(decoded.wireMode, .auto)
    },
])

public let videoStatsSuite = TestSuite("VideoStatistics", [

    TestCase("inbound and outbound video stats are picked out, audio is ignored") {
        let stats = VideoStatistics.parse([
            (type: "inbound-rtp", values: ["kind": "audio", "framesDecoded": NSNumber(value: 999)]),
            (type: "inbound-rtp", values: [
                "kind": "video",
                "framesDecoded": NSNumber(value: 412),
                "framesReceived": NSNumber(value: 420),
                "bytesReceived": NSNumber(value: 1_500_000),
                "framesPerSecond": NSNumber(value: 28.5),
                "frameWidth": NSNumber(value: 2560),
                "frameHeight": NSNumber(value: 1662),
                "decoderImplementation": "VideoToolbox",
            ]),
            (type: "candidate-pair", values: ["nominated": NSNumber(value: true)]),
        ])
        try expectEqual(stats.framesDecoded, 412)
        try expectEqual(stats.framesReceived, 420)
        try expectEqual(stats.bytesReceived, 1_500_000)
        try expectClose(stats.framesPerSecond, 28.5)
        try expectEqual(stats.frameWidth, 2560)
        try expectEqual(stats.frameHeight, 1662)
        try expectEqual(stats.decoderImplementation, "VideoToolbox")
        try expectEqual(stats.framesEncoded, 0, "an inbound-only report must not invent encoded frames")
    },

    TestCase("outbound stats report the encoder implementation") {
        let stats = VideoStatistics.parse([
            (type: "outbound-rtp", values: [
                "kind": "video",
                "framesEncoded": NSNumber(value: 300),
                "framesSent": NSNumber(value: 298),
                "bytesSent": NSNumber(value: 900_000),
                "encoderImplementation": "VideoToolbox",
            ]),
        ])
        try expectEqual(stats.framesEncoded, 300)
        try expectEqual(stats.framesSent, 298)
        try expectEqual(stats.bytesSent, 900_000)
        try expectEqual(stats.encoderImplementation, "VideoToolbox")
    },

    TestCase("bitrate and frame rate are computed from the delta between samples") {
        var earlier = VideoStatistics()
        earlier.bytesReceived = 100_000
        earlier.framesDecoded = 100
        earlier.bytesSent = 50_000
        earlier.framesEncoded = 90
        var later = VideoStatistics()
        later.bytesReceived = 350_000
        later.framesDecoded = 160
        later.bytesSent = 300_000
        later.framesEncoded = 120

        try expectClose(VideoStatistics.bitrate(from: earlier, to: later, seconds: 2, direction: .inbound),
                        1_000_000)
        try expectClose(VideoStatistics.measuredFPS(from: earlier, to: later, seconds: 2, direction: .inbound),
                        30)
        try expectClose(VideoStatistics.bitrate(from: earlier, to: later, seconds: 2, direction: .outbound),
                        1_000_000)
        try expectClose(VideoStatistics.measuredFPS(from: earlier, to: later, seconds: 2, direction: .outbound),
                        15)
    },

    TestCase("a counter that went backwards (a reconnect) reports zero, never a negative rate") {
        var earlier = VideoStatistics(); earlier.bytesReceived = 500_000; earlier.framesDecoded = 400
        var later = VideoStatistics(); later.bytesReceived = 1_000; later.framesDecoded = 2
        try expectClose(VideoStatistics.bitrate(from: earlier, to: later, seconds: 1, direction: .inbound), 0)
        try expectClose(VideoStatistics.measuredFPS(from: earlier, to: later, seconds: 1, direction: .inbound), 0)
        try expectClose(VideoStatistics.bitrate(from: earlier, to: later, seconds: 0, direction: .inbound), 0)
    },

    TestCase("capture state names the permission problem specifically") {
        let denied = CaptureState.failed(.screenRecordingDenied)
        try expect(denied.needsScreenRecordingPermission)
        try expectFalse(denied.isRunning)
        let message = try expectNotNil(denied.message)
        try expect(message.contains("Screen Recording"), "the message must name the permission: \(message)")

        let other = CaptureState.failed(.streamStopped("display asleep"))
        try expectFalse(other.needsScreenRecordingPermission,
                        "an unrelated failure must not send the user to the privacy pane")
        try expect(CaptureState.running(width: 3024, height: 1964, fps: 30).isRunning)
        try expectNil(CaptureState.idle.message)
    },

    TestCase("the synthetic frame source is opt-in and never selected by accident") {
        try expectEqual(CaptureSourceKind.fromEnvironment([:]), .screen)
        try expectEqual(CaptureSourceKind.fromEnvironment(["RC_CAPTURE_SOURCE": "screen"]), .screen)
        try expectEqual(CaptureSourceKind.fromEnvironment(["RC_CAPTURE_SOURCE": "synthetic"]), .synthetic)
        try expectEqual(CaptureSourceKind.fromEnvironment(["RC_CAPTURE_SOURCE": "nonsense"]), .screen)
    },
])
