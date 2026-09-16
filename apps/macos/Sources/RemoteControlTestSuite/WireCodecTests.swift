import Foundation
import RCTestKit
import RemoteControlCore

/// Re-encodes a payload inside an envelope and reads it back, asserting the
/// envelope metadata survives too. A codec that dropped `re` or mangled `v`
/// would pass a bare `Codable` round-trip and fail this.
private func roundTrip<T: Codable & Equatable>(_ type: String, _ payload: T) throws -> T {
    let data = try Envelope.encode(type: type, id: "c-42", re: "r-7", ts: 1_755_600_000_000, payload: payload)
    let envelope = try Envelope.decode(data)
    try expectEqual(envelope.v, 1)
    try expectEqual(envelope.type, type)
    try expectEqual(envelope.id, "c-42")
    try expectEqual(envelope.re, "r-7")
    try expectEqual(envelope.ts, 1_755_600_000_000)
    return try envelope.decodePayload(T.self)
}

public let wireCodecSuite = TestSuite("Wire codec (PROTOCOL.md §0, §2, §5, §6)", [

    TestCase("the envelope is exactly the documented shape") {
        let data = try Envelope.encode(type: "connect_req", id: "c-17",
                                       payload: ConnectReqPayload(deviceId: "481930275", accessCode: "K7FM3Q8PW2XY"))
        let object = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        try expectEqual(object["v"] as? Int, 1)
        try expectEqual(object["type"] as? String, "connect_req")
        try expectEqual(object["id"] as? String, "c-17")
        try expectNil(object["re"], "re must be absent, not null, on a request")
        let payload = try expectNotNil(object["payload"] as? [String: Any])
        try expectEqual(payload["deviceId"] as? String, "481930275")
        try expectEqual(payload["accessCode"] as? String, "K7FM3Q8PW2XY")
    },

    TestCase("a version other than 1 is refused") {
        let bad = Data(#"{"v":2,"type":"hello","payload":{}}"#.utf8)
        do {
            _ = try Envelope.decode(bad)
            throw fail("decoding v=2 must throw")
        } catch let error as WireError {
            try expectEqual(error, .unsupportedVersion(2))
        }
    },

    TestCase("a frame with no type, and a non-object frame, are refused") {
        do { _ = try Envelope.decode(Data(#"{"v":1,"payload":{}}"#.utf8)); throw fail("missing type must throw") }
        catch let error as WireError { try expectEqual(error, .missingType) }
        do { _ = try Envelope.decode(Data("[1,2,3]".utf8)); throw fail("a JSON array must throw") }
        catch let error as WireError { try expectEqual(error, .notJSONObject) }
    },

    TestCase("an absent or null payload decodes as {}, matching the Go side") {
        let absent = try Envelope.decode(Data(#"{"v":1,"type":"heartbeat"}"#.utf8))
        _ = try absent.decodePayload(EmptyPayload.self)
        let null = try Envelope.decode(Data(#"{"v":1,"type":"heartbeat","payload":null}"#.utf8))
        _ = try null.decodePayload(EmptyPayload.self)
    },

    TestCase("unknown payload members are ignored, as receivers must") {
        let frame = Data(#"{"v":1,"type":"presence","payload":{"deviceId":"481930275","online":true,"since":5,"future":42}}"#.utf8)
        let presence = try Envelope.decode(frame).decodePayload(PresencePayload.self)
        try expectEqual(presence, PresencePayload(deviceId: "481930275", online: true, since: 5))
    },

    // ---- every signaling payload -----------------------------------------

    TestCase("challenge round-trips") {
        let value = ChallengePayload(nonce: "bm9uY2U=", serverTime: 1_755_600_000_000)
        try expectEqual(try roundTrip("challenge", value), value)
    },

    TestCase("register + the code verifier round-trip with the exact Go field names") {
        let verifier = CodeVerifier(salt: "c2FsdA==", hash: "aGFzaA==", time: 3, memKiB: 65536, par: 1, len: 32)
        let value = RegisterPayload(pubkey: "cHVi", sig: "c2ln", label: "Studio Mac", code: verifier)
        try expectEqual(try roundTrip("register", value), value)

        let data = try Envelope.encode(type: "register", payload: value)
        let object = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        let code = (object["payload"] as! [String: Any])["code"] as! [String: Any]
        try expectEqual(code["alg"] as? String, "argon2id")
        try expectEqual(code["memKiB"] as? Int, 65536)   // NOT memKib, NOT memoryKiB
        try expectEqual(code["par"] as? Int, 1)
        try expectEqual(code["len"] as? Int, 32)
        try expectEqual(code["time"] as? Int, 3)
    },

    TestCase("register_ok round-trips") {
        let value = RegisterOKPayload(deviceId: "481930275", existing: true)
        try expectEqual(try roundTrip("register_ok", value), value)
    },

    TestCase("hello round-trips") {
        let value = HelloPayload(deviceId: "481930275", pubkey: "cHVi", sig: "c2ln", role: "host")
        try expectEqual(try roundTrip("hello", value), value)
    },

    TestCase("hello_ok round-trips, with and without an active session") {
        let servers = [
            ICEServerSpec(urls: ["stun:stun.l.google.com:19302"]),
            ICEServerSpec(urls: ["turn:54.246.73.81:3478?transport=udp"],
                          username: "1755600000:481930275", credential: "Y3JlZA==",
                          expiresAt: 1_755_643_200_000),
        ]
        let bare = HelloOKPayload(deviceId: "481930275", serverTime: 1, iceServers: servers,
                                  heartbeatSec: 15, offlineAfterSec: 40, sessionTokenTtlSec: 600)
        try expectEqual(try roundTrip("hello_ok", bare), bare)
        try expectNil(try roundTrip("hello_ok", bare).activeSessionId)

        var resumable = bare
        resumable.activeSessionId = String(repeating: "a", count: 32)
        try expectEqual(try roundTrip("hello_ok", resumable), resumable)
    },

    TestCase("heartbeat_ok, watch, unwatch and presence round-trip") {
        try expectEqual(try roundTrip("heartbeat_ok", HeartbeatOKPayload(serverTime: 9)).serverTime, 9)
        let device = DeviceIDPayload(deviceId: "481930275")
        try expectEqual(try roundTrip("watch", device), device)
        try expectEqual(try roundTrip("unwatch", device), device)
        let presence = PresencePayload(deviceId: "481930275", online: false, since: 0)
        try expectEqual(try roundTrip("presence", presence), presence)
    },

    TestCase("connect_req round-trips and never prints the access code") {
        let value = ConnectReqPayload(deviceId: "481930275", accessCode: "K7FM3Q8PW2XY")
        try expectEqual(try roundTrip("connect_req", value), value)
        try expectFalse("\(value)".contains("K7FM3Q8PW2XY"), "description must redact the plaintext code")
        try expect("\(value)".contains("redacted"))
    },

    TestCase("connect_ok / session_start round-trip and redact the token") {
        let value = SessionGrantPayload(sessionId: String(repeating: "b", count: 32),
                                        sessionToken: "tok.en", expiresAt: 2, ttlSec: 600,
                                        hostDeviceId: "481930275", controllerDeviceId: "111222333")
        try expectEqual(try roundTrip("connect_ok", value), value)
        try expectEqual(try roundTrip("session_start", value), value)
        try expectFalse("\(value)".contains("tok.en"))
    },

    TestCase("resume / resume_ok / renew_ok round-trip") {
        let resume = ResumePayload(sessionId: "s", sessionToken: "t")
        try expectEqual(try roundTrip("resume", resume), resume)
        try expectFalse("\(resume)".contains("t\""), "the token must not appear in a description")

        let ok = ResumeOKPayload(sessionId: "s", sessionToken: "t2", expiresAt: 3, ttlSec: 600,
                                 peerAttached: true, role: "controller")
        try expectEqual(try roundTrip("resume_ok", ok), ok)

        let renew = RenewOKPayload(sessionId: "s", sessionToken: "t3", expiresAt: 4, ttlSec: 600)
        try expectEqual(try roundTrip("renew_ok", renew), renew)
    },

    TestCase("peer_state round-trips") {
        let value = PeerStatePayload(sessionId: "s", attached: false)
        try expectEqual(try roundTrip("peer_state", value), value)
    },

    TestCase("sdp round-trips verbatim, and `restart` is omitted when unset") {
        let body = "v=0\r\no=- 1 1 IN IP4 0.0.0.0\r\ns=-\r\nm=application 9 UDP/DTLS/SCTP webrtc-datachannel\r\n"
        let plain = SDPPayload(sessionId: "s", sdpType: "offer", sdp: body)
        let decoded = try roundTrip("sdp", plain)
        try expectEqual(decoded.sdp, body, "the SDP body must survive byte-for-byte")
        try expectNil(decoded.restart)

        let restart = SDPPayload(sessionId: "s", sdpType: "offer", sdp: body, restart: true)
        try expectEqual(try roundTrip("sdp", restart).restart, true)

        let object = try JSONSerialization.jsonObject(
            with: try Envelope.encode(type: "sdp", payload: plain)) as! [String: Any]
        try expectNil((object["payload"] as! [String: Any])["restart"])
    },

    TestCase("ice round-trips, including the end-of-candidates marker") {
        let candidate = ICEPayload(sessionId: "s",
                                   candidate: "candidate:1 1 udp 2113937151 192.0.2.1 54321 typ host",
                                   sdpMid: "0", sdpMLineIndex: 0)
        try expectEqual(try roundTrip("ice", candidate), candidate)
        let end = ICEPayload(sessionId: "s", candidate: "")
        try expectEqual(try roundTrip("ice", end), end)
    },

    TestCase("bye round-trips every documented reason") {
        for reason in ["user_ended", "host_ended", "timeout", "failed",
                       "code_refreshed", "replaced", "shutdown", "error"] {
            let value = ByePayload(sessionId: "s", reason: reason)
            try expectEqual(try roundTrip("bye", value), value)
        }
    },

    TestCase("refresh_code_ok round-trips") {
        let value = RefreshCodeOKPayload(deviceId: "481930275", updatedAt: 7)
        try expectEqual(try roundTrip("refresh_code_ok", value), value)
    },

    TestCase("every error code decodes into a typed Swift error") {
        let codes = ["bad_request", "unsupported_version", "unsupported", "unauthenticated",
                     "bad_signature", "unknown_device", "bad_code", "offline", "busy",
                     "rate_limited", "self_connect", "no_session", "bad_token",
                     "peer_offline", "displaced", "forbidden", "internal"]
        for code in codes {
            let payload = ErrorPayload(code: code, message: "m", retryAfterSec: code == "rate_limited" ? 240 : nil)
            let data = try Envelope.encode(type: "error", re: "c-1", payload: payload)
            let envelope = try Envelope.decode(data)
            let wire = try expectNotNil(envelope.asProtocolError, "an error frame must map to a WireError")
            try expectEqual(wire.serverCode, code)
            if code == "rate_limited" { try expectEqual(wire.retryAfterSec, 240) }
            else { try expectNil(wire.retryAfterSec) }
        }
        // A non-error frame must never look like one.
        let ok = try Envelope.decode(try Envelope.encode(type: "hello_ok", payload: EmptyPayload()))
        try expectNil(ok.asProtocolError)
    },

    TestCase("server error codes map to specific, actionable UI errors") {
        func failure(_ code: String, retryAfter: Int = 0) -> ConnectFailure {
            ConnectFailure(WireError.protocolError(code: code, message: "m", retryAfterSec: retryAfter))
        }
        try expectEqual(failure("bad_code"), .badCode)
        try expectEqual(failure("offline"), .offline)
        try expectEqual(failure("busy"), .busy)
        try expectEqual(failure("rate_limited", retryAfter: 240), .rateLimited(retryAfterSec: 240))
        try expectEqual(failure("unknown_device"), .unknownDevice)
        try expectEqual(failure("self_connect"), .selfConnect)
        // The retry-after must reach the user, not be swallowed.
        let message = try expectNotNil(failure("rate_limited", retryAfter: 240).errorDescription)
        try expect(message.contains("4 minutes"), "got: \(message)")
        // Four distinct codes must not collapse into one message.
        let messages = Set([failure("bad_code"), failure("offline"), failure("busy"),
                            failure("unknown_device")].map { $0.errorDescription ?? "" })
        try expectEqual(messages.count, 4)
    },

    // ---- ctrl / hi payloads ------------------------------------------------

    TestCase("ping/pong, display_info, session_close and mouse_move round-trip") {
        let ping = PingPayload(t: 1_755_600_000_123)
        try expectEqual(try roundTrip("ping", ping), ping)
        try expectEqual(try roundTrip("pong", ping), ping)
        let display = DisplayInfoPayload(w: 3024, h: 1964, scale: 2.0)
        try expectEqual(try roundTrip("display_info", display), display)
        let close = SessionClosePayload(reason: "user_ended")
        try expectEqual(try roundTrip("session_close", close), close)
        let move = MouseMovePayload(x: 0.25, y: 0.75, seq: 9_000_000_000)
        try expectEqual(try roundTrip("mouse_move", move), move)
    },

    TestCase("input_reset is an empty payload, not a null one") {
        let data = try Envelope.encode(type: "input_reset", payload: EmptyPayload())
        let object = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        let payload = try expectNotNil(object["payload"] as? [String: Any])
        try expect(payload.isEmpty)
    },
])
