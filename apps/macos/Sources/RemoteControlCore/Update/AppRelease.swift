import Foundation

public struct AppRelease: Decodable, Equatable, Sendable {
    public let version: String
    public let build: String
    public let minimumOS: String
    public let url: String
    public let sha256: String
    public let size: Int64
    public let notes: String?
    public let publishedAt: Int64
    public let critical: Bool

    public init(
        version: String, build: String, minimumOS: String, url: String, sha256: String,
        size: Int64, notes: String? = nil, publishedAt: Int64 = 0, critical: Bool = false
    ) {
        self.version = version
        self.build = build
        self.minimumOS = minimumOS
        self.url = url
        self.sha256 = sha256
        self.size = size
        self.notes = notes
        self.publishedAt = publishedAt
        self.critical = critical
    }
}

public struct ReleaseTrack: Equatable, Sendable {
    public let platform: String
    public let arch: String
    public let channel: String

    public init(platform: String = "macos", arch: String = ReleaseTrack.runningArch, channel: String = "stable") {
        self.platform = platform
        self.arch = arch
        self.channel = channel
    }

    public static var runningArch: String {
        #if arch(arm64)
        return "arm64"
        #else
        return "x86_64"
        #endif
    }

    public var queryItems: [URLQueryItem] {
        [
            URLQueryItem(name: "platform", value: platform),
            URLQueryItem(name: "arch", value: arch),
            URLQueryItem(name: "channel", value: channel),
        ]
    }
}

public struct StagedUpdate: Equatable, Sendable {
    public let sealed: SealedBundle
    public let critical: Bool

    public var appURL: URL { sealed.url }
    public var version: String { sealed.version }
    public var build: BuildNumber { sealed.build }

    public static func == (lhs: StagedUpdate, rhs: StagedUpdate) -> Bool {
        lhs.sealed === rhs.sealed && lhs.critical == rhs.critical
    }
}

public enum UpdateRefusal: Error, Equatable, CustomStringConvertible {
    case noTeamIdentifier
    case invalidTeamIdentifier
    case notAnAppBundle
    case insecureSource(String)
    case malformedRelease(String)
    case tooLarge(expected: Int64)
    case sizeMismatch(expected: Int64, actual: Int64)
    case digestMismatch
    case imageUnusable(String)
    case appMissingFromImage
    case signatureInvalid(OSStatus)
    case notNotarized(OSStatus)
    case wrongBundleIdentifier(String?)
    case notNewer(candidate: String?, running: String)
    case installFailed(String)
    case exceedsSizeCap(Int64)
    case unsafeWorkDirectory(String)
    case installedCopyRejected(String)

    public var description: String {
        switch self {
        case .noTeamIdentifier: return "the running app has no Team ID"
        case .invalidTeamIdentifier: return "the running app's Team ID is malformed"
        case .notAnAppBundle: return "the running code is not an .app bundle"
        case .insecureSource(let url): return "download URL is not https: \(url)"
        case .malformedRelease(let why): return "release is malformed: \(why)"
        case .tooLarge(let expected): return "download exceeded the announced \(expected) bytes"
        case .sizeMismatch(let expected, let actual): return "size \(actual), announced \(expected)"
        case .digestMismatch: return "sha256 does not match the announced digest"
        case .imageUnusable(let why): return "disk image unusable: \(why)"
        case .appMissingFromImage: return "the disk image holds no SkipperDesk.app"
        case .signatureInvalid(let status): return "code signature does not satisfy the pinned requirement (\(status))"
        case .notNotarized(let status): return "app is not notarized (\(status))"
        case .wrongBundleIdentifier(let id): return "bundle identifier is \(id ?? "missing")"
        case .notNewer(let candidate, let running): return "build \(candidate ?? "missing") is not newer than \(running)"
        case .installFailed(let why): return "install failed: \(why)"
        case .exceedsSizeCap(let size): return "announced size \(size) exceeds the \(UpdateTrust.maximumDownloadBytes)-byte cap"
        case .unsafeWorkDirectory(let path): return "update work directory is not private: \(path)"
        case .installedCopyRejected(let why): return "installed copy failed re-verification and was rolled back: \(why)"
        }
    }
}
