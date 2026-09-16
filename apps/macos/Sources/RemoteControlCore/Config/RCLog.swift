import Foundation

/// Opt-in diagnostics on stderr, enabled with `RC_DEBUG=1`.
///
/// Never used for anything the protocol calls a secret: no access codes, no
/// session tokens, no SDP bodies, no candidates, no clipboard, no input.
/// PROTOCOL.md §8 binds the server; the client holds itself to the same line.
public enum RCLog {
    public static let enabled = ProcessInfo.processInfo.environment["RC_DEBUG"] == "1"

    /// When set, diagnostics are appended here as well as stderr.
    ///
    /// Needed because the app must be launched through LaunchServices (`open`)
    /// rather than by exec'ing the inner binary: macOS attributes a TCC grant to
    /// the *responsible process*, so a shell-launched binary inherits the
    /// terminal's (absent) Screen Recording permission. `open` detaches stdio,
    /// so a file is the only way a verification script can still read the log.
    private static let logFileHandle: FileHandle? = {
        guard enabled,
              let path = ProcessInfo.processInfo.environment["RC_LOG_FILE"],
              !path.isEmpty else { return nil }
        if !FileManager.default.fileExists(atPath: path) {
            FileManager.default.createFile(atPath: path, contents: nil)
        }
        let handle = FileHandle(forWritingAtPath: path)
        handle?.seekToEndOfFile()
        return handle
    }()

    public static func debug(_ message: @autoclosure () -> String) {
        guard enabled else { return }
        let line = Data("[rc] \(message())\n".utf8)
        FileHandle.standardError.write(line)
        if let logFileHandle {
            logFileHandle.write(line)
            try? logFileHandle.synchronize()
        }
    }

    /// Notable but expected lifecycle events (capture started, display changed).
    public static func info(_ message: @autoclosure () -> String) {
        debug("INFO \(message())")
    }

    /// A real failure. Still gated on `RC_DEBUG`, deliberately: `rc-node` folds
    /// stderr into the JSON event stream the integration scripts parse, and an
    /// unconditional line there would be noise in every run. Failures that
    /// matter reach the user through the UI, not through this.
    public static func error(_ message: @autoclosure () -> String) {
        debug("ERROR \(message())")
    }
}
