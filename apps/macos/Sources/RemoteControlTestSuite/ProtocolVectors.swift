import Foundation

/// A file in the repository's `protocol/vectors/`, the cross-language contract every
/// implementation reads.
func protocolVectorURL(_ name: String) -> URL {
    URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("protocol/vectors")
        .appendingPathComponent(name)
}
