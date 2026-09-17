import Foundation

// Host keys pinned per Device ID on the controller (PROTOCOL.md v4 changes).

public enum HostKeyPinDecision: Equatable {
    case firstUse
    case match
    case mismatch
}

public struct HostKeyMismatch: Equatable {
    public let deviceID: String
    public let presentedKey: String?

    public init(deviceID: String, presentedKey: String?) {
        self.deviceID = deviceID
        self.presentedKey = presentedKey
    }
}

@MainActor
public final class HostKeyPins: ObservableObject {

    public static let changedCode = "host_key_changed"
    public static let changedSentence = "This Device ID now belongs to a different Mac. If you reinstalled or "
        + "replaced that Mac, choose Trust the new Mac; otherwise don't connect."

    @Published public private(set) var mismatch: HostKeyMismatch?

    private let secrets: SecretStore
    private var pending: (sessionID: String, deviceID: String, key: String)?

    public init(secrets: SecretStore) {
        self.secrets = secrets
    }

    public static func canonicalKey(_ key: String?) -> String? {
        guard let key, !key.isEmpty, let der = Data(base64Encoded: key), !der.isEmpty else { return nil }
        return der.base64EncodedString()
    }

    public static func decide(pinned: String?, presented: String?) -> HostKeyPinDecision {
        guard let pinned = canonicalKey(pinned) else { return .firstUse }
        return canonicalKey(presented) == pinned ? .match : .mismatch
    }

    public func pinnedKey(forHost deviceID: String) -> String? {
        do {
            return try secrets.hostKeyPins()[deviceID]
        } catch {
            RCLog.error("host key pins could not be read: \(error.localizedDescription)")
            return nil
        }
    }

    public func decision(forHost deviceID: String, presentedKey: String?) throws -> HostKeyPinDecision {
        Self.decide(pinned: try secrets.hostKeyPins()[deviceID], presented: presentedKey)
    }

    public func admit(_ grant: SessionGrantPayload) throws {
        pending = nil
        let deviceID = grant.hostDeviceId
        switch try decision(forHost: deviceID, presentedKey: grant.hostPubkey) {
        case .match:
            mismatch = nil
        case .firstUse:
            mismatch = nil
            if let key = Self.canonicalKey(grant.hostPubkey) {
                pending = (grant.sessionId, deviceID, key)
            }
        case .mismatch:
            RCLog.error("host key for \(deviceID) differs from the pinned key; refusing before the access-code exchange")
            mismatch = HostKeyMismatch(deviceID: deviceID, presentedKey: Self.canonicalKey(grant.hostPubkey))
            throw WireError.protocolError(code: Self.changedCode, message: Self.changedSentence, retryAfterSec: 0)
        }
    }

    public func confirm(sessionID: String, hostPubkey: String? = nil) {
        guard let pending, pending.sessionID == sessionID else { return }
        if let hostPubkey, Self.canonicalKey(hostPubkey) != pending.key { return }
        self.pending = nil
        do {
            var pins = try secrets.hostKeyPins()
            guard pins[pending.deviceID] == nil else { return }
            pins[pending.deviceID] = pending.key
            try secrets.saveHostKeyPins(pins)
            RCLog.info("pinned the host key for \(pending.deviceID)")
        } catch {
            RCLog.error("the host key for \(pending.deviceID) could not be pinned: \(error.localizedDescription)")
        }
    }

    public func trustNewMac() throws {
        guard let mismatch else { return }
        var pins = try secrets.hostKeyPins()
        pins[mismatch.deviceID] = mismatch.presentedKey
        try secrets.saveHostKeyPins(pins)
        try secrets.forgetPeerCode(forHost: mismatch.deviceID)
        RCLog.info("replaced the pinned host key for \(mismatch.deviceID) at the user's request")
        self.mismatch = nil
    }

    public func dismissMismatch() {
        mismatch = nil
    }

    public func peerByeMayForgetCode(forHost deviceID: String?) -> Bool {
        guard let deviceID else { return true }
        return pinnedKey(forHost: deviceID) == nil
    }
}
