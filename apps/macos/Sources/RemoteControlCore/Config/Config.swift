import Foundation

/// Everything about *where* and *how* the app talks to its backend, in one
/// place.
///
/// The app is backend-agnostic (docs/SCOPE.md §4): it knows exactly ONE
/// config value, the API domain. Anything implementing the REST + signaling
/// contract is a valid backend — local dev server, tunnel, or the deployed
/// AWS account — with no app change beyond `apiBaseURL`.
public struct RCConfig: Equatable {

    // MARK: Server

    /// The API domain, e.g. `https://api.skipperdesk.app`. Override with
    /// `SKIPPER_API_BASE_URL`. `http://`/`ws://` is accepted only when the
    /// host is `localhost` or `127.0.0.1` (local dev); anything else fails at
    /// config load rather than silently sending credentials over plaintext.
    public var apiBaseURL: URL
    /// `wss://<host>/ws` (or `ws://<host>/ws` for local dev), derived from
    /// `apiBaseURL`. There is no separate override: two values that can
    /// disagree is exactly the bug this config collapses away.
    public var signalingURL: URL
    /// Human label sent with `register`. Override with `RC_DEVICE_LABEL`.
    public var deviceLabel: String

    // MARK: Timeouts and intervals (PROTOCOL.md §2, PLAN.md §2.1)

    /// How long a single WebSocket connect + authenticate attempt may take.
    public var handshakeTimeout: TimeInterval
    /// How long to wait for a reply to a correlated request.
    public var requestTimeout: TimeInterval
    /// `heartbeat` cadence. The server advertises 15 s in `hello_ok`; this is the
    /// value used until it does.
    public var heartbeatInterval: TimeInterval
    /// `renew` cadence while a session is live. PROTOCOL.md §2.11 says 5 minutes.
    public var renewInterval: TimeInterval
    /// Reconnect backoff floor and ceiling. PLAN.md §2.1: 0.5 s → 15 s, jittered.
    public var backoffMinimum: TimeInterval
    public var backoffMaximum: TimeInterval
    /// ICE `disconnected` for this long triggers an ICE restart. PLAN.md §2.1: 3 s.
    public var iceRestartDelay: TimeInterval
    /// ICE `failed` plus this grace window closes the session. PLAN.md §2.1: 45 s.
    public var iceFailureGrace: TimeInterval
    /// `all` (default) or `relay`. `relay` forces every candidate through TURN,
    /// which is how `scripts/test-partition.sh` gets a media path it can
    /// actually cut on a single machine — two processes on one Mac would
    /// otherwise talk over loopback, which no firewall rule here can block.
    /// It is also the switch Phase 6 uses to prove the relay works at all.
    public var forceTURNRelay: Bool

    public init(
        apiBaseURL: URL,
        deviceLabel: String = "Mac",
        handshakeTimeout: TimeInterval = 20,
        requestTimeout: TimeInterval = 15,
        heartbeatInterval: TimeInterval = 15,
        renewInterval: TimeInterval = 300,
        backoffMinimum: TimeInterval = 0.5,
        backoffMaximum: TimeInterval = 15,
        iceRestartDelay: TimeInterval = 3,
        iceFailureGrace: TimeInterval = 45,
        forceTURNRelay: Bool = false
    ) {
        self.apiBaseURL = apiBaseURL
        self.signalingURL = Self.deriveSignalingURL(fromAPIBaseURL: apiBaseURL)
        self.deviceLabel = deviceLabel
        self.handshakeTimeout = handshakeTimeout
        self.requestTimeout = requestTimeout
        self.heartbeatInterval = heartbeatInterval
        self.renewInterval = renewInterval
        self.backoffMinimum = backoffMinimum
        self.backoffMaximum = backoffMaximum
        self.iceRestartDelay = iceRestartDelay
        self.iceFailureGrace = iceFailureGrace
        self.forceTURNRelay = forceTURNRelay
    }

    // MARK: Deployed defaults

    /// The public backend described in docs/SCOPE.md §4.
    public static let defaultAPIBaseURLString = "https://api.skipperdesk.app"

    private static let localDevHosts: Set<String> = ["localhost", "127.0.0.1"]

    /// `wss://<host>[:<port>]/ws`, or `ws://` when `apiBaseURL` is plain HTTP.
    private static func deriveSignalingURL(fromAPIBaseURL apiBaseURL: URL) -> URL {
        var parts = URLComponents()
        parts.scheme = (apiBaseURL.scheme == "http") ? "ws" : "wss"
        parts.host = apiBaseURL.host
        parts.port = apiBaseURL.port
        parts.path = "/ws"
        guard let url = parts.url else {
            fatalError("could not derive a signaling URL from \(apiBaseURL.absoluteString)")
        }
        return url
    }

    /// Reads the environment once and produces the configuration the app runs on.
    public static func fromEnvironment(_ env: [String: String] = ProcessInfo.processInfo.environment) -> RCConfig {
        let urlString = env["SKIPPER_API_BASE_URL"]?.trimmingCharacters(in: .whitespaces).nilIfEmpty
            ?? defaultAPIBaseURLString
        guard let url = URL(string: urlString), let scheme = url.scheme else {
            fatalError("SKIPPER_API_BASE_URL is not a valid URL: '\(urlString)'")
        }

        let insecureSchemes: Set<String> = ["http", "ws"]
        if insecureSchemes.contains(scheme), !localDevHosts.contains(url.host ?? "") {
            fatalError("""
                SKIPPER_API_BASE_URL uses \(scheme):// against '\(url.host ?? "?")'. \
                Only https:// (which becomes wss://) is allowed outside localhost/127.0.0.1 \
                local development.
                """)
        }

        var config = RCConfig(
            apiBaseURL: url,
            deviceLabel: env["RC_DEVICE_LABEL"]?.nilIfEmpty ?? Host.current().localizedName ?? "Mac")

        if let v = env["RC_HANDSHAKE_TIMEOUT"].flatMap(Double.init) { config.handshakeTimeout = v }
        if let v = env["RC_REQUEST_TIMEOUT"].flatMap(Double.init) { config.requestTimeout = v }
        if let v = env["RC_HEARTBEAT_SEC"].flatMap(Double.init) { config.heartbeatInterval = v }
        if let v = env["RC_RENEW_SEC"].flatMap(Double.init) { config.renewInterval = v }
        if let v = env["RC_BACKOFF_MIN"].flatMap(Double.init) { config.backoffMinimum = v }
        if let v = env["RC_BACKOFF_MAX"].flatMap(Double.init) { config.backoffMaximum = v }
        if let v = env["RC_ICE_RESTART_DELAY"].flatMap(Double.init) { config.iceRestartDelay = v }
        if let v = env["RC_ICE_FAILURE_GRACE"].flatMap(Double.init) { config.iceFailureGrace = v }
        if let policy = env["RC_ICE_POLICY"] { config.forceTURNRelay = (policy == "relay") }
        return config
    }

    /// The process-wide configuration. Read once so that a mid-run environment
    /// change cannot make two components disagree about where the server is.
    public static let current = RCConfig.fromEnvironment()

    /// `https://<host>[:<port>]/healthz`, for diagnostics and the test scripts.
    public var healthURL: URL? {
        guard var parts = URLComponents(url: apiBaseURL, resolvingAgainstBaseURL: false) else { return nil }
        parts.path = "/healthz"
        return parts.url
    }
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
