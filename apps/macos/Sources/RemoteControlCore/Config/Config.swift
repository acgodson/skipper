import Foundation

public struct RCConfig: Equatable {

    // MARK: Server

    public var apiBaseURL: URL
    public var signalingURL: URL
    public var deviceLabel: String

    // MARK: Timeouts and intervals (PROTOCOL.md §2, PLAN.md §2.1)

    public var handshakeTimeout: TimeInterval
    public var requestTimeout: TimeInterval
    public var heartbeatInterval: TimeInterval
    public var renewInterval: TimeInterval
    public var backoffMinimum: TimeInterval
    public var backoffMaximum: TimeInterval
    public var iceRestartDelay: TimeInterval
    public var iceFailureGrace: TimeInterval
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

    public static let defaultAPIBaseURLString = "https://api.skipperdesk.app"

    private static let localDevHosts: Set<String> = ["localhost", "127.0.0.1"]

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

    public static let current = RCConfig.fromEnvironment()

    public var healthURL: URL? {
        guard var parts = URLComponents(url: apiBaseURL, resolvingAgainstBaseURL: false) else { return nil }
        parts.path = "/healthz"
        return parts.url
    }
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
