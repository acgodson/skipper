import CSkipperCore
import Foundation

/// A call into the shared core came back `{"ok": false}`, or could not be read
/// at all. Every message is the core's own wording.
public struct SkipperCoreError: Error, CustomStringConvertible, LocalizedError {
    public let message: String

    public init(_ message: String) {
        self.message = message
    }

    public var description: String { message }
    public var errorDescription: String? { message }
}

private struct CoreEnvelope: Decodable {
    let ok: Bool
    let error: String?
}

/// The one place that turns a `char *` JSON result from `skipper_core.h` into a
/// Swift value or a thrown error, and frees it either way.
enum CoreBoundary {
    static func call<Result: Decodable>(_ body: () -> UnsafeMutablePointer<CChar>?) throws -> Result {
        guard let raw = body() else {
            throw SkipperCoreError("the shared core could not allocate a result")
        }
        defer { skipper_string_free(raw) }
        let data = Data(bytes: raw, count: strlen(raw))
        if let envelope = try? JSONDecoder().decode(CoreEnvelope.self, from: data), !envelope.ok {
            throw SkipperCoreError(envelope.error ?? "the shared core rejected the call")
        }
        do {
            return try JSONDecoder().decode(Result.self, from: data)
        } catch {
            throw SkipperCoreError("the shared core returned an undecodable result: \(error)")
        }
    }
}
