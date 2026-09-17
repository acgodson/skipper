import CryptoKit
import Foundation
import Security

// Update trust model (docs/SECURITY.md "Updates"): the release feed says WHAT to
// install; only the checks in this file decide that it is SAFE.
public enum UpdateTrust {

    public static let bundleIdentifier = "app.skipperdesk.desktop"
    public static let appName = "SkipperDesk.app"
    public static let notarizationRequirement = "anchor apple generic and notarized"

    public static func designatedRequirement(teamID: String?) throws -> String {
        guard let teamID, !teamID.isEmpty else { throw UpdateRefusal.noTeamIdentifier }
        guard teamID.count == 10,
              teamID.unicodeScalars.allSatisfy({ ("A"..."Z").contains($0) || ("0"..."9").contains($0) })
        else { throw UpdateRefusal.invalidTeamIdentifier }
        return "anchor apple generic"
            + " and identifier \"\(bundleIdentifier)\""
            + " and certificate 1[field.1.2.840.113635.100.6.2.6] exists"
            + " and certificate leaf[field.1.2.840.113635.100.6.1.13] exists"
            + " and certificate leaf[subject.OU] = \"\(teamID)\""
    }

    public static let maximumDownloadBytes: Int64 = 512 * 1024 * 1024

    public static func requireSecureSource(
        _ raw: String, allowLoopback: Bool = DevelopmentHooks.areCompiledIn
    ) throws -> URL {
        guard let url = URL(string: raw), let host = url.host, !host.isEmpty, url.user == nil else {
            throw UpdateRefusal.insecureSource(raw)
        }
        switch url.scheme?.lowercased() {
        case "https":
            return url
        case "http" where allowLoopback && ["localhost", "127.0.0.1", "::1"].contains(host):
            return url
        default:
            throw UpdateRefusal.insecureSource(raw)
        }
    }

    public static func requireAcceptableSize(_ size: Int64) throws {
        guard size > 0 else { throw UpdateRefusal.malformedRelease("size") }
        guard size <= maximumDownloadBytes else { throw UpdateRefusal.exceedsSizeCap(size) }
    }

    public static func downloadLimit(announced size: Int64) -> Int64 {
        min(size, maximumDownloadBytes)
    }

    public static func requireNewer(candidate: String?, running: BuildNumber) throws -> BuildNumber {
        guard let candidate, let build = BuildNumber(candidate), build > running else {
            throw UpdateRefusal.notNewer(candidate: candidate, running: running.description)
        }
        return build
    }

    public static func isOffered(_ release: AppRelease, running: BuildNumber, os: BuildNumber) -> Bool {
        guard let build = BuildNumber(release.build), build > running else { return false }
        guard let minimum = BuildNumber(release.minimumOS) else { return false }
        return os >= minimum
    }
}

public enum UpdateAvailability: Equatable, Sendable {
    case enabled(requirement: String)
    case disabledInDevelopment

    public static let disabledSentence = "Updates are disabled in development builds."

    public static func resolve(
        teamID: String?,
        isAppBundle: Bool,
        hooksCompiledIn: Bool,
        runningSatisfies: (String) -> Bool
    ) -> UpdateAvailability {
        guard !hooksCompiledIn, isAppBundle, let requirement = try? UpdateTrust.designatedRequirement(teamID: teamID),
              runningSatisfies(requirement) else {
            return .disabledInDevelopment
        }
        return .enabled(requirement: requirement)
    }

    public static func current() -> UpdateAvailability {
        resolve(
            teamID: RunningAppSignature.teamIdentifier(),
            isAppBundle: Bundle.main.bundleURL.pathExtension == "app",
            hooksCompiledIn: DevelopmentHooks.areCompiledIn,
            runningSatisfies: RunningAppSignature.satisfies
        )
    }
}

public enum RunningAppSignature {

    private static func selfCode() -> SecCode? {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess else { return nil }
        return code
    }

