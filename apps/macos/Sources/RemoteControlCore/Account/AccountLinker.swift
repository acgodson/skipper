import Foundation
import AppKit
import IOKit
import SkipperCore

public enum AccountState: Equatable {
    case unlinked
    case linking
    case linked(accountLabel: String?, device: DeviceRecord)
    case error(message: String)

    public var isLinked: Bool {
        if case .linked = self { return true }
        return false
    }

    public var isLinking: Bool {
        if case .linking = self { return true }
        return false
    }
}

public enum LinkCallbackVerdict: Equatable {
    case notOurs
    case noAttempt
    case expired
    case nonceMismatch
    case missingCode
    case accepted(code: String, nonce: String)
}

@MainActor
public final class AccountLinker: ObservableObject {

    @Published public private(set) var state: AccountState = .unlinked
    @Published public private(set) var entitlement: CachedEntitlement?

    nonisolated public static let linkAttemptLifetime: TimeInterval = 120
    nonisolated public static let callbackScheme = "skipperdesk"
    nonisolated public static let callbackHost = "link"

    private struct LinkAttempt {
        let nonce: String
        let startedAt: Date
    }

    private let identity: IdentityStore
    private let client: APIClient
    private let tokens: DeviceTokenStore
    private let webBaseURL: URL
    private let openInBrowser: (URL) -> Void
    private let hardwareIdentifier: () -> String

    private var attempt: LinkAttempt?
    private var token: DeviceToken?

    public var hasPendingLink: Bool { attempt != nil }

    public init(
        identity: IdentityStore,
        client: APIClient = APIClient(),
        tokens: DeviceTokenStore = DeviceTokenStore.forThisMac(),
        webBaseURL: URL = AccountLinker.defaultWebBaseURL(),
        openInBrowser: @escaping (URL) -> Void = { NSWorkspace.shared.open($0) },
        hardwareIdentifier: @escaping () -> String = AccountLinker.platformSerialNumber
    ) {
        self.identity = identity
        self.client = client
        self.tokens = tokens
        self.webBaseURL = webBaseURL
        self.openInBrowser = openInBrowser
        self.hardwareIdentifier = hardwareIdentifier
    }

    nonisolated public static func defaultWebBaseURL(
        apiBaseURL: URL = RCConfig.current.apiBaseURL,
        overrides: BackendOverrides = .fromEnvironment()
    ) -> URL {
        if let url = overrides.webBaseURL {
            return url
        }
        guard var parts = URLComponents(url: apiBaseURL, resolvingAgainstBaseURL: false),
              let host = parts.host else { return apiBaseURL }
        if host.hasPrefix("api.") {
            parts.host = String(host.dropFirst("api.".count))
        }
        return parts.url ?? apiBaseURL
    }

    // MARK: - Restore

    public func restore() async {
        do {
            guard let stored = try tokens.load() else {
                state = .unlinked
                return
            }
            token = stored
            if stored.needsRefresh {
                try? await refreshToken()
            }
            try await loadLinkedState()
        } catch let error as APIError {
            handle(error)
        } catch {
            state = .error(message: error.localizedDescription)
        }
    }

    // MARK: - §1.1 link

    public func beginLink() {
        guard let nonce = try? Self.freshNonce() else {
            state = .error(message: "This Mac could not generate a secure link request.")
            return
        }
        var parts = URLComponents(url: webBaseURL.appendingPathComponent("link"), resolvingAgainstBaseURL: false)
        parts?.percentEncodedQueryItems = [
            URLQueryItem(name: "nonce", value: Self.queryEncoded(nonce)),
            URLQueryItem(name: "device", value: Self.queryEncoded(identity.publicKeyBase64)),
        ]
        guard let url = parts?.url else {
            state = .error(message: "The sign-in address could not be built from \(webBaseURL.absoluteString).")
            return
        }
        attempt = LinkAttempt(nonce: nonce, startedAt: Date())
        state = .linking
        RCLog.info("account: opening browser sign-in at \(webBaseURL.absoluteString)/link")
        openInBrowser(url)
    }

    public func cancelLink() {
        attempt = nil
        state = token == nil ? .unlinked : state
        if token != nil {
            Task { await restore() }
        }
    }

    @discardableResult
    public func handleCallback(_ url: URL) -> Bool {
        let verdict = Self.verdict(
            for: url, pendingNonce: attempt?.nonce, startedAt: attempt?.startedAt, now: Date())
        switch verdict {
        case .notOurs:
            return false
        case .noAttempt:
            RCLog.error("account: ignored a link callback; no sign-in is in progress")
        case .expired:
            attempt = nil
            state = .error(message: "That sign-in took too long. Try linking this Mac again.")
        case .nonceMismatch:
            RCLog.error("account: rejected a link callback whose nonce did not match; the sign-in attempt was abandoned")
            cancelLink()
        case .missingCode:
            attempt = nil
            state = .error(message: "The sign-in page came back without a code. Try linking this Mac again.")
        case .accepted(let code, let nonce):
            RCLog.info("account: accepted the \(Self.callbackScheme)://\(Self.callbackHost) callback")
            attempt = nil
            Task { await exchange(code: code, nonce: nonce) }
        }
        return true
    }

    nonisolated public static func verdict(
        for url: URL,
        pendingNonce: String?,
        startedAt: Date?,
        now: Date
    ) -> LinkCallbackVerdict {
        guard url.scheme == callbackScheme, url.host == callbackHost else { return .notOurs }
        guard let pendingNonce, let startedAt else { return .noAttempt }
        guard now.timeIntervalSince(startedAt) < linkAttemptLifetime else { return .expired }
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let value = { (name: String) in items.first(where: { $0.name == name })?.value ?? "" }
        let nonce = value("nonce")
        guard !nonce.isEmpty, constantTimeEquals(nonce, pendingNonce) else { return .nonceMismatch }
        let code = value("code")
        guard !code.isEmpty else { return .missingCode }
        return .accepted(code: code, nonce: nonce)
    }

