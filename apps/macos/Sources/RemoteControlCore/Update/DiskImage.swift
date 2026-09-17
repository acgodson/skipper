import Foundation

struct MountedDiskImage {

    let mountPoint: URL

    private static let hdiutil = URL(fileURLWithPath: "/usr/bin/hdiutil")

    static func attach(_ image: URL, under root: URL) throws -> MountedDiskImage {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let output = try run([
            "attach", image.path, "-nobrowse", "-readonly", "-noautoopen", "-plist", "-mountroot", root.path,
        ])
        guard let plist = try? PropertyListSerialization.propertyList(from: output, format: nil) as? [String: Any],
              let entities = plist["system-entities"] as? [[String: Any]],
              let mountPath = entities.compactMap({ $0["mount-point"] as? String }).first
        else { throw UpdateRefusal.imageUnusable("hdiutil reported no mount point") }
        let mountPoint = URL(fileURLWithPath: mountPath, isDirectory: true)
        guard mountPoint.standardizedFileURL.path.hasPrefix(root.standardizedFileURL.path + "/") else {
            _ = try? run(["detach", mountPath, "-force"])
            throw UpdateRefusal.imageUnusable("mounted outside the requested root")
        }
        return MountedDiskImage(mountPoint: mountPoint)
    }

    func detach() {
        _ = try? Self.run(["detach", mountPoint.path, "-force"])
    }

    func bundledApp() throws -> URL {
        let app = mountPoint.appendingPathComponent(UpdateTrust.appName, isDirectory: true)
        let values = try? app.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey])
        guard values?.isDirectory == true, values?.isSymbolicLink == false else {
            throw UpdateRefusal.appMissingFromImage
        }
        return app
    }

    private static func run(_ arguments: [String]) throws -> Data {
        let process = Process()
        process.executableURL = hdiutil
        process.arguments = arguments
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        try process.run()
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw UpdateRefusal.imageUnusable("hdiutil \(arguments.first ?? "") exited \(process.terminationStatus)")
        }
        return data
    }
}