    public static func teamIdentifier() -> String? {
        guard let code = selfCode() else { return nil }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return nil }
        var info: CFDictionary?
        let flags = SecCSFlags(rawValue: kSecCSSigningInformation)
        guard SecCodeCopySigningInformation(staticCode, flags, &info) == errSecSuccess,
              let dictionary = info as? [String: Any] else { return nil }
        return dictionary[kSecCodeInfoTeamIdentifier as String] as? String
    }

    public static func satisfies(_ requirementText: String) -> Bool {
        guard let code = selfCode(), let requirement = try? UpdateVerifier.requirement(requirementText) else {
            return false
        }
        return SecCodeCheckValidity(code, [], requirement) == errSecSuccess
    }
}

public struct UpdateSignaturePolicy: Sendable {
    let publisher: String
    let notarization: String?

    public init(requirement: String) {
        publisher = requirement
        notarization = UpdateTrust.notarizationRequirement
    }

#if DEBUG || SKIPPER_TEST_HOOKS
    public static func withoutNotarization(requirement: String) -> UpdateSignaturePolicy {
        UpdateSignaturePolicy(publisher: requirement, notarization: nil)
    }

    private init(publisher: String, notarization: String?) {
        self.publisher = publisher
        self.notarization = notarization
    }
#endif
}

public final class SealedBundle: @unchecked Sendable {
    public let url: URL
    public let version: String
    public let build: BuildNumber
    let code: SecStaticCode

    init(url: URL, version: String, build: BuildNumber, code: SecStaticCode) {
        self.url = url
        self.version = version
        self.build = build
        self.code = code
    }
}

public enum UpdateVerifier {

    static let strictFlags = SecCSFlags(rawValue:
        kSecCSCheckAllArchitectures
        | kSecCSStrictValidate
        | kSecCSCheckNestedCode
        | kSecCSRestrictSymlinks
        | kSecCSRestrictToAppLike)

    static func requirement(_ text: String) throws -> SecRequirement {
        var requirement: SecRequirement?
        let status = SecRequirementCreateWithString(text as CFString, [], &requirement)
        guard status == errSecSuccess, let requirement else { throw UpdateRefusal.signatureInvalid(status) }
        return requirement
    }

    public static func verifyDownload(at file: URL, sha256 expected: String, size: Int64) throws {
        let normalized = expected.lowercased()
        guard normalized.count == 64, normalized.unicodeScalars.allSatisfy({
            ("0"..."9").contains($0) || ("a"..."f").contains($0)
        }) else { throw UpdateRefusal.malformedRelease("sha256") }

        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        let actual = (attributes[.size] as? NSNumber)?.int64Value ?? -1
        guard actual == size else { throw UpdateRefusal.sizeMismatch(expected: size, actual: actual) }

        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        guard digest == normalized else { throw UpdateRefusal.digestMismatch }
    }

    private static func staticCode(at app: URL) throws -> SecStaticCode {
        var code: SecStaticCode?
        let status = SecStaticCodeCreateWithPath(app as CFURL, [], &code)
        guard status == errSecSuccess, let code else { throw UpdateRefusal.signatureInvalid(status) }
        return code
    }

    private static func checkPublisher(_ code: SecStaticCode, requirement text: String) throws {
        let status = SecStaticCodeCheckValidity(code, strictFlags, try requirement(text))
        guard status == errSecSuccess else { throw UpdateRefusal.signatureInvalid(status) }
    }

    private static func checkNotarized(_ code: SecStaticCode, requirement text: String) throws {
        let notarized: SecRequirement
        do {
            notarized = try requirement(text)
        } catch UpdateRefusal.signatureInvalid(let status) {
            throw UpdateRefusal.notNotarized(status)
        }
        let status = SecStaticCodeCheckValidity(code, strictFlags, notarized)
        guard status == errSecSuccess else { throw UpdateRefusal.notNotarized(status) }
    }

