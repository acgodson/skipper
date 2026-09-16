import Foundation

/// Low-level owner-only file primitives shared by every on-disk secret.
///
/// WHY THIS EXISTS: the app used to keep the device key and access code in the
/// macOS Keychain. Because this build is ad-hoc signed, its code signature — and
/// therefore its Keychain ACL identity — changes on every rebuild, so macOS
/// prompted the user for permission again and again. There is no Apple Developer
/// account, so neither the Secure Enclave nor a stable signing identity is
/// available. AnyDesk and RustDesk store their device identity in a plain
/// owner-only file for exactly the same reason, and that is what we do here.
///
/// What this actually buys us, stated honestly:
///   * `0600` on the file and `0700` on the directory — no other user account on
///     this Mac can read it, and no unprivileged process running as another user can.
///   * FileVault protects it at rest when the disk is locked.
///   * It does NOT protect against a process already running as this user, and it
///     is NOT hardware-backed. The UI must not claim otherwise.
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

    /// Creates `url` if absent and forces its mode to 0700 either way.
    ///
    /// The mode is re-applied on every call rather than only at creation: a
    /// directory that was created before this code existed, restored from a
    /// backup, or copied with a permissive umask must still end up at 0700.
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

    /// The permission bits of `url`, masked to 0777.
    public static func currentMode(of url: URL) throws -> Int16 {
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            let number = attributes[.posixPermissions] as? NSNumber ?? 0
            return Int16(number.int16Value & 0o777)
        } catch {
            throw Error.readFailed(path: url.path, underlying: error.localizedDescription)
        }
    }

    /// Tightens `url` to 0600 if it is currently more permissive.
    ///
    /// Returns a human-readable warning when it had to act, and nil when the
    /// file was already correct. Callers surface the warning; they do not fail,
    /// because refusing to start over a fixable permission bit would leave the
    /// user with a dead app and no way forward.
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

    /// Writes `data` so that a crash can never be observed as a truncated or
    /// empty file.
    ///
    /// The sequence is: create a fresh temp file **in the same directory** (so
    /// the rename cannot cross a filesystem boundary), write it, `fsync` it so
    /// the bytes are on the platter before anything points at them, then
    /// `rename(2)` over the destination. `rename` within one filesystem is
    /// atomic: a reader sees either the entire old file or the entire new one.
    ///
    /// `beforeRename` is a test seam. Production passes nil. A test throws from
    /// it to prove that a failure after the temp file exists still leaves the
    /// previous identity fully intact.
    public static func writeAtomically(
        _ data: Data,
        to url: URL,
        beforeRename: (() throws -> Void)? = nil
    ) throws {
        let directory = url.deletingLastPathComponent()
        try ensureDirectory(directory)

        let temp = directory.appendingPathComponent(".\(url.lastPathComponent).tmp-\(UUID().uuidString)")
        // Clean the temp up on every exit path, success or failure. A leftover
        // temp file containing key material would be its own security problem.
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

        // Durability barrier. Without this the rename can land before the data
        // does, which is precisely the truncated-file case we are ruling out.
        guard fsync(fd) == 0 else {
            throw Error.writeFailed(path: temp.path, underlying: "fsync: \(String(cString: strerror(errno)))")
        }
        closeOnce()

        // O_EXCL created the file at 0600 already, but the process umask does not
        // apply to open(2) modes uniformly across filesystems, so make it explicit.
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

    /// Reads `url`, first tightening its permissions if they are too open.
    ///
    /// Returns nil when the file does not exist — that is "first launch", not an
    /// error. `warning` is non-nil only when the permissions had to be repaired.
    public static func read(_ url: URL) throws -> (data: Data, warning: String?)? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let warning = try tightenIfNeeded(url)
        do {
            return (try Data(contentsOf: url), warning)
        } catch {
            throw Error.readFailed(path: url.path, underlying: error.localizedDescription)
        }
    }

    /// Removes `url` if present. Returns whether something was actually there.
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
