import Foundation
import RCTestKit
import RemoteControlCore
import SkipperCore

private let hostID = "482719351"
private let sessionA = String(repeating: "a", count: 32)
private let sessionB = String(repeating: "b", count: 32)
private let candidate = "candidate:1 1 udp 2122260223 192.168.1.20 61234 typ host"
private let certificateA = Data([0x30, 0x06, 0x02, 0x01, 0x01, 0x02, 0x01, 0x01]).base64EncodedString()
private let certificateB = Data([0x30, 0x06, 0x02, 0x01, 0x02, 0x02, 0x01, 0x02]).base64EncodedString()
private let certificateC = Data([0x30, 0x06, 0x02, 0x01, 0x03, 0x02, 0x01, 0x03]).base64EncodedString()

private func freshKey() throws -> String {
    try DeviceKey().publicKeyDER().base64EncodedString()
}

private func compressedSpelling(of key: String) throws -> String {
    let der = [UInt8](try expectNotNil(Data(base64Encoded: key)))
    let point = der.suffix(65)
    let prefixLength = der.count - 65
    var header = Array(der.prefix(prefixLength))
    header[1] -= 32
    header[prefixLength - 2] -= 32
    let y = point[point.startIndex + 64]
    let compressed = [UInt8(y & 1 == 1 ? 3 : 2)] + point[(point.startIndex + 1)..<(point.startIndex + 33)]
    return Data(header + compressed).base64EncodedString()
}

private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
    try Envelope.decode(Data(json.utf8)).decodePayload(T.self)
}

private func pakeFrame(step: String, extra: String = "") -> String {
    #"{"v":5,"type":"pake","payload":{"sessionId":"\#(sessionA)","step":\#(step),"payload":"QUJD"\#(extra)}}"#
}

private func grant(session: String = sessionA, host: String = hostID, hostKey: String?) -> SessionGrantPayload {
    SessionGrantPayload(sessionId: session, sessionToken: "t", expiresAt: 1, ttlSec: 600,
                        hostDeviceId: host, controllerDeviceId: "739000587", hostPubkey: hostKey)
}

