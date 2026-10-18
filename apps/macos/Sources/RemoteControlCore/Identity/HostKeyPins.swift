import Foundation
import SkipperCore

// Host keys pinned per Device ID on the controller (PROTOCOL.md v4 changes).
// A key becomes a pin only after a session with it proved the access code;
// "Trust the new computer" stores the presented key as pending, and it replaces the
// pin only once a later exchange with that host succeeds.

public enum HostKeyPinDecision: Equatable {
    case firstUse
    case match
    case pendingReplacement
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
    public static let changedSentence = "This Device ID now belongs to a different computer. If you reinstalled or "
        + "replaced that computer, choose Trust the new computer; otherwise don't connect."

    @Published public private(set) var mismatch: HostKeyMismatch?

    private let secrets: SecretStore
    private var awaitingProof: (sessionID: String, deviceID: String, key: String)?

    public init(secrets: SecretStore) {
        self.secrets = secrets
    }

    public static func canonicalKey(_ key: String?) -> String? {
        guard let key, !key.isEmpty else { return nil }
        return try? DevicePublicKey.canonical(key)
    }

    public static func decide(pinned: String?, presented: String?, pending: String? = nil) -> HostKeyPinDecision {
        guard let pinned = canonicalKey(pinned) else { return .firstUse }
        guard let presented = canonicalKey(presented) else { return .mismatch }
        if presented == pinned { return .match }
        return presented == canonicalKey(pending) ? .pendingReplacement : .mismatch
    }

    public func pinnedKey(forHost deviceID: String) -> String? {
        read { try $0.hostKeyPins()[deviceID] }
    }

    public func pendingKey(forHost deviceID: String) -> String? {
        read { try $0.pendingHostKeys()[deviceID] }
    }

    public func decision(forHost deviceID: String, presentedKey: String?) throws -> HostKeyPinDecision {
        Self.decide(pinned: try secrets.hostKeyPins()[deviceID],
                    presented: presentedKey,
                    pending: try secrets.pendingHostKeys()[deviceID])
    }

    /// `connect_ok`: a pinned host must present its pin, or the key the user
    /// chose to trust; either way the exchange must then prove it.
    public func admit(_ grant: SessionGrantPayload) throws {
        awaitingProof = nil
        let deviceID = grant.hostDeviceId
        let presented = Self.canonicalKey(grant.hostPubkey)
        switch try decision(forHost: deviceID, presentedKey: grant.hostPubkey) {
        case .match:
            mismatch = nil
        case .firstUse, .pendingReplacement:
            mismatch = nil
            if let presented {
                awaitingProof = (grant.sessionId, deviceID, presented)
            }
        case .mismatch:
            RCLog.error("host key for \(deviceID) differs from the pinned key; refusing before the access-code exchange")
            mismatch = HostKeyMismatch(deviceID: deviceID, presentedKey: presented)
            throw WireError.protocolError(code: Self.changedCode, message: Self.changedSentence, retryAfterSec: 0)
        }
    }

    /// The exchange for `sessionID` proved `hostPubkey`: a first-use key
    /// becomes the pin, and a pending key replaces it.
    public func confirm(sessionID: String, hostPubkey: String) {
        guard let proof = awaitingProof, proof.sessionID == sessionID,
              Self.canonicalKey(hostPubkey) == proof.key else { return }
        awaitingProof = nil
        do {
            var pins = try secrets.hostKeyPins()
            var pending = try secrets.pendingHostKeys()
            let replacing = pending[proof.deviceID] == proof.key
            guard pins[proof.deviceID] == nil || replacing else { return }
            pins[proof.deviceID] = proof.key
            try secrets.saveHostKeyPins(pins)
            if replacing {
                pending[proof.deviceID] = nil
                try secrets.savePendingHostKeys(pending)
            }
            RCLog.info("pinned the host key for \(proof.deviceID)")
        } catch {
            RCLog.error("the host key for \(proof.deviceID) could not be pinned: \(error.localizedDescription)")
        }
    }

    /// Keeps the pin until the new key proves the access code.
    public func trustNewMac() throws {
        guard let mismatch, let presented = mismatch.presentedKey else { return }
        var pending = try secrets.pendingHostKeys()
        pending[mismatch.deviceID] = presented
        try secrets.savePendingHostKeys(pending)
        try secrets.forgetPeerCode(forHost: mismatch.deviceID)
        RCLog.info("the host key for \(mismatch.deviceID) will be replaced once the new computer proves its code")
        self.mismatch = nil
    }

    public func dismissMismatch() {
        mismatch = nil
    }

    /// A failed exchange or an unauthenticated bye may wipe a remembered code
    /// only for a host that has never proved a key.
    public func mayForgetCode(forHost deviceID: String?) -> Bool {
        guard let deviceID else { return true }
        return pinnedKey(forHost: deviceID) == nil
    }

    private func read(_ body: (SecretStore) throws -> String?) -> String? {
        do {
            return try body(secrets)
        } catch {
            RCLog.error("host key pins could not be read: \(error.localizedDescription)")
            return nil
        }
    }
}
