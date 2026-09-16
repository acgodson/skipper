import Foundation

public enum PresenceState: String, Equatable {
    case online
    case offline
    /// We have no signaling connection, so we genuinely do not know. Shown as
    /// "Unknown" rather than guessing "Offline", which would be a lie.
    case unknown

    public var indicator: String {
        switch self {
        case .online: return "\u{25CF}"   // filled
        case .offline: return "\u{25CB}"  // hollow
        case .unknown: return "\u{25CB}"
        }
    }

    public var label: String {
        switch self {
        case .online: return "Online"
        case .offline: return "Offline"
        case .unknown: return "Unknown"
        }
    }
}

/// Presence of a watched peer device.
///
/// PHASE 3 supplies the real implementation over the signaling WebSocket:
/// `watch {deviceId}` on connect and a pushed `presence` event thereafter.
@MainActor
public protocol PeerPresenceSource: AnyObject {
    var state: PresenceState { get }
    var explanation: String { get }
    func watch(deviceID: String)
    func stopWatching()
}

/// STUB. Reports `.unknown` forever, because Phase 2 has no signaling client.
/// It never claims a peer is online — that would fake a feature that does not
/// exist yet.
@MainActor
public final class PreviewPresenceSource: PeerPresenceSource, ObservableObject {

    @Published public private(set) var state: PresenceState = .unknown
    @Published public private(set) var watchedDeviceID: String?

    public var explanation: String {
        "Presence requires the signaling server (Phase 3). Not connected."
    }

    public init() {}

    public func watch(deviceID: String) {
        watchedDeviceID = deviceID
        state = .unknown
    }

    public func stopWatching() {
        watchedDeviceID = nil
        state = .unknown
    }
}

/// This machine's own reachability, as reported to the signaling server.
/// PHASE 3, real: driven by the signaling client's authentication state.
@MainActor
public final class SelfPresence: ObservableObject {
    @Published public private(set) var state: PresenceState = .unknown
    @Published public private(set) var explanation = "Connecting to the signaling server\u{2026}"

    public init() {}

    public func update(reachable: Bool, detail: String) {
        state = reachable ? .online : .offline
        explanation = detail
    }

    public func setUnknown(detail: String) {
        state = .unknown
        explanation = detail
    }
}

/// PHASE 3, real. Driven by `watch` / `presence` on the signaling socket
/// (PROTOCOL.md §2.7, §2.8). `SessionCoordinator` owns one and pushes into it;
/// the view binds to it exactly as it bound to the Phase 2 stub.
///
/// It reports `.unknown`, never `.offline`, whenever we have no authenticated
/// signaling socket — with no control plane we do not know anything about the
/// peer, and claiming "Offline" would be a statement about them rather than
/// about us.
@MainActor
public final class SignalingPresenceSource: PeerPresenceSource, ObservableObject {

    @Published public private(set) var state: PresenceState = .unknown
    @Published public private(set) var watchedDeviceID: String?
    @Published public private(set) var since: Date?
    @Published public private(set) var serverReachable = false

    /// Set by the owner so `watch`/`stopWatching` reach the socket.
    public var onWatch: ((String) -> Void)?
    public var onStopWatching: (() -> Void)?

    public init() {}

    public var explanation: String {
        guard let watchedDeviceID else { return "No saved Mac to watch." }
        if !serverReachable {
            return "Not connected to the signaling server, so the status of \(DeviceID.formatted(watchedDeviceID)) is unknown."
        }
        switch state {
        case .online: return "\(DeviceID.formatted(watchedDeviceID)) is online and reachable."
        case .offline: return "\(DeviceID.formatted(watchedDeviceID)) is not running RemoteControl, or has no internet."
        case .unknown: return "Waiting for the server to report the status of \(DeviceID.formatted(watchedDeviceID))."
        }
    }

    public func watch(deviceID: String) {
        guard let canonical = DeviceID.canonicalize(deviceID) else { return }
        watchedDeviceID = canonical
        state = .unknown
        onWatch?(canonical)
    }

    public func stopWatching() {
        watchedDeviceID = nil
        state = .unknown
        since = nil
        onStopWatching?()
    }

    /// Called by the coordinator on every `presence` push for the watched device.
    public func apply(online: Bool, since millis: Int64) {
        state = online ? .online : .offline
        self.since = millis > 0 ? Date(timeIntervalSince1970: Double(millis) / 1000.0) : nil
    }

    public func setServerReachable(_ reachable: Bool) {
        serverReachable = reachable
        if !reachable { state = .unknown }
    }
}