    public static func verifySignature(ofAppAt app: URL, requirement text: String) throws {
        try checkPublisher(try staticCode(at: app), requirement: text)
    }

    // TODO: verify on a Developer-ID-signed build that a signed but un-notarized app is refused here.
    public static func verifyNotarized(appAt app: URL) throws {
        let code: SecStaticCode
        do {
            code = try staticCode(at: app)
        } catch UpdateRefusal.signatureInvalid(let status) {
            throw UpdateRefusal.notNotarized(status)
        }
        try checkNotarized(code, requirement: UpdateTrust.notarizationRequirement)
    }

    static func identity(fromInfo info: [String: Any], newerThan floor: BuildNumber) throws -> (version: String, build: BuildNumber) {
        let identifier = info["CFBundleIdentifier"] as? String
        guard identifier == UpdateTrust.bundleIdentifier else {
            throw UpdateRefusal.wrongBundleIdentifier(identifier)
        }
        let build = try UpdateTrust.requireNewer(candidate: info["CFBundleVersion"] as? String, running: floor)
        return ((info["CFBundleShortVersionString"] as? String) ?? build.description, build)
    }

    private static func infoDictionary(atBundle app: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: app.appendingPathComponent("Contents/Info.plist")) else { return nil }
        return (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any]
    }

    public static func verifyBundle(appAt app: URL, newerThan floor: BuildNumber) throws -> (version: String, build: BuildNumber) {
        guard let info = infoDictionary(atBundle: app) else { throw UpdateRefusal.wrongBundleIdentifier(nil) }
        return try identity(fromInfo: info, newerThan: floor)
    }

    public static func installedBuild(at app: URL) -> BuildNumber? {
        guard let info = infoDictionary(atBundle: app),
              info["CFBundleIdentifier"] as? String == UpdateTrust.bundleIdentifier,
              let raw = info["CFBundleVersion"] as? String else { return nil }
        return BuildNumber(raw)
    }

    private static func sealedInfo(of code: SecStaticCode) throws -> [String: Any] {
        var information: CFDictionary?
        let status = SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &information)
        guard status == errSecSuccess,
              let dictionary = information as? [String: Any],
              let plist = dictionary[kSecCodeInfoPList as String] as? [String: Any]
        else { throw UpdateRefusal.wrongBundleIdentifier(nil) }
        return plist
    }

    private static func check(
        _ code: SecStaticCode, policy: UpdateSignaturePolicy, newerThan floor: BuildNumber
    ) throws -> (version: String, build: BuildNumber) {
        try checkPublisher(code, requirement: policy.publisher)
        if let notarization = policy.notarization {
            try checkNotarized(code, requirement: notarization)
        }
        return try identity(fromInfo: try sealedInfo(of: code), newerThan: floor)
    }

    public static func seal(appAt app: URL, policy: UpdateSignaturePolicy, newerThan floor: BuildNumber) throws -> SealedBundle {
        let code = try staticCode(at: app)
        let identity = try check(code, policy: policy, newerThan: floor)
        return SealedBundle(url: app, version: identity.version, build: identity.build, code: code)
    }

    public static func recheck(_ sealed: SealedBundle, policy: UpdateSignaturePolicy, newerThan floor: BuildNumber) throws {
        let identity = try check(sealed.code, policy: policy, newerThan: floor)
        guard identity.build == sealed.build else {
            throw UpdateRefusal.notNewer(candidate: identity.build.description, running: sealed.build.description)
        }
    }

    // TODO: verify on a Developer-ID-signed build: signature and notarization cannot pass on a local build.
    public static func verifyApp(at app: URL, requirement: String, newerThan floor: BuildNumber) throws -> (version: String, build: BuildNumber) {
        let sealed = try seal(appAt: app, policy: UpdateSignaturePolicy(requirement: requirement), newerThan: floor)
        return (sealed.version, sealed.build)
    }
}
