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

    public static func requireSecureSource(_ raw: String) throws -> URL {
        guard let url = URL(string: raw), let host = url.host, url.user == nil else {
            throw UpdateRefusal.insecureSource(raw)
        }
        switch url.scheme {
        case "https":
            return url
        case "http" where ["localhost", "127.0.0.1", "::1"].contains(host):
            return url
        default:
            throw UpdateRefusal.insecureSource(raw)
        }
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
        runningSatisfies: (String) -> Bool
    ) -> UpdateAvailability {
        guard isAppBundle, let requirement = try? UpdateTrust.designatedRequirement(teamID: teamID),
              runningSatisfies(requirement) else {
            return .disabledInDevelopment
        }
        return .enabled(requirement: requirement)
    }

    public static func current() -> UpdateAvailability {
        resolve(
            teamID: RunningAppSignature.teamIdentifier(),
            isAppBundle: Bundle.main.bundleURL.pathExtension == "app",
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

    public static func verifySignature(ofAppAt app: URL, requirement text: String) throws {
        let code = try staticCode(at: app)
        let status = SecStaticCodeCheckValidity(code, strictFlags, try requirement(text))
        guard status == errSecSuccess else { throw UpdateRefusal.signatureInvalid(status) }
    }

    // TODO: verify on a Developer-ID-signed build that a signed but un-notarized app is refused here.
    public static func verifyNotarized(appAt app: URL) throws {
        let code: SecStaticCode
        let notarized: SecRequirement
        do {
            code = try staticCode(at: app)
            notarized = try requirement(UpdateTrust.notarizationRequirement)
        } catch UpdateRefusal.signatureInvalid(let status) {
            throw UpdateRefusal.notNotarized(status)
        }
        let status = SecStaticCodeCheckValidity(code, strictFlags, notarized)
        guard status == errSecSuccess else { throw UpdateRefusal.notNotarized(status) }
    }

    public static func verifyBundle(appAt app: URL, newerThan running: BuildNumber) throws -> (version: String, build: BuildNumber) {
        let plist = app.appendingPathComponent("Contents/Info.plist")
        guard let data = try? Data(contentsOf: plist),
              let info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        else {
            throw UpdateRefusal.wrongBundleIdentifier(nil)
        }
        let identifier = info["CFBundleIdentifier"] as? String
        guard identifier == UpdateTrust.bundleIdentifier else {
            throw UpdateRefusal.wrongBundleIdentifier(identifier)
        }
        let build = try UpdateTrust.requireNewer(candidate: info["CFBundleVersion"] as? String, running: running)
        return ((info["CFBundleShortVersionString"] as? String) ?? build.description, build)
    }

    // TODO: verify on a Developer-ID-signed build: signature and notarization cannot pass on a local build.
    public static func verifyApp(at app: URL, requirement: String, newerThan running: BuildNumber) throws -> (version: String, build: BuildNumber) {
        try verifySignature(ofAppAt: app, requirement: requirement)
        try verifyNotarized(appAt: app)
        return try verifyBundle(appAt: app, newerThan: running)
    }
}
