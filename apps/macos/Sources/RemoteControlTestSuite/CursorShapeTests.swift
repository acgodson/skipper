import CoreGraphics
import Foundation
import RCTestKit
import RemoteControlCore

private func wireVectorsURL() -> URL {
    protocolVectorURL("vectors.json")
}

private func cursorShapeFrames() throws -> [Data] {
    let file = try JSONSerialization.jsonObject(with: Data(contentsOf: wireVectorsURL())) as? [String: Any]
    let cases = try expectNotNil(file?["cases"] as? [[String: Any]], "vectors.json has no cases")
    return try cases
        .filter { $0["type"] as? String == CtrlType.cursorShape }
        .map { try JSONSerialization.data(withJSONObject: try expectNotNil($0["frame"])) }
}

public let cursorSuite = TestSuite("Cursor shapes (PROTOCOL.md §5 cursor_shape)", [

    TestCase("every cursor_shape vector round-trips and names a known shape") {
        let frames = try cursorShapeFrames()
        try expectEqual(frames.count, CursorShape.allCases.count, "one vector per shape")
        var seen = Set<CursorShape>()
        for frame in frames {
            let envelope = try Envelope.decode(frame)
            try expectEqual(envelope.type, CtrlType.cursorShape)
            let payload = try envelope.decodePayload(CursorShapePayload.self)
            let shape = try expectNotNil(CursorShape(rawValue: payload.shape),
                                         "vector shape \(payload.shape) is not a Swift case")
            seen.insert(shape)

            let reencoded = try Envelope.encode(type: CtrlType.cursorShape, ts: envelope.ts,
                                                payload: CursorShapePayload(shape))
            let original = try JSONSerialization.jsonObject(with: frame) as? NSDictionary
            let ours = try JSONSerialization.jsonObject(with: reencoded) as? NSDictionary
            try expectEqual(ours, original, "\(shape.rawValue) re-encodes to the same frame as the vector")
        }
        try expectEqual(seen, Set(CursorShape.allCases))
    },

    TestCase("an unknown shape is drawn as the arrow") {
        try expectEqual(CursorShapePayload(shape: "zoom_in").cursorShape, .arrow)
        try expectEqual(CursorShape(wire: ""), .arrow)
    },

    TestCase("every shape maps to its own drawable vector path around the hot spot") {
        var paths: [CGPath] = []
        for shape in CursorShape.allCases {
            let path = shape.path
            let box = path.boundingBoxOfPath
            try expectFalse(path.isEmpty, "\(shape.rawValue) has no path")
            try expect(box.width >= 6 && box.height >= 6, "\(shape.rawValue) is too small to see: \(box)")
            try expect(box.width <= 32 && box.height <= 32, "\(shape.rawValue) is larger than a cursor: \(box)")
            try expect(box.insetBy(dx: -0.5, dy: -0.5).contains(CGPoint.zero),
                       "\(shape.rawValue)'s hot spot lies outside its glyph: \(box)")
            try expectFalse(paths.contains { $0 == path }, "\(shape.rawValue) is drawn the same as another shape")
            paths.append(path)
        }
    },

    TestCase("the arrow keeps its tip on the pointer") {
        let box = CursorShape.arrow.path.boundingBoxOfPath
        try expectEqual(box.minX, 0)
        try expectEqual(box.minY, 0)
    },
])
