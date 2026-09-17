import Foundation

public enum RCLog {
    public static let enabled = DevelopmentHooks.diagnosticsRequested

    private static let logFileHandle: FileHandle? = {
        guard enabled,
              let path = DevelopmentHooks.value(.logFile) else { return nil }
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

    public static func info(_ message: @autoclosure () -> String) {
        debug("INFO \(message())")
    }

    public static func error(_ message: @autoclosure () -> String) {
        debug("ERROR \(message())")
    }
}
