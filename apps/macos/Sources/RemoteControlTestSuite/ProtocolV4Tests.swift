import Foundation
import RCTestKit
import RemoteControlCore
import SkipperCore

private let hostID = "482719351"
private let sessionA = String(repeating: "a", count: 32)
private let sessionB = String(repeating: "b", count: 32)

private func freshKey() throws -> String {
    try DeviceKey().publicKeyDER().base64EncodedString()
}

private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
    try Envelope.decode(Data(json.utf8)).decodePayload(T.self)
}

private func grant(session: String = sessionA, host: String = hostID, hostKey: String?) -> SessionGrantPayload {
    SessionGrantPayload(sessionId: session, sessionToken: "t", expiresAt: 1, ttlSec: 600,
                        hostDeviceId: host, controllerDeviceId: "739000587", hostPubkey: hostKey)
}

@MainActor
private func withStore(_ body: @MainActor (IdentityStore, SecretStore, IdentityFileStore) async throws -> Void) async throws {
    let directory = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("rc-tests-v4-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let fileStore = IdentityFileStore(directory: directory)
    let secrets = SecretStore(blobs: InMemorySecretStore())
    try await body(try IdentityStore(fileStore: fileStore, secrets: secrets), secrets, fileStore)
}

public let protocolV4Suite = TestSuite("Protocol v4 client", [

    TestCase("the wire version is 4 and v3 frames are refused") {
        try expectEqual(Wire.version, 4)
        try await expectThrows("a v3 frame") {
            _ = try Envelope.decode(Data(#"{"v":3,"type":"heartbeat","payload":{}}"#.utf8))
        }
    },

    TestCase("register carries the certificate and the preferred id; register_ok and hello_ok return one") {
        let data = try Envelope.encode(type: "register", payload: RegisterPayload(
            pubkey: "cHVi", sig: "c2ln", label: nil, preferredDeviceId: hostID, idCert: "Y2VydA=="))
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let payload = try expectNotNil(object?["payload"] as? [String: Any])
        try expectEqual(payload["idCert"] as? String, "Y2VydA==")
        try expectEqual(payload["preferredDeviceId"] as? String, hostID)

        let registered = try decode(RegisterOKPayload.self,
            #"{"v":4,"type":"register_ok","payload":{"deviceId":"482719351","existing":false,"idCert":"Y2VydA=="}}"#)
        try expectEqual(registered.idCert, "Y2VydA==")
        let hello = try decode(HelloOKPayload.self,
            #"{"v":4,"type":"hello_ok","payload":{"deviceId":"482719351","serverTime":1,"heartbeatSec":15,"offlineAfterSec":40,"sessionTokenTtlSec":600,"idCert":"Y2VydA=="}}"#)
        try expectEqual(hello.idCert, "Y2VydA==")
        try expect(hello.iceServers.isEmpty, "hello_ok may omit iceServers entirely")
    },

    TestCase("re-registration sends the certificate and asks for the same id; a first registration asks for nothing") {
        try expectEqual(RegistrationRequest.make(deviceID: hostID, certificate: nil, afterUnknownDevice: false),
                        RegistrationRequest(preferredDeviceId: nil, idCert: nil))
        try expectEqual(RegistrationRequest.make(deviceID: hostID, certificate: "Y2VydA==", afterUnknownDevice: false),
                        RegistrationRequest(preferredDeviceId: hostID, idCert: "Y2VydA=="))
        try expectEqual(RegistrationRequest.make(deviceID: hostID, certificate: nil, afterUnknownDevice: true),
                        RegistrationRequest(preferredDeviceId: hostID, idCert: nil))
        try expectEqual(RegistrationRequest.make(deviceID: "482 719 351", certificate: "", afterUnknownDevice: true),
                        RegistrationRequest(preferredDeviceId: hostID, idCert: nil),
                        "an empty certificate is never sent")
    },

    TestCase("the Device ID certificate is kept in secure storage and survives a relaunch") {
        try await withStore { store, secrets, fileStore in
            try expectNil(store.deviceIDCertificate)
            store.storeDeviceIDCertificate(nil)
            store.storeDeviceIDCertificate("")
            try expectNil(try secrets.deviceIDCertificate(), "nothing is stored for a missing certificate")

            store.storeDeviceIDCertificate("Y2VydA==")
            try expectEqual(try secrets.deviceIDCertificate(), "Y2VydA==")
            let key = store.publicKeyBase64
            let relaunched = try IdentityStore(fileStore: fileStore, secrets: secrets)
            try expectEqual(relaunched.deviceIDCertificate, "Y2VydA==")
            try expectEqual(relaunched.publicKeyBase64, key, "a certificate never means a new key")

            relaunched.storeDeviceIDCertificate("bmV3")
            try expectEqual(relaunched.deviceIDCertificate, "bmV3", "a newer certificate replaces the old one")
            secrets.discardEverything()
            try expectNil(relaunched.deviceIDCertificate, "a deliberate reset drops the certificate with the key")
        }
    },

    TestCase("hello_ok keeps only STUN; TURN arrives with the session") {
        let hello = try decode(HelloOKPayload.self, #"""
        {"v":4,"type":"hello_ok","payload":{"deviceId":"482719351","serverTime":1,"heartbeatSec":15,
        "offlineAfterSec":40,"sessionTokenTtlSec":600,"iceServers":[
        {"urls":["stun:stun.example:3478"]},
        {"urls":["turn:turn.example:3478"],"username":"1:x","credential":"c"}]}}
        """#)
        try expectEqual(hello.iceServers, [ICEServerSpec(urls: ["stun:stun.example:3478"])])

        let turn = ICEServerSpec(urls: ["turn:turn.example:3478"], username: "7200:\(sessionA)", credential: "c",
                                 expiresAt: 7_200_000)
        for type in ["connect_ok", "session_start"] {
            let data = try Envelope.encode(type: type, payload: SessionGrantPayload(
                sessionId: sessionA, sessionToken: "t", expiresAt: 1, ttlSec: 600,
                hostDeviceId: hostID, controllerDeviceId: "739000587", iceServers: [turn]))
            let decoded = try Envelope.decode(data).decodePayload(SessionGrantPayload.self)
            try expectEqual(decoded.iceServers, [turn], type)
            try expect(decoded.iceServers?.first?.carriesCredentials == true)
        }
        let renewed = try decode(RenewOKPayload.self, #"""
        {"v":4,"type":"renew_ok","payload":{"sessionId":"\#(sessionA)","sessionToken":"t","expiresAt":1,"ttlSec":600,
        "iceServers":[{"urls":["turn:turn.example:3478"],"username":"u","credential":"c"}]}}
        """#)
        try expectEqual(renewed.iceServers?.first?.username, "u")
        let legacyRenew = try decode(RenewOKPayload.self, #"""
        {"v":4,"type":"renew_ok","payload":{"sessionId":"\#(sessionA)","sessionToken":"t","expiresAt":1,"ttlSec":600}}
        """#)
        try expectNil(legacyRenew.iceServers)
    },

    TestCase("heartbeat intervals outside 1...300 seconds fall back to 15") {
        for (sent, used) in [(15, 15), (1, 1), (300, 300), (0, 15), (-5, 15), (301, 15), (Int.max, 15), (Int.min, 15)] {
            let hello = HelloOKPayload(deviceId: hostID, serverTime: 1, heartbeatSec: sent,
                                       offlineAfterSec: 40, sessionTokenTtlSec: 600)
            try expectEqual(hello.heartbeatInterval, TimeInterval(used), "heartbeatSec \(sent)")
        }
        try expectEqual(WireBounds.heartbeatSeconds(nil), 15)
        try expectEqual(WireBounds.nanoseconds(-1), 0)
        try expectEqual(WireBounds.nanoseconds(.nan), 0)
        try expectEqual(WireBounds.nanoseconds(.infinity), 0)
        try expectEqual(WireBounds.nanoseconds(1e30), 86_400 * 1_000_000_000, "a huge delay is capped, never a trap")
        try expectEqual(WireBounds.nanoseconds(0.5), 500_000_000)
    },

    TestCase("retryAfterSec and sdpMLineIndex are bounded when decoded") {
        let negative = try Envelope.decode(Data(#"{"v":4,"type":"error","payload":{"code":"rate_limited","message":"m","retryAfterSec":-9}}"#.utf8))
        try expectNil(negative.asProtocolError?.retryAfterSec)
        let huge = try Envelope.decode(Data(#"{"v":4,"type":"error","payload":{"code":"rate_limited","message":"m","retryAfterSec":9223372036854775807}}"#.utf8))
        try expectEqual(huge.asProtocolError?.retryAfterSec, 86_400)

        try expectEqual(try decode(ICEPayload.self,
            #"{"v":4,"type":"ice","payload":{"sessionId":"s","candidate":"c","sdpMLineIndex":1}}"#).sdpMLineIndex, 1)
        for index in ["-1", "4294967296", "9223372036854775807"] {
            try await expectThrows("sdpMLineIndex \(index)") {
                _ = try decode(ICEPayload.self,
                    #"{"v":4,"type":"ice","payload":{"sessionId":"s","candidate":"c","sdpMLineIndex":\#(index)}}"#)
            }
        }
    },

    TestCase("rate_limited on connect reads as the plan sentence and holds further connects back") {
        let wire = WireError.protocolError(code: Wire.ErrorCode.rateLimited, message: "slow down", retryAfterSec: 90)
        try expectEqual(EntitlementPresentation.sentence(for: ConnectFailure(wire)),
                        "Too many attempts. Try again in 2 min.")

        let now = Date(timeIntervalSince1970: 1_000_000)
        let until = ConnectRateGate.allowedAfter(retryAfterSec: 90, now: now)
        try expectEqual(ConnectRateGate.remainingSeconds(until: until, now: now), 90)
        try expectEqual(ConnectRateGate.remainingSeconds(until: until, now: now.addingTimeInterval(89.5)), 1)
        try expectNil(ConnectRateGate.remainingSeconds(until: until, now: now.addingTimeInterval(90)))
        try expectNil(ConnectRateGate.remainingSeconds(until: nil, now: now))
        try expectEqual(ConnectRateGate.remainingSeconds(
            until: ConnectRateGate.allowedAfter(retryAfterSec: nil, now: now), now: now), 60,
            "a limit without a retry hint still backs off")
    },

    TestCase("pin decisions: first use, match, mismatch") {
        let key = try freshKey()
        try expectEqual(HostKeyPins.decide(pinned: nil, presented: key), .firstUse)
        try expectEqual(HostKeyPins.decide(pinned: nil, presented: nil), .firstUse)
        try expectEqual(HostKeyPins.decide(pinned: key, presented: key), .match)
        try expectEqual(HostKeyPins.decide(pinned: key, presented: try freshKey()), .mismatch)
        try expectEqual(HostKeyPins.decide(pinned: key, presented: nil), .mismatch,
                        "a pinned host that stops naming its key is not trusted")
        try expectEqual(HostKeyPins.decide(pinned: key, presented: "not base64!"), .mismatch)
    },

    TestCase("a host key is pinned only after the session proved the code") {
        try await withStore { store, secrets, _ in
            let pins = store.hostKeyPins
            let key = try freshKey()
            try pins.admit(grant(hostKey: key))
            try expectNil(pins.pinnedKey(forHost: hostID), "connect_ok alone pins nothing")
            pins.confirm(sessionID: sessionB)
            try expectNil(pins.pinnedKey(forHost: hostID), "another session's proof does not count")
            pins.confirm(sessionID: sessionA, hostPubkey: try freshKey())
            try expectNil(pins.pinnedKey(forHost: hostID), "a proof for a different key does not count")
            pins.confirm(sessionID: sessionA, hostPubkey: key)
            try expectEqual(try secrets.hostKeyPins(), [hostID: key])
            try pins.admit(grant(session: sessionB, hostKey: key))
            try expectNil(pins.mismatch)
        }
    },

    TestCase("a changed host key stops the connect and keeps the remembered code") {
        try await withStore { store, secrets, _ in
            let pins = store.hostKeyPins
            let original = try freshKey()
            let impostor = try freshKey()
            let code = try AccessCode.generate()
            try secrets.saveHostKeyPins([hostID: original])
            try secrets.rememberPeerCode(code, forHost: hostID)

            do {
                try pins.admit(grant(hostKey: impostor))
                throw fail("a different key for a pinned Device ID must be refused")
            } catch let error as WireError {
                try expectEqual(error.serverCode, HostKeyPins.changedCode)
                try expectEqual(ConnectFailure(error).code, HostKeyPins.changedCode)
            }
            try expectEqual(pins.mismatch, HostKeyMismatch(deviceID: hostID, presentedKey: impostor))
            try expectEqual(try secrets.peerCode(forHost: hostID), code, "the remembered code is kept")
            try expectEqual(pins.pinnedKey(forHost: hostID), original)
            try expectFalse(pins.peerByeMayForgetCode(forHost: hostID),
                            "an unauthenticated bye cannot wipe a pinned host's code")
            try expect(pins.peerByeMayForgetCode(forHost: "739000587"))

            pins.confirm(sessionID: sessionA, hostPubkey: impostor)
            try expectEqual(pins.pinnedKey(forHost: hostID), original, "a refused session never pins")

            pins.dismissMismatch()
            try expectNil(pins.mismatch)
            try expectEqual(pins.pinnedKey(forHost: hostID), original, "Cancel changes nothing")
        }
    },

    TestCase("Trust the new Mac replaces the pin and forgets the remembered code") {
        try await withStore { store, secrets, _ in
            let pins = store.hostKeyPins
            let replacement = try freshKey()
            try secrets.saveHostKeyPins([hostID: try freshKey(), "739000587": "b3RoZXI="])
            try secrets.rememberPeerCode(try AccessCode.generate(), forHost: hostID)
            try await expectThrows("the mismatch") { try pins.admit(grant(hostKey: replacement)) }

            try pins.trustNewMac()
            try expectNil(pins.mismatch)
            try expectEqual(pins.pinnedKey(forHost: hostID), replacement)
            try expectEqual(pins.pinnedKey(forHost: "739000587"), "b3RoZXI=", "other hosts keep their pins")
            try expectNil(try secrets.peerCode(forHost: hostID), "the code must be typed again")
            try pins.admit(grant(session: sessionB, hostKey: replacement))
            try expectNil(pins.mismatch)
        }
    },

    TestCase("Refresh Code resets per-controller counters but never the host-wide budget") {
        try await withStore { store, secrets, _ in
            let controller = try freshKey()
            try secrets.saveGuessCounter(GuessCounter(failures: 4), forController: controller)
            try secrets.saveGuessCounter(GuessCounter(failures: 17), forController: GuessLedger.hostKey)
            try secrets.recordTrustedController(pubkey: controller, label: "a Mac")

            try secrets.revokeControllers()
            try expectEqual(try secrets.guessCounter(forController: controller), GuessCounter(failures: 4))
            try expectEqual(try secrets.guessCounter(forController: GuessLedger.hostKey), GuessCounter(failures: 17))

            _ = try? await store.refreshAccessCode()
            try expect(try secrets.trustedControllers().isEmpty)
            try expectNil(try secrets.guessCounter(forController: controller),
                          "a new code gives each controller a fresh per-key count")
            try expectEqual(try secrets.guessCounter(forController: GuessLedger.hostKey), GuessCounter(failures: 17),
                            "but the host-wide budget is untouched")
        }
    },
])
