import Foundation

public enum PresenceState: String, Equatable {
    case online
    case offline
    case unknown

    public var indicator: String {
        switch self {
        case .online: return "\u{25CF}"
        case .offline: return "\u{25CB}"
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

@MainActor
public protocol PeerPresenceSource: AnyObject {
    var state: PresenceState { get }
    var explanation: String { get }
    func watch(deviceID: String)
    func stopWatching()
}

@MainActor
public final class SelfPresence: ObservableObject {
    @Published public private(set) var state: PresenceState = .unknown
    @Published public private(set) var explanation = "Connecting to SkipperDesk\u{2026}"

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

@MainActor
public final class SignalingPresenceSource: PeerPresenceSource, ObservableObject {

    @Published public private(set) var state: PresenceState = .unknown
    @Published public private(set) var watchedDeviceID: String?
    @Published public private(set) var since: Date?
    @Published public private(set) var serverReachable = false

    public var onWatch: ((String) -> Void)?
    public var onStopWatching: (() -> Void)?

    public init() {}

    public var explanation: String {
        guard let watchedDeviceID else { return "No saved Mac to watch." }
        if !serverReachable {
            return "Not connected to SkipperDesk, so it is not known whether \(DeviceID.formatted(watchedDeviceID)) is online."
        }
        switch state {
        case .online: return "\(DeviceID.formatted(watchedDeviceID)) is online and reachable."
        case .offline: return "\(DeviceID.formatted(watchedDeviceID)) is not running SkipperDesk, or has no internet."
        case .unknown: return "Checking whether \(DeviceID.formatted(watchedDeviceID)) is online\u{2026}"
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

    public func apply(online: Bool, since millis: Int64) {
        state = online ? .online : .offline
        self.since = millis > 0 ? Date(timeIntervalSince1970: Double(millis) / 1000.0) : nil
    }

    public func setServerReachable(_ reachable: Bool) {
        serverReachable = reachable
        if !reachable { state = .unknown }
    }
}