    nonisolated static func constantTimeEquals(_ lhs: String, _ rhs: String) -> Bool {
        let left = Array(lhs.utf8)
        let right = Array(rhs.utf8)
        guard left.count == right.count else { return false }
        var difference: UInt8 = 0
        for index in left.indices {
            difference |= left[index] ^ right[index]
        }
        return difference == 0
    }

    // MARK: - §1.3 / §1.4 exchange

    private func exchange(code: String, nonce: String) async {
        state = .linking
        do {
            let challenge = try await client.deviceChallenge(code: code)
            guard let nonceBytes = challenge.nonceBytes else {
                state = .error(message: "The server's sign-in challenge was not readable.")
                return
            }
            let grant = try await client.deviceToken(
                code: code,
                nonce: nonce,
                pubkey: identity.publicKeyBase64,
                signature: try identity.signatureBase64(purpose: .apiChallenge, nonce: nonceBytes),
                platform: "macos",
                hardwareId: hardwareIdentifier(),
                label: RCConfig.current.deviceLabel
            )
            let fresh = DeviceToken(grant: grant)
            try tokens.save(fresh)
            token = fresh
            RCLog.info("account: linked device \(fresh.deviceId)")
            try await loadLinkedState()
        } catch let error as APIError {
            handle(error)
        } catch {
            state = .error(message: error.localizedDescription)
        }
    }

    // MARK: - §1.5 refresh, §1.6 revoke

    private func refreshToken() async throws {
        guard let current = token else { throw APIError.transport("This Mac holds no account token.") }
        let challenge = try await client.deviceChallenge(deviceId: current.deviceId)
        guard let nonceBytes = challenge.nonceBytes else {
            throw APIError.transport("The server's refresh challenge was not readable.")
        }
        let grant = try await client.refreshDeviceToken(
            deviceId: current.deviceId,
            nonce: challenge.nonce,
            pubkey: identity.publicKeyBase64,
            signature: try identity.signatureBase64(purpose: .apiChallenge, nonce: nonceBytes)
        )
        let fresh = DeviceToken(grant: grant)
        try tokens.save(fresh)
        token = fresh
        RCLog.info("account: refreshed the device token for \(fresh.deviceId)")
    }

    public func unlink() async {
        let current = token
        token = nil
        entitlement = nil
        state = .unlinked
        try? tokens.remove()
        guard let current else { return }
        do {
            try await client.revokeDeviceToken(current.token)
            RCLog.info("account: revoked the device token for \(current.deviceId)")
        } catch let error as APIError {
            RCLog.error("account: revoke failed (\(error.code.wire)); the token is gone from this Mac anyway")
        } catch {
            RCLog.error("account: revoke failed; the token is gone from this Mac anyway")
        }
    }

    // MARK: - §3.4 / §4.1 reads

    public func refreshEntitlement(force: Bool = false) async {
        guard token != nil else { return }
        if !force, let cached = entitlement, !cached.isStale { return }
        do {
            let fresh = try await authorized { try await self.client.entitlement(token: $0) }
            entitlement = CachedEntitlement(value: fresh, fetchedAt: Date())
            RCLog.info("account: entitlement status=\(fresh.status.rawValue) tier=\(fresh.tier)")
        } catch let error as APIError {
            handle(error)
        } catch {
            state = .error(message: error.localizedDescription)
        }
    }

    private func loadLinkedState() async throws {
        guard let current = token else {
            state = .unlinked
            return
        }
        let record = try await authorized { try await self.client.device(id: current.deviceId, token: $0) }
        state = .linked(accountLabel: current.accountId, device: record)
        let fresh = try await authorized { try await self.client.entitlement(token: $0) }
        entitlement = CachedEntitlement(value: fresh, fetchedAt: Date())
        RCLog.info("account: entitlement status=\(fresh.status.rawValue) tier=\(fresh.tier)")
    }

    private func authorized<T>(_ call: (String) async throws -> T) async throws -> T {
        guard let current = token else { throw APIError.transport("This Mac holds no account token.") }
        do {
            return try await call(current.token)
        } catch let error as APIError where error.code == .unauthenticated {
            try await refreshToken()
            guard let renewed = token else { throw error }
            return try await call(renewed.token)
        }
    }

    // MARK: - Failure

    private func handle(_ error: APIError) {
        RCLog.error("account: \(error.code.wire)\(error.reason.map { " (\($0))" } ?? "") — \(error.message)")
        switch error.code {
        case .unauthenticated:
            token = nil
            try? tokens.remove()
            entitlement = nil
            state = .error(message: "This Mac's sign-in is no longer valid. Link it again.")
        case .forbidden where error.reason == "unlinked" || error.reason == "revoked":
            token = nil
            try? tokens.remove()
            entitlement = nil
            state = .unlinked
        default:
            state = .error(message: error.message)
        }
    }

    // MARK: - Inputs

    nonisolated private static func queryEncoded(_ value: String) -> String {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "+&=?#")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }

    private static func freshNonce() throws -> String {
        try SecureRandom.data(32).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    nonisolated public static func platformSerialNumber() -> String {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPlatformExpertDevice"))
        guard service != 0 else { return "unknown" }
        defer { IOObjectRelease(service) }
        let property = IORegistryEntryCreateCFProperty(
            service, "IOPlatformSerialNumber" as CFString, kCFAllocatorDefault, 0)
        guard let serial = property?.takeRetainedValue() as? String, !serial.isEmpty else { return "unknown" }
        return serial
    }
}
