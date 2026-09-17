import CSkipperCore
import Foundation

public struct SkipperCoreError: Error, CustomStringConvertible, LocalizedError {
    public let message: String
    public let kind: String?

    public init(_ message: String, kind: String? = nil) {
        self.message = message
        self.kind = kind
    }

    public var isAuthenticationFailure: Bool { kind == "authentication" }

    public var description: String { message }
    public var errorDescription: String? { message }
}

private struct CoreEnvelope: Decodable {
    let ok: Bool
    let error: String?
    let kind: String?
}

/// One argument as the core receives it: a pointer and a length, never a C string.
struct CoreBytes {
    let base: UnsafePointer<UInt8>?
    let count: Int
}

enum CoreBoundary {
    static func call<Result: Decodable>(_ body: () -> UnsafeMutablePointer<CChar>?) throws -> Result {
        guard let raw = body() else {
            throw SkipperCoreError("the shared core could not allocate a result")
        }
        defer { skipper_string_free(raw) }
        let data = Data(bytes: raw, count: strlen(raw))
        if let envelope = try? JSONDecoder().decode(CoreEnvelope.self, from: data), !envelope.ok {
            throw SkipperCoreError(envelope.error ?? "the shared core rejected the call", kind: envelope.kind)
        }
        do {
            return try JSONDecoder().decode(Result.self, from: data)
        } catch {
            throw SkipperCoreError("the shared core returned an undecodable result: \(error)")
        }
    }

    /// A present value always gets a non-null pointer, even when empty, so the
    /// core can tell "" from nil.
    static func withBytes<R>(_ values: [Data?], _ body: ([CoreBytes]) -> R) -> R {
        let buffers = values.map { value -> UnsafeMutableBufferPointer<UInt8>? in
            guard let value else { return nil }
            let buffer = UnsafeMutableBufferPointer<UInt8>.allocate(capacity: max(value.count, 1))
            _ = buffer.initialize(from: value)
            return buffer
        }
        defer { buffers.forEach { $0?.deallocate() } }
        let arguments = zip(values, buffers).map { value, buffer in
            CoreBytes(base: buffer.map { UnsafePointer($0.baseAddress!) }, count: value?.count ?? 0)
        }
        return body(arguments)
    }

    static func withText<R>(_ values: [String?], _ body: ([CoreBytes]) -> R) -> R {
        withBytes(values.map { $0.map { Data($0.utf8) } }, body)
    }
}
