import Foundation
import AppKit
import IOKit

/// What this Mac's link to a SkipperDesk account is doing right now.
///
/// State only: four cases, each of which the host screen renders directly.
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

/// Links this Mac to a SkipperDesk account, exactly as protocol/API.md §1
/// describes: sign-in happens in the browser, the app receives a one-time code
/// over the `skipperdesk://` scheme and exchanges it for a device token bound
/// to the device key.
///
/// The app never sees a password, never holds a Cognito token, and never keeps
/// the one-time code beyond the exchange.
@MainActor
public final class AccountLinker: ObservableObject {

    @Published public private(set) var state: AccountState = .unlinked
    /// The API.md §4.1 answer and the moment it was read (§4.2: the client
    /// renders this, it never computes an entitlement of its own).
    @Published public private(set) var entitlement: CachedEntitlement?

    /// API.md §1.1 rule 1: a callback for an attempt that is older than this,
    /// or that was never started here, is discarded.
    public static let linkAttemptLifetime: TimeInterval = 120
    public static let callbackScheme = "skipperdesk"
    public static let callbackHost = "link"

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

    /// The website that runs the sign-in: `apiBaseURL` with the `api.` label
    /// stripped, overridable with `SKIPPER_WEB_BASE_URL` for a dev stub.
    nonisolated public static func defaultWebBaseURL(
        apiBaseURL: URL = RCConfig.current.apiBaseURL,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        if let override = environment["SKIPPER_WEB_BASE_URL"]?.trimmingCharacters(in: .whitespaces).nilIfEmpty,
           let url = URL(string: override) {
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

    /// Reads the stored token and re-states what the server says about this
    /// device. Called once at launch.
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

    /// Step 1: mint the app's nonce and hand the browser the sign-in page.
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

    /// Step 4: the browser hands back `skipperdesk://link?code=…`.
    ///
    /// Returns false for a URL this linker did not start, which the caller
    /// treats as "not mine" rather than as a failure.
    @discardableResult
    public func handleCallback(_ url: URL) -> Bool {
        guard url.scheme == Self.callbackScheme, url.host == Self.callbackHost else { return false }
        RCLog.info("account: received a \(Self.callbackScheme)://\(Self.callbackHost) callback")
        guard let code = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == "code" })?.value, !code.isEmpty else {
            state = .error(message: "The sign-in page came back without a code. Try linking this Mac again.")
            return true
        }
        guard let started = attempt, Date().timeIntervalSince(started.startedAt) < Self.linkAttemptLifetime else {
            attempt = nil
            state = .error(message: "This Mac did not start that sign-in, or it took too long. Try again.")
            return true
        }
        attempt = nil
        Task { await exchange(code: code) }
        return true
    }

    // MARK: - §1.3 / §1.4 exchange

    private func exchange(code: String) async {
        state = .linking
        do {
            let challenge = try await client.deviceChallenge(code: code)
            guard let nonceBytes = challenge.nonceBytes else {
                state = .error(message: "The server's sign-in challenge was not readable.")
                return
            }
            let grant = try await client.deviceToken(
                code: code,
                pubkey: identity.publicKeyBase64,
                signature: try identity.signatureBase64(for: nonceBytes),
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

    /// Proves possession of the device key and mints a new token. Used when the
    /// TTL runs low and once on any `401` (API.md §1.5).
    private func refreshToken() async throws {
        guard let current = token else { throw APIError.transport("This Mac holds no account token.") }
        let challenge = try await client.deviceChallenge(deviceId: current.deviceId)
        guard let nonceBytes = challenge.nonceBytes else {
            throw APIError.transport("The server's refresh challenge was not readable.")
        }
        let grant = try await client.refreshDeviceToken(
            deviceId: current.deviceId,
            pubkey: identity.publicKeyBase64,
            signature: try identity.signatureBase64(for: nonceBytes)
        )
        let fresh = DeviceToken(grant: grant)
        try tokens.save(fresh)
        token = fresh
        RCLog.info("account: refreshed the device token for \(fresh.deviceId)")
    }

    /// Ends this Mac's link: revokes the calling token (§1.6) and forgets it.
    ///
    /// Breaking the link entirely is `DELETE /v1/devices/{id}` (§3.6), which is
    /// a user-session call and therefore belongs to the website. This applies
    /// the same local consequences as §3.6 does server-side: no token, no
    /// entitlement, and nothing that could host a session.
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

    /// Re-reads the entitlement, honouring the server's own `refreshAfterSec`
    /// unless the caller insists (API.md §4.2).
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

    /// Runs a device-token call, refreshing once on `401` (API.md §1.5).
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

    /// A device that the account no longer holds is unlinked, not broken: the
    /// user is told to link again rather than shown an error code.
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

    /// Percent-encodes a query value, `+` and `=` included.
    ///
    /// `URLComponents.queryItems` leaves both alone, and a base64 `pubkey`
    /// contains them: a server reading the query with ordinary form decoding
    /// would then see a space where the key has a `+`, and reject the device at
    /// API.md §1.1 rule 3 for a key it was never actually sent.
    nonisolated private static func queryEncoded(_ value: String) -> String {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "+&=?#")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }

    /// 32 random bytes, base64url, no padding (API.md §1.1).
    private static func freshNonce() throws -> String {
        try SecureRandom.data(32).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// `hardwareId` of API.md §1.4, sent exactly once. The server keeps only a
    /// salted hash of it (§3.2) and the raw value never appears anywhere else.
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
