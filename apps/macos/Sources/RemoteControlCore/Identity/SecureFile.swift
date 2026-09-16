import Foundation

public enum SecureFile {

    public static let fileMode: Int16 = 0o600
    public static let directoryMode: Int16 = 0o700

    // MARK: - Errors

    public enum Error: Swift.Error, LocalizedError {
        case directoryUnavailable(path: String, underlying: String)
        case writeFailed(path: String, underlying: String)
        case renameFailed(path: String, errno: Int32)
        case readFailed(path: String, underlying: String)

        public var errorDescription: String? {
            switch self {
            case .directoryUnavailable(let path, let underlying):
                return "Could not create or secure \(path): \(underlying)"
            case .writeFailed(let path, let underlying):
                return "Could not write \(path): \(underlying)"
            case .renameFailed(let path, let code):
                return "Could not atomically replace \(path) (errno \(code): \(String(cString: strerror(code))))"
            case .readFailed(let path, let underlying):
                return "Could not read \(path): \(underlying)"
            }
        }
    }

    // MARK: - Directory

    @discardableResult
    public static func ensureDirectory(_ url: URL) throws -> Bool {
        let fm = FileManager.default
        var isDirectory: ObjCBool = false
        let exists = fm.fileExists(atPath: url.path, isDirectory: &isDirectory)
        do {
            if !exists {
                try fm.createDirectory(
                    at: url,
                    withIntermediateDirectories: true,
                    attributes: [.posixPermissions: NSNumber(value: directoryMode)]
                )
                return true
            }
            guard isDirectory.boolValue else {
                throw Error.directoryUnavailable(path: url.path, underlying: "a file already exists at that path")
            }
            if try currentMode(of: url) != directoryMode {
                try fm.setAttributes([.posixPermissions: NSNumber(value: directoryMode)], ofItemAtPath: url.path)
            }
            return false
        } catch let error as Error {
            throw error
        } catch {
            throw Error.directoryUnavailable(path: url.path, underlying: error.localizedDescription)
        }
    }

    // MARK: - Mode inspection

    public static func currentMode(of url: URL) throws -> Int16 {
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            let number = attributes[.posixPermissions] as? NSNumber ?? 0
            return Int16(number.int16Value & 0o777)
        } catch {
            throw Error.readFailed(path: url.path, underlying: error.localizedDescription)
        }
    }

    @discardableResult
    public static func tightenIfNeeded(_ url: URL) throws -> String? {
        let mode = try currentMode(of: url)
        guard mode != fileMode else { return nil }
        do {
            try FileManager.default.setAttributes(
                [.posixPermissions: NSNumber(value: fileMode)],
                ofItemAtPath: url.path
            )
        } catch {
            throw Error.writeFailed(path: url.path, underlying: error.localizedDescription)
        }
        return String(
            format: "%@ had permissions %04o (more permissive than 0600) and has been tightened to 0600.",
            url.lastPathComponent, Int(mode)
        )
    }

    // MARK: - Atomic write

    public static func writeAtomically(
        _ data: Data,
        to url: URL,
        beforeRename: (() throws -> Void)? = nil
    ) throws {
        let directory = url.deletingLastPathComponent()
        try ensureDirectory(directory)

        let temp = directory.appendingPathComponent(".\(url.lastPathComponent).tmp-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: temp) }

        let fd = temp.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { return -1 }
            return open(path, O_WRONLY | O_CREAT | O_EXCL, mode_t(fileMode))
        }
        guard fd >= 0 else {
            throw Error.writeFailed(path: temp.path, underlying: String(cString: strerror(errno)))
        }

        var closed = false
        func closeOnce() { if !closed { close(fd); closed = true } }
        defer { closeOnce() }

        try data.withUnsafeBytes { raw in
            var offset = 0
            let base = raw.bindMemory(to: UInt8.self).baseAddress
            while offset < raw.count {
                let written = write(fd, base! + offset, raw.count - offset)
                if written < 0 {
                    if errno == EINTR { continue }
                    throw Error.writeFailed(path: temp.path, underlying: String(cString: strerror(errno)))
                }
                offset += written
            }
        }

        guard fsync(fd) == 0 else {
            throw Error.writeFailed(path: temp.path, underlying: "fsync: \(String(cString: strerror(errno)))")
        }
        closeOnce()

        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: fileMode)],
            ofItemAtPath: temp.path
        )

        try beforeRename?()

        let renamed = temp.withUnsafeFileSystemRepresentation { from -> Int32 in
            url.withUnsafeFileSystemRepresentation { to -> Int32 in
                guard let from, let to else { return -1 }
                return rename(from, to)
            }
        }
        guard renamed == 0 else {
            throw Error.renameFailed(path: url.path, errno: errno)
        }
    }

    // MARK: - Read

    public static func read(_ url: URL) throws -> (data: Data, warning: String?)? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let warning = try tightenIfNeeded(url)
        do {
            return (try Data(contentsOf: url), warning)
        } catch {
            throw Error.readFailed(path: url.path, underlying: error.localizedDescription)
        }
    }

    @discardableResult
    public static func remove(_ url: URL) throws -> Bool {
        guard FileManager.default.fileExists(atPath: url.path) else { return false }
        do {
            try FileManager.default.removeItem(at: url)
            return true
        } catch {
            throw Error.writeFailed(path: url.path, underlying: error.localizedDescription)
        }
    }
}
