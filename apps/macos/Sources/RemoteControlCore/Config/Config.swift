import Foundation

/// Everything about *where* and *how* the app talks to `rc-signal`, in one place.
///
/// Every field has an environment-variable override so that the integration
/// scripts can point two processes at a different server, a different identity
/// directory, or a deliberately wrong certificate pin — the last of which is how
/// `scripts/test-transport.sh` proves the pin is load-bearing rather than
/// decorative.
public struct RCConfig: Equatable {

    // MARK: Server

    /// `wss://<host>:8443/ws`. Override with `RC_SERVER_URL`.
    public var signalingURL: URL
    /// Base64 SHA-256 of the server's **DER** certificate. Override with
    /// `RC_CERT_PIN`. Set `RC_CERT_PIN=off` to disable pinning entirely, which
    /// is only ever correct for a plain-`ws://` local server.
    public var certificatePinBase64: String?
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
        signalingURL: URL,
        certificatePinBase64: String?,
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
        self.signalingURL = signalingURL
        self.certificatePinBase64 = certificatePinBase64
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

    /// The live deployment described in `infra/README.md`.
    ///
    /// The IP is not an Elastic IP yet, so if the instance is ever stopped both
    /// this address and the pin below change together — the pin's SAN is bound
    /// to the IP. That is a documented outstanding risk, not an oversight.
    public static let defaultServerURLString = "wss://54.246.73.81:8443/ws"
    public static let defaultCertificatePin = "E30xoxEp9t658+TJEVdaGb8Ooi7HGGMWp1kxVpeSpgk="

    /// Reads the environment once and produces the configuration the app runs on.
    public static func fromEnvironment(_ env: [String: String] = ProcessInfo.processInfo.environment) -> RCConfig {
        let urlString = env["RC_SERVER_URL"]?.trimmingCharacters(in: .whitespaces).nilIfEmpty
            ?? defaultServerURLString
        let url = URL(string: urlString) ?? URL(string: defaultServerURLString)!

        var pin: String? = defaultCertificatePin
        if let override = env["RC_CERT_PIN"]?.trimmingCharacters(in: .whitespaces) {
            pin = (override.lowercased() == "off" || override.isEmpty) ? nil : override
        }
        // A plain ws:// endpoint has no certificate to pin. Keeping a pin set
        // here would be a lie in every log line that mentions it.
        if url.scheme == "ws" { pin = nil }

        var config = RCConfig(
            signalingURL: url,
            certificatePinBase64: pin,
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

    /// `https://<host>:<port>/healthz`, for diagnostics and the test scripts.
    public var healthURL: URL? {
        guard var parts = URLComponents(url: signalingURL, resolvingAgainstBaseURL: false) else { return nil }
        parts.scheme = (signalingURL.scheme == "ws") ? "http" : "https"
        parts.path = "/healthz"
        return parts.url
    }
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
