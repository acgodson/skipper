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

    public static let defaultAPIBaseURL = URL(string: defaultAPIBaseURLString)!

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
        let url = BackendOverrides.fromEnvironment(env).apiBaseURL ?? defaultAPIBaseURL

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

public enum BackendURLPolicy {

    public static let localDevelopmentHosts: Set<String> = ["localhost", "127.0.0.1"]

    public enum Rejection: Error, Equatable, CustomStringConvertible {
        case malformed(String)
        case insecure(scheme: String, host: String)

        public var description: String {
            switch self {
            case .malformed(let raw):
                return "'\(raw)' is not a valid https:// URL"
            case .insecure(let scheme, let host):
                return "\(scheme):// against '\(host)' is refused; only https:// is allowed outside localhost/127.0.0.1"
            }
        }
    }

    public static func validate(_ raw: String) -> Result<URL, Rejection> {
        guard let url = URL(string: raw), let scheme = url.scheme?.lowercased(),
              let host = url.host?.lowercased(), !host.isEmpty else {
            return .failure(.malformed(raw))
        }
        switch scheme {
        case "https":
            return .success(url)
        case "http" where localDevelopmentHosts.contains(host):
            return .success(url)
        default:
            return .failure(.insecure(scheme: scheme, host: host))
        }
    }
}

// TODO: AccountLinker.defaultWebBaseURL should read BackendOverrides.fromEnvironment().webBaseURL; until then AppModel validates both variables at launch.
public struct BackendOverrides: Equatable {

    public static let apiVariable = "SKIPPER_API_BASE_URL"
    public static let webVariable = "SKIPPER_WEB_BASE_URL"
    public static let defaultWebBaseURLString = "https://skipperdesk.app"

    public let apiBaseURL: URL?
    public let webBaseURL: URL?

    public init(apiBaseURL: URL?, webBaseURL: URL?) {
        self.apiBaseURL = apiBaseURL
        self.webBaseURL = webBaseURL
    }

    public static func parse(_ env: [String: String]) -> Result<BackendOverrides, BackendURLPolicy.Rejection> {
        var resolved: [String: URL] = [:]
        for variable in [apiVariable, webVariable] {
            guard let raw = env[variable]?.trimmingCharacters(in: .whitespaces).nilIfEmpty else { continue }
            switch BackendURLPolicy.validate(raw) {
            case .success(let url): resolved[variable] = url
            case .failure(let rejection): return .failure(rejection)
            }
        }
        return .success(BackendOverrides(apiBaseURL: resolved[apiVariable], webBaseURL: resolved[webVariable]))
    }

    public static func fromEnvironment(_ env: [String: String] = ProcessInfo.processInfo.environment) -> BackendOverrides {
        switch parse(env) {
        case .success(let overrides):
            return overrides
        case .failure(let rejection):
            fatalError("\(apiVariable) / \(webVariable): \(rejection)")
        }
    }

    public var developmentHosts: [String] {
        var hosts: [String] = []
        let candidates = [(apiBaseURL, RCConfig.defaultAPIBaseURLString),
                          (webBaseURL, Self.defaultWebBaseURLString)]
        for (url, standard) in candidates {
            guard let url, !Self.sameOrigin(url, standard), let host = url.host else { continue }
            let label = url.port.map { "\(host):\($0)" } ?? host
            if !hosts.contains(label) { hosts.append(label) }
        }
        return hosts
    }

    public var developmentBannerText: String? {
        let hosts = developmentHosts
        guard !hosts.isEmpty else { return nil }
        return "Using a development server: " + hosts.joined(separator: ", ")
    }

    private static func sameOrigin(_ url: URL, _ standard: String) -> Bool {
        guard let other = URL(string: standard) else { return false }
        return url.scheme?.lowercased() == other.scheme
            && url.host?.lowercased() == other.host
            && url.port == other.port
    }
}