@MainActor
private func withStore(_ body: @MainActor (IdentityStore, SecretStore, IdentityFileStore) async throws -> Void) async throws {
    let directory = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("rc-tests-v5-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let fileStore = IdentityFileStore(directory: directory)
    let secrets = SecretStore(blobs: InMemorySecretStore())
    try await body(try IdentityStore(fileStore: fileStore, secrets: secrets), secrets, fileStore)
}

public let protocolV5Suite = TestSuite("Protocol v5 client", [

    TestCase("the wire version is 5 and v4 frames are refused") {
        try expectEqual(Wire.version, 5)
        try expectEqual(Wire.MessageType.iceServers, "ice_servers")
        try await expectThrows("a v4 frame") {
            _ = try Envelope.decode(Data(#"{"v":4,"type":"heartbeat","payload":{}}"#.utf8))
        }
    },

    // MARK: - C1: pake steps are bounded at decode

    TestCase("review C1: a pake step of 2^32 is refused at decode, never a trap") {
        try expectEqual(try decode(PakePayload.self, pakeFrame(step: "2")).step, 2)
        for step in ["4294967296", "9223372036854775807", "-9223372036854775808", "0", "4", "-1", "2.5", "\"2\""] {
            try await expectThrows("step \(step)") {
                _ = try decode(PakePayload.self, pakeFrame(step: step))
            }
        }
        try await expectThrows("the typed decoder on its own, without the core's frame check") {
            _ = try JSONDecoder().decode(PakePayload.self, from: Data(
                #"{"sessionId":"\#(sessionA)","step":4294967296,"payload":"QUJD"}"#.utf8))
        }
    },

    TestCase("a PakeMessage built in code with a wild step is refused by the exchange") {
        let exchange = try PakeExchange.host(accessCode: "K7FM3Q8PW2XY", deviceID: hostID,
                                             sessionID: sessionA, ownPublicKey: try freshKey())
        for step in [Int(Int32.max) + 1, Int.max, Int.min, 0, 4, -1] {
            try expectNil(PakeMessage(step: step, payload: "QUJD").wireStep, "\(step)")
            try await expectThrows("step \(step)") {
                _ = try exchange.step(PakeMessage(step: step, payload: "QUJD"))
            }
        }
        try expectEqual(PakeMessage(step: 1, payload: "QUJD").wireStep, 1)
    },

    // MARK: - Relayed frames match their exact schema

    TestCase("relayed frames with unknown, miscased or duplicate keys are refused") {
        try await expectThrows("an unknown key") {
            _ = try Envelope.decode(Data(pakeFrame(step: "1", extra: #","extra":1"#).utf8))
        }
        try await expectThrows("a duplicate key") {
            _ = try Envelope.decode(Data(pakeFrame(step: "1", extra: #","step":1"#).utf8))
        }
        try await expectThrows("a miscased session id key") {
            _ = try Envelope.decode(Data(
                #"{"v":5,"type":"sdp","payload":{"SESSIONID":"\#(sessionA)","sessionId":"\#(sessionB)","sdpType":"offer","sdp":"v=0"}}"#.utf8))
        }
        try await expectThrows("an ice line that is not a candidate") {
            _ = try Envelope.decode(Data(
                #"{"v":5,"type":"ice","payload":{"sessionId":"\#(sessionA)","candidate":"c"}}"#.utf8))
        }
        try await expectThrows("an sdp that does not start with v=0") {
            _ = try Envelope.decode(Data(
                #"{"v":5,"type":"sdp","payload":{"sessionId":"\#(sessionA)","sdpType":"offer","sdp":"o=- 1"}}"#.utf8))
        }
        let ok = try Envelope.decode(Data(
            #"{"v":5,"type":"sdp","payload":{"sessionId":"\#(sessionA)","sdpType":"answer","sdp":"v=0\r\n","fp":"sha-256 AA"}}"#.utf8))
        try expectEqual(try ok.decodePayload(SDPPayload.self).sdpType, "answer")
        let bye = try Envelope.decode(Data(
            #"{"v":5,"type":"bye","payload":{"sessionId":"\#(sessionA)","reason":"x","extra":1}}"#.utf8))
        try expectEqual(bye.type, "bye", "only sdp, ice and pake are relayed peer payloads")
    },

    TestCase("retryAfterSec and sdpMLineIndex are bounded when decoded") {
        let negative = try Envelope.decode(Data(#"{"v":5,"type":"error","payload":{"code":"rate_limited","message":"m","retryAfterSec":-9}}"#.utf8))
        try expectNil(negative.asProtocolError?.retryAfterSec)
        let huge = try Envelope.decode(Data(#"{"v":5,"type":"error","payload":{"code":"rate_limited","message":"m","retryAfterSec":9223372036854775807}}"#.utf8))
        try expectEqual(huge.asProtocolError?.retryAfterSec, 86_400)

        try expectEqual(try decode(ICEPayload.self,
            #"{"v":5,"type":"ice","payload":{"sessionId":"\#(sessionA)","candidate":"\#(candidate)","sdpMLineIndex":1}}"#).sdpMLineIndex, 1)
        for index in ["-1", "65536", "4294967296", "9223372036854775807", "1.5"] {
            try await expectThrows("sdpMLineIndex \(index)") {
                _ = try decode(ICEPayload.self,
                    #"{"v":5,"type":"ice","payload":{"sessionId":"\#(sessionA)","candidate":"\#(candidate)","sdpMLineIndex":\#(index)}}"#)
            }
        }
    },

    // MARK: - TURN arrives with ice_servers

    TestCase("hello_ok, connect_ok and session_start keep only STUN; ice_servers and renew_ok carry TURN") {
        let hello = try decode(HelloOKPayload.self, #"""
        {"v":5,"type":"hello_ok","payload":{"deviceId":"482719351","serverTime":1,"heartbeatSec":15,
        "offlineAfterSec":40,"sessionTokenTtlSec":600,"iceServers":[
        {"urls":["stun:stun.example:3478"]},
        {"urls":["turn:turn.example:3478"],"username":"1:x","credential":"c"}]}}
        """#)
        try expectEqual(hello.iceServers, [ICEServerSpec(urls: ["stun:stun.example:3478"])])

        let stun = ICEServerSpec(urls: ["stun:stun.example:3478"])
        let turn = ICEServerSpec(urls: ["turn:turn.example:3478"], username: "600:\(sessionA)", credential: "c",
                                 expiresAt: 600_000)
        for type in ["connect_ok", "session_start"] {
            let data = try Envelope.encode(type: type, payload: SessionGrantPayload(
                sessionId: sessionA, sessionToken: "t", expiresAt: 1, ttlSec: 600,
                hostDeviceId: hostID, controllerDeviceId: "739000587", iceServers: [stun, turn]))
            let decoded = try Envelope.decode(data).decodePayload(SessionGrantPayload.self)
            try expectEqual(decoded.iceServers, [stun], "\(type) never hands out relay credentials")
        }

        let pushed = try decode(ICEServersPayload.self, #"""
        {"v":5,"type":"ice_servers","payload":{"sessionId":"\#(sessionA)","iceServers":[
        {"urls":["stun:stun.example:3478"]},
        {"urls":["turn:turn.example:3478"],"username":"600:\#(sessionA)","credential":"c","expiresAt":600000}]}}
        """#)
        try expectEqual(pushed, ICEServersPayload(sessionId: sessionA, iceServers: [stun, turn]))

        let renewed = try decode(RenewOKPayload.self, #"""
        {"v":5,"type":"renew_ok","payload":{"sessionId":"\#(sessionA)","sessionToken":"t","expiresAt":1,"ttlSec":600,
        "iceServers":[{"urls":["turn:turn.example:3478"],"username":"u","credential":"c"}]}}
        """#)
        try expectEqual(renewed.iceServers?.first?.username, "u")
    },

    TestCase("session relay credentials belong to one session and are dropped with it") {
        try await withStore { store, _, _ in
            let client = SignalingClient(identity: store, role: .controller)
            let turn = ICEServerSpec(urls: ["turn:turn.example:3478"], username: "u", credential: "c")
            try expectEqual(client.iceServers(forSession: sessionA), [])
            client.adoptSessionICEServers([turn], sessionID: sessionA)
            try expect(client.holdsSessionICECredentials)
            try expectEqual(client.iceServers(forSession: sessionA), [turn])
            try expectEqual(client.iceServers(forSession: sessionB), [], "another session never sees them")
            client.dropSessionICEServers()
            try expectFalse(client.holdsSessionICECredentials)
            try expectEqual(client.iceServers(forSession: sessionA), [])
        }
    },

    TestCase("a peer connection takes a new ICE server list without being rebuilt") {
        let peer = PeerSession(iceServers: [], isOfferer: true, forceTURNRelay: true)
        try peer.start()
        defer { peer.close() }
        let turn = ICEServerSpec(urls: ["turn:198.51.100.7:3478"], username: "u", credential: "c")
        try expect(peer.updateICEServers([turn]))
        try expectEqual(peer.iceServers, [turn])
        try expect(peer.isRelayOnly)
    },

    // MARK: - C4: Device ID certificates

    TestCase("re-registration sends the certificate and asks for the same id; a first registration asks for nothing") {
        try expectEqual(RegistrationRequest.make(deviceID: hostID, certificate: nil, afterUnknownDevice: false),
                        RegistrationRequest(preferredDeviceId: nil, idCert: nil))
        try expectEqual(RegistrationRequest.make(deviceID: hostID, certificate: certificateA, afterUnknownDevice: false),
                        RegistrationRequest(preferredDeviceId: hostID, idCert: certificateA))
        try expectEqual(RegistrationRequest.make(deviceID: hostID, certificate: nil, afterUnknownDevice: true),
                        RegistrationRequest(preferredDeviceId: hostID, idCert: nil))
        try expectEqual(RegistrationRequest.make(deviceID: "482 719 351", certificate: "", afterUnknownDevice: true),
                        RegistrationRequest(preferredDeviceId: hostID, idCert: nil),
                        "an empty certificate is never sent")
    },

    TestCase("only a DER-shaped certificate and a 9-digit id are ever stored") {
        try expect(DeviceIDCertificates.isWellFormed(certificateA))
        for bad in ["", "Y2VydA==", "not base64!", Data([0x30, 0x07, 0, 0, 0, 0, 0, 0]).base64EncodedString(),
                    Data([0x31, 0x06, 0, 0, 0, 0, 0, 0]).base64EncodedString(),
                    Data([0x30, 0x47] + [UInt8](repeating: 0, count: 71)).base64EncodedString()] {
            try expectFalse(DeviceIDCertificates.isWellFormed(bad), bad)
        }
        try await withStore { store, _, _ in
            try store.recordRegistration(deviceID: hostID, certificate: certificateA, presentedDeviceID: nil)
            try expectEqual(store.deviceIDCertificate, certificateA)
            do {
                try store.recordRegistration(deviceID: "739000587", certificate: "Y2VydA==", presentedDeviceID: hostID)
                throw fail("a malformed certificate must be refused")
            } catch let error as IdentityRegistrationError {
                try expectEqual(error, .malformedCertificate)
            }
            try expectEqual(store.deviceID, hostID, "nothing from a malformed register_ok is adopted")
            try expectEqual(store.deviceIDCertificate, certificateA)

            store.storeDeviceIDCertificate("Y2VydA==", forDeviceID: hostID)
            try expectEqual(store.deviceIDCertificate, certificateA, "hello_ok cannot store junk either")
            store.storeDeviceIDCertificate(certificateB, forDeviceID: "739000587")
            try expectEqual(store.deviceIDCertificate, certificateA, "nor a certificate for another id")
            store.storeDeviceIDCertificate(certificateB, forDeviceID: hostID)
            try expectEqual(store.deviceIDCertificate, certificateB, "a newer one for this id replaces the old one")
        }
    },

    TestCase("review C4: a reassigned id keeps the presented certificate to reclaim the first id") {
        try await withStore { store, secrets, fileStore in
            let key = store.publicKeyBase64
            try store.recordRegistration(deviceID: hostID, certificate: certificateA, presentedDeviceID: nil)
            try expectEqual(store.certificatePresentation?.deviceID, hostID)

            try store.recordRegistration(deviceID: "739000587", certificate: certificateB, presentedDeviceID: hostID)
            try expectEqual(store.deviceID, "739000587", "the new id is adopted")
            try expectEqual(store.deviceIDCertificate, certificateB, "and stored under the new id")
            let book = try secrets.deviceIDCertificates(currentDeviceID: store.deviceID)
            try expectEqual(book.certificate(for: hostID), certificateA, "the first certificate is not overwritten")
            try expectEqual(store.certificatePresentation?.deviceID, hostID)
            try expectEqual(store.certificatePresentation?.certificate, certificateA,
                            "the next reset presents the first id's certificate")

            let relaunched = try IdentityStore(fileStore: fileStore, secrets: secrets)
            try expectEqual(relaunched.certificatePresentation?.certificate, certificateA, "and it survives a relaunch")
            try expectEqual(relaunched.publicKeyBase64, key)

            try relaunched.recordRegistration(deviceID: "913004287", certificate: certificateC,
                                              presentedDeviceID: hostID)
            let twice = try secrets.deviceIDCertificates(currentDeviceID: relaunched.deviceID)
            try expectEqual(Set(twice.byDeviceID.keys), [hostID, "913004287"], "at most two are ever held")

            try relaunched.recordRegistration(deviceID: hostID, certificate: certificateA, presentedDeviceID: hostID)
            try expectEqual(relaunched.deviceID, hostID)
            let reclaimed = try secrets.deviceIDCertificates(currentDeviceID: hostID)
            try expectEqual(reclaimed, DeviceIDCertificates(byDeviceID: [hostID: certificateA]),
                            "winning the id back leaves only its certificate")
        }
    },

    TestCase("a certificate stored before v5 still belongs to this Mac's id") {
        try await withStore { store, _, _ in
            let blobs = InMemorySecretStore()
            try blobs.save(try JSONEncoder().encode(certificateA), for: .deviceIDCertificate)
            let legacy = try SecretStore(blobs: blobs).deviceIDCertificates(currentDeviceID: store.deviceID)
            try expectEqual(legacy.certificate(for: store.deviceID), certificateA)
            store.storeDeviceIDCertificate(nil, forDeviceID: store.deviceID)
            try expectNil(store.deviceIDCertificate)
        }
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

    // MARK: - Host key pins (C3, C6)

    TestCase("pin decisions: first use, match, pending replacement, mismatch") {
        let key = try freshKey()
        let pending = try freshKey()
        try expectEqual(HostKeyPins.decide(pinned: nil, presented: key), .firstUse)
        try expectEqual(HostKeyPins.decide(pinned: nil, presented: nil), .firstUse)
        try expectEqual(HostKeyPins.decide(pinned: key, presented: key), .match)
        try expectEqual(HostKeyPins.decide(pinned: key, presented: try freshKey()), .mismatch)
        try expectEqual(HostKeyPins.decide(pinned: key, presented: pending, pending: pending), .pendingReplacement)
        try expectEqual(HostKeyPins.decide(pinned: key, presented: nil), .mismatch,
                        "a pinned host that stops naming its key is not trusted")
        try expectEqual(HostKeyPins.decide(pinned: key, presented: "not base64!"), .mismatch)
    },

    TestCase("review C6: another spelling of the pinned key is the same Mac") {
        let key = try freshKey()
        let compressed = try compressedSpelling(of: key)
        try expectNotEqual(compressed, key)
        try expectEqual(HostKeyPins.canonicalKey(compressed), key)
        try expectEqual(HostKeyPins.decide(pinned: key, presented: compressed), .match)
        try expectEqual(HostKeyPins.decide(pinned: compressed, presented: key), .match)
        try expect(DevicePublicKey.same(key, compressed))
        try expectFalse(DevicePublicKey.same(key, try freshKey()))
        try expectFalse(DevicePublicKey.same(nil, key))
        try expectEqual(try DevicePublicKey.fingerprint(compressed), try DevicePublicKey.fingerprint(key),
                        "and shows the same fingerprint")
        try expectNil(HostKeyPins.canonicalKey(Data("not a key".utf8).base64EncodedString()))
    },

    TestCase("a host key is pinned only after the session proved the code") {
        try await withStore { store, secrets, _ in
            let pins = store.hostKeyPins
            let key = try freshKey()
            try pins.admit(grant(hostKey: key))
            try expectNil(pins.pinnedKey(forHost: hostID), "connect_ok alone pins nothing")
            pins.confirm(sessionID: sessionB, hostPubkey: key)
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
            try expectFalse(pins.mayForgetCode(forHost: hostID),
                            "review C3a: neither a failed exchange nor a bye can wipe a pinned host's code")
            try expect(pins.mayForgetCode(forHost: "739000587"))

            pins.confirm(sessionID: sessionA, hostPubkey: impostor)
            try expectEqual(pins.pinnedKey(forHost: hostID), original, "a refused session never pins")

            pins.dismissMismatch()
            try expectNil(pins.mismatch)
            try expectEqual(pins.pinnedKey(forHost: hostID), original, "Cancel changes nothing")
        }
    },

    TestCase("review C3b: Trust the new computer replaces the pin only after the new key proves the code") {
        try await withStore { store, secrets, _ in
            let pins = store.hostKeyPins
            let original = try freshKey()
            let replacement = try freshKey()
            try secrets.saveHostKeyPins([hostID: original, "739000587": "b3RoZXI="])
            try secrets.rememberPeerCode(try AccessCode.generate(), forHost: hostID)
            try await expectThrows("the mismatch") { try pins.admit(grant(hostKey: replacement)) }

            try pins.trustNewMac()
            try expectNil(pins.mismatch)
            try expectEqual(pins.pinnedKey(forHost: hostID), original, "the old pin stays until the proof")
            try expectEqual(pins.pendingKey(forHost: hostID), replacement)
            try expectEqual(pins.pinnedKey(forHost: "739000587"), "b3RoZXI=", "other hosts keep their pins")
            try expectNil(try secrets.peerCode(forHost: hostID), "the code must be typed again")
            try expectFalse(pins.mayForgetCode(forHost: hostID))

            try await expectThrows("a third key") { try pins.admit(grant(hostKey: try freshKey())) }
            try pins.admit(grant(session: sessionB, hostKey: replacement))
            try expectNil(pins.mismatch, "the pending key may run the exchange")
            pins.confirm(sessionID: sessionA, hostPubkey: replacement)
            try expectEqual(pins.pinnedKey(forHost: hostID), original, "a proof for another session does not count")

            try pins.admit(grant(session: sessionA, hostKey: replacement))
            try expectEqual(pins.pinnedKey(forHost: hostID), original, "a failed exchange replaces nothing")

            try pins.admit(grant(session: sessionB, hostKey: try compressedSpelling(of: replacement)))
            pins.confirm(sessionID: sessionB, hostPubkey: replacement)
            try expectEqual(pins.pinnedKey(forHost: hostID), replacement, "the proven key is now the pin")
            try expectNil(pins.pendingKey(forHost: hostID))
            try pins.admit(grant(hostKey: replacement))
            try expectNil(pins.mismatch)
            try await expectThrows("the old key is no longer trusted") {
                try pins.admit(grant(hostKey: original))
            }
        }
    },

    TestCase("Refresh Code resets per-controller counters but never the host-wide budget") {
        try await withStore { store, secrets, _ in
            let controller = try freshKey()
            let recent = Int64(Date().timeIntervalSince1970 * 1000)
            let perController = GuessCounter(failures: 4, lastFailureMs: recent)
            let hostWide = GuessCounter(failures: 17, lastFailureMs: recent)
            try secrets.saveGuessCounter(perController, forController: controller)
            try secrets.saveGuessCounter(hostWide, forController: GuessLedger.hostKey)
            try secrets.recordTrustedController(pubkey: controller, label: "a Mac")

            try secrets.revokeControllers()
            try expectEqual(try secrets.guessCounter(forController: controller), perController)
            try expectEqual(try secrets.guessCounter(forController: GuessLedger.hostKey), hostWide)

            _ = try? await store.refreshAccessCode()
            try expect(try secrets.trustedControllers().isEmpty)
            try expectNil(try secrets.guessCounter(forController: controller),
                          "a new code gives each controller a fresh per-key count")
            try expectEqual(try secrets.guessCounter(forController: GuessLedger.hostKey), hostWide,
                            "but the host-wide budget is untouched")
        }
    },

    TestCase("this Mac's fingerprint is the six-group form the other Mac's prompt shows") {
        try await withStore { store, _, _ in
            let fingerprint = try DevicePublicKey.fingerprint(store.publicKeyBase64)
            let groups = fingerprint.split(separator: " ")
            try expectEqual(groups.count, 6)
            try expect(groups.allSatisfy { $0.count == 4 && $0.allSatisfy(\.isHexDigit) && $0.uppercased() == $0 })
            try await expectThrows("a non-key") { _ = try DevicePublicKey.fingerprint("host") }

            let prompt = ConsentRequest(
                promptID: "p", controllerLabel: "Other Mac", controllerDeviceID: "567397415",
                controllerFingerprint: fingerprint, expiresAt: Date().addingTimeInterval(30))
            try expectEqual(prompt.fingerprintLine, DevicePublicKey.fingerprintLine(fingerprint))
            try expectEqual(prompt.fingerprintLine, "Fingerprint \(fingerprint)")
            try expect(!fingerprint.hasPrefix("MFkwEwYHKoZIzj0"),
                       "a trusted row must not fall back to the shared DER prefix of the key")
        }
    },
])
