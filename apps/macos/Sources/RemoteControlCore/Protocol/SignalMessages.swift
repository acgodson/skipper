import Foundation
@_exported import SkipperCore

/// The Swift side of the wire contract. `protocol/PROTOCOL.md` is normative and
/// `protocol/protocol.go` is its Go mirror; every name, JSON key and constant
/// below is copied from there deliberately rather than inferred.
public enum Wire {

    public static let version = 2

    // PROTOCOL.md §2.16
    public enum MessageType {
        public static let challenge = "challenge"
        public static let register = "register"
        public static let registerOK = "register_ok"
        public static let hello = "hello"
        public static let helloOK = "hello_ok"
        public static let heartbeat = "heartbeat"
        public static let heartbeatOK = "heartbeat_ok"
        public static let watch = "watch"
        public static let watchOK = "watch_ok"
        public static let unwatch = "unwatch"
        public static let unwatchOK = "unwatch_ok"
        public static let presence = "presence"
        public static let connectReq = "connect_req"
        public static let connectOK = "connect_ok"
        public static let sessionStart = "session_start"
        public static let resume = "resume"
        public static let resumeOK = "resume_ok"
        public static let renew = "renew"
        public static let renewOK = "renew_ok"
        public static let peerState = "peer_state"
        public static let sdp = "sdp"
        public static let ice = "ice"
        public static let bye = "bye"
        public static let refreshCode = "refresh_code"
        public static let refreshCodeOK = "refresh_code_ok"
        public static let error = "error"
    }

    // PROTOCOL.md §7
    public enum ErrorCode {
        public static let badRequest = "bad_request"
        public static let unsupportedVersion = "unsupported_version"
        public static let unsupported = "unsupported"
        public static let unauthenticated = "unauthenticated"
        public static let badSignature = "bad_signature"
        public static let unknownDevice = "unknown_device"
        public static let badCode = "bad_code"
        public static let offline = "offline"
        public static let busy = "busy"
        public static let rateLimited = "rate_limited"
        public static let selfConnect = "self_connect"
        public static let noSession = "no_session"
        public static let badToken = "bad_token"
        public static let peerOffline = "peer_offline"
        public static let displaced = "displaced"
        public static let forbidden = "forbidden"
        public static let internalError = "internal"
    }

    // PROTOCOL.md §2.14
    public enum ByeReason {
        public static let userEnded = "user_ended"
        public static let hostEnded = "host_ended"
        public static let timeout = "timeout"
        public static let failed = "failed"
        public static let codeRefreshed = "code_refreshed"
        public static let replaced = "replaced"
        public static let shutdown = "shutdown"
        public static let error = "error"
        /// The peer's signed SDP fingerprints did not verify against the device
        /// key this side expects (PROTOCOL.md §2.12).
        public static let peerAuthFailed = "peer_auth_failed"
    }

    /// Owned by the shared core, so the state machine and the wire agree by
    /// construction rather than by convention.
    public typealias Role = SessionRole
}

// MARK: - Envelope

public enum WireError: Swift.Error, LocalizedError, Equatable {
    case notJSONObject
    case unsupportedVersion(Int)
    case missingType
    case badPayload(String)
    case protocolError(code: String, message: String, retryAfterSec: Int)

    public var errorDescription: String? {
        switch self {
        case .notJSONObject: return "The frame was not a JSON object."
        case .unsupportedVersion(let v): return "Unsupported protocol version \(v)."
        case .missingType: return "The frame has no `type`."
        case .badPayload(let why): return "The payload could not be decoded: \(why)"
        case .protocolError(let code, let message, _): return "\(code): \(message)"
        }
    }

    /// The `code` of a server `error` frame, when this is one.
    public var serverCode: String? {
        if case .protocolError(let code, _, _) = self { return code }
        return nil
    }

    public var retryAfterSec: Int? {
        if case .protocolError(_, _, let retry) = self { return retry > 0 ? retry : nil }
        return nil
    }
}

/// One frame. The payload is kept as raw JSON bytes so that routing never has to
/// know every payload type — exactly like `json.RawMessage` on the Go side.
public struct Envelope: Equatable {

    public var v: Int
    public var type: String
    public var id: String?
    public var re: String?
    public var ts: Int64?
    public var payload: Data

    public init(type: String, id: String? = nil, re: String? = nil, ts: Int64? = nil, payload: Data = Data("{}".utf8)) {
        self.v = Wire.version
        self.type = type
        self.id = id
        self.re = re
        self.ts = ts
        self.payload = payload
    }

    /// Builds a frame around an encodable payload.
    public static func encode<T: Encodable>(
        type: String, id: String? = nil, re: String? = nil,
        ts: Int64? = Int64(Date().timeIntervalSince1970 * 1000),
        payload: T
    ) throws -> Data {
        let body = try JSONEncoder().encode(payload)
        var object: [String: Any] = [
            "v": Wire.version,
            "type": type,
            "payload": try JSONSerialization.jsonObject(with: body),
        ]
        if let id { object["id"] = id }
        if let re { object["re"] = re }
        if let ts { object["ts"] = ts }
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    public static func encodeEmpty(type: String, id: String? = nil) throws -> Data {
        try encode(type: type, id: id, payload: EmptyPayload())
    }

    public static func decode(_ data: Data) throws -> Envelope {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw WireError.notJSONObject
        }
        let v = object["v"] as? Int ?? 0
        guard v == Wire.version else { throw WireError.unsupportedVersion(v) }
        guard let type = object["type"] as? String, !type.isEmpty else { throw WireError.missingType }

        // An absent or null payload is treated as {}, matching protocol.Unmarshal.
        let rawPayload: Data
        if let p = object["payload"], !(p is NSNull) {
            rawPayload = (try? JSONSerialization.data(withJSONObject: p)) ?? Data("{}".utf8)
        } else {
            rawPayload = Data("{}".utf8)
        }

        var envelope = Envelope(type: type, payload: rawPayload)
        envelope.id = object["id"] as? String
        envelope.re = object["re"] as? String
        if let ts = object["ts"] as? NSNumber { envelope.ts = ts.int64Value }
        return envelope
    }

    public func decodePayload<T: Decodable>(_ type: T.Type) throws -> T {
        do {
            return try JSONDecoder().decode(T.self, from: payload)
        } catch {
            throw WireError.badPayload("\(type): \(error)")
        }
    }

    /// Turns an `error` frame into a Swift error. Returns nil for anything else.
    public var asProtocolError: WireError? {
        guard type == Wire.MessageType.error else { return nil }
        let body = (try? decodePayload(ErrorPayload.self))
            ?? ErrorPayload(code: Wire.ErrorCode.internalError, message: "undecodable error frame")
        return .protocolError(code: body.code, message: body.message, retryAfterSec: body.retryAfterSec ?? 0)
    }
}

public struct EmptyPayload: Codable, Equatable {
    public init() {}
}

// MARK: - Signaling payloads (PROTOCOL.md §2)

public struct ChallengePayload: Codable, Equatable {
    public var nonce: String
    public var serverTime: Int64
    public init(nonce: String, serverTime: Int64) { self.nonce = nonce; self.serverTime = serverTime }
}

/// PROTOCOL.md §2.3. The plaintext access code never appears here.
public struct CodeVerifier: Codable, Equatable {
    public var alg: String
    public var salt: String
    public var hash: String
    public var time: UInt32
    public var memKiB: UInt32
    public var par: UInt32
    public var len: UInt32

    public init(alg: String = "argon2id", salt: String, hash: String,
                time: UInt32, memKiB: UInt32, par: UInt32, len: UInt32) {
        self.alg = alg; self.salt = salt; self.hash = hash
        self.time = time; self.memKiB = memKiB; self.par = par; self.len = len
    }

    /// Builds a verifier with the parameters PROTOCOL.md recommends and the Go
    /// server's `auth.MakeVerifier` uses: time 3, 64 MiB, 1 lane, 32-byte output.
    public static func make(for plaintextCode: String) throws -> CodeVerifier {
        let salt = try SecureRandom.data(16)
        let digest = try Argon2id.hash(
            password: plaintextCode, salt: salt,
            iterations: Argon2id.recommendedTime,
            memoryKiB: Argon2id.recommendedMemoryKiB,
            parallelism: Argon2id.recommendedParallelism,
            length: Argon2id.recommendedLength)
        return CodeVerifier(
            salt: salt.base64EncodedString(),
            hash: digest.base64EncodedString(),
            time: Argon2id.recommendedTime,
            memKiB: Argon2id.recommendedMemoryKiB,
            par: Argon2id.recommendedParallelism,
            len: Argon2id.recommendedLength)
    }

    /// Local recomputation. The app never needs this — the server verifies — but
    /// it is what lets the test suite prove the KDF is wired up correctly.
    public func verify(_ plaintextCode: String) -> Bool {
        guard alg == "argon2id",
              let saltBytes = Data(base64Encoded: salt),
              let expected = Data(base64Encoded: hash),
              let got = try? Argon2id.hash(password: plaintextCode, salt: saltBytes,
                                           iterations: time, memoryKiB: memKiB,
                                           parallelism: par, length: len)
        else { return false }
        guard got.count == expected.count else { return false }
        var diff: UInt8 = 0
        for (a, b) in zip(got, expected) { diff |= a ^ b }
        return diff == 0
    }
}

public struct RegisterPayload: Codable, Equatable {
    public var pubkey: String
    public var sig: String
    public var label: String?
    public var code: CodeVerifier
    public init(pubkey: String, sig: String, label: String?, code: CodeVerifier) {
        self.pubkey = pubkey; self.sig = sig; self.label = label; self.code = code
    }
}

public struct RegisterOKPayload: Codable, Equatable {
    public var deviceId: String
    public var existing: Bool
    public init(deviceId: String, existing: Bool) { self.deviceId = deviceId; self.existing = existing }
}

public struct HelloPayload: Codable, Equatable {
    public var deviceId: String
    public var pubkey: String
    public var sig: String
    public var role: String
    public init(deviceId: String, pubkey: String, sig: String, role: String) {
        self.deviceId = deviceId; self.pubkey = pubkey; self.sig = sig; self.role = role
    }
}

public struct ICEServerSpec: Codable, Equatable {
    public var urls: [String]
    public var username: String?
    public var credential: String?
    public var expiresAt: Int64?
    public init(urls: [String], username: String? = nil, credential: String? = nil, expiresAt: Int64? = nil) {
        self.urls = urls; self.username = username; self.credential = credential; self.expiresAt = expiresAt
    }
}

public struct HelloOKPayload: Codable, Equatable {
    public var deviceId: String
    public var serverTime: Int64
    public var iceServers: [ICEServerSpec]
    public var heartbeatSec: Int
    public var offlineAfterSec: Int
    public var sessionTokenTtlSec: Int
    public var activeSessionId: String?
    public init(deviceId: String, serverTime: Int64, iceServers: [ICEServerSpec],
                heartbeatSec: Int, offlineAfterSec: Int, sessionTokenTtlSec: Int,
                activeSessionId: String? = nil) {
        self.deviceId = deviceId; self.serverTime = serverTime; self.iceServers = iceServers
        self.heartbeatSec = heartbeatSec; self.offlineAfterSec = offlineAfterSec
        self.sessionTokenTtlSec = sessionTokenTtlSec; self.activeSessionId = activeSessionId
    }
}

public struct HeartbeatOKPayload: Codable, Equatable {
    public var serverTime: Int64
    public init(serverTime: Int64) { self.serverTime = serverTime }
}

public struct DeviceIDPayload: Codable, Equatable {
    public var deviceId: String
    public init(deviceId: String) { self.deviceId = deviceId }
}

public struct PresencePayload: Codable, Equatable {
    public var deviceId: String
    public var online: Bool
    public var since: Int64
    public init(deviceId: String, online: Bool, since: Int64) {
        self.deviceId = deviceId; self.online = online; self.since = since
    }
}

/// Carries the plaintext access code. Never log an instance of this type.
public struct ConnectReqPayload: Codable, Equatable, CustomStringConvertible {
    public var deviceId: String
    public var accessCode: String
    public init(deviceId: String, accessCode: String) {
        self.deviceId = deviceId; self.accessCode = accessCode
    }
    public var description: String { "connect_req(deviceId: \(deviceId), accessCode: <redacted>)" }
}

/// `connect_ok` and `session_start` share a shape (PROTOCOL.md §2.9).
public struct SessionGrantPayload: Codable, Equatable, CustomStringConvertible {
    public var sessionId: String
    public var sessionToken: String
    public var expiresAt: Int64
    public var ttlSec: Int
    public var hostDeviceId: String
    public var controllerDeviceId: String
    /// The host's registered `pubkey`, base64 DER SPKI: the key the controller
    /// requires on the host's signed `sdp` (PROTOCOL.md §2.12). Absent from a
    /// server that does not speak this part of v2 yet.
    public var hostPubkey: String?
    public init(sessionId: String, sessionToken: String, expiresAt: Int64, ttlSec: Int,
                hostDeviceId: String, controllerDeviceId: String, hostPubkey: String? = nil) {
        self.sessionId = sessionId; self.sessionToken = sessionToken
        self.expiresAt = expiresAt; self.ttlSec = ttlSec
        self.hostDeviceId = hostDeviceId; self.controllerDeviceId = controllerDeviceId
        self.hostPubkey = hostPubkey
    }
    public var description: String {
        "session(\(sessionId), host: \(hostDeviceId), controller: \(controllerDeviceId), token: <redacted>)"
    }
}

public struct ResumePayload: Codable, Equatable, CustomStringConvertible {
    public var sessionId: String
    public var sessionToken: String
    public init(sessionId: String, sessionToken: String) {
        self.sessionId = sessionId; self.sessionToken = sessionToken
    }
    public var description: String { "resume(\(sessionId), token: <redacted>)" }
}

public struct ResumeOKPayload: Codable, Equatable {
    public var sessionId: String
    public var sessionToken: String
    public var expiresAt: Int64
    public var ttlSec: Int
    public var peerAttached: Bool
    public var role: String
    public init(sessionId: String, sessionToken: String, expiresAt: Int64, ttlSec: Int,
                peerAttached: Bool, role: String) {
        self.sessionId = sessionId; self.sessionToken = sessionToken
        self.expiresAt = expiresAt; self.ttlSec = ttlSec
        self.peerAttached = peerAttached; self.role = role
    }
}

public struct RenewOKPayload: Codable, Equatable {
    public var sessionId: String
    public var sessionToken: String
    public var expiresAt: Int64
    public var ttlSec: Int
    public init(sessionId: String, sessionToken: String, expiresAt: Int64, ttlSec: Int) {
        self.sessionId = sessionId; self.sessionToken = sessionToken
        self.expiresAt = expiresAt; self.ttlSec = ttlSec
    }
}

extension SessionGrantPayload: SessionGrantLike {}
extension ResumeOKPayload: SessionTokenLike {}
extension RenewOKPayload: SessionTokenLike {}

public struct PeerStatePayload: Codable, Equatable {
    public var sessionId: String
    public var attached: Bool
    public init(sessionId: String, attached: Bool) { self.sessionId = sessionId; self.attached = attached }
}

/// PROTOCOL.md §2.12. `fp`, `pubkey` and `sig` are the signed DTLS
/// fingerprints; the server relays them unchanged and never checks `sig`.
public struct SDPPayload: Codable, Equatable {
    public var sessionId: String
    public var sdpType: String
    public var sdp: String
    public var restart: Bool?
    public var fp: String?
    public var pubkey: String?
    public var sig: String?
    public init(sessionId: String, sdpType: String, sdp: String, restart: Bool? = nil,
                fp: String? = nil, pubkey: String? = nil, sig: String? = nil) {
        self.sessionId = sessionId; self.sdpType = sdpType; self.sdp = sdp; self.restart = restart
        self.fp = fp; self.pubkey = pubkey; self.sig = sig
    }

    /// The three signature fields, when all three are present. A frame missing
    /// any of them cannot be verified and must not be applied.
    public var signature: SdpSignature? {
        guard let fp, let pubkey, let sig, !fp.isEmpty, !pubkey.isEmpty, !sig.isEmpty else {
            return nil
        }
        return SdpSignature(fingerprints: fp, pubkey: pubkey, signature: sig)
    }
}

public struct ICEPayload: Codable, Equatable {
    public var sessionId: String
    public var candidate: String
    public var sdpMid: String?
    public var sdpMLineIndex: Int?
    public init(sessionId: String, candidate: String, sdpMid: String? = nil, sdpMLineIndex: Int? = nil) {
        self.sessionId = sessionId; self.candidate = candidate
        self.sdpMid = sdpMid; self.sdpMLineIndex = sdpMLineIndex
    }
}

public struct ByePayload: Codable, Equatable {
    public var sessionId: String
    public var reason: String
    public init(sessionId: String, reason: String) { self.sessionId = sessionId; self.reason = reason }
}

public struct RefreshCodeOKPayload: Codable, Equatable {
    public var deviceId: String
    public var updatedAt: Int64
    public init(deviceId: String, updatedAt: Int64) { self.deviceId = deviceId; self.updatedAt = updatedAt }
}

public struct ErrorPayload: Codable, Equatable {
    public var code: String
    public var message: String
    public var retryAfterSec: Int?
    public init(code: String, message: String, retryAfterSec: Int? = nil) {
        self.code = code; self.message = message; self.retryAfterSec = retryAfterSec
    }
}

// MARK: - `ctrl` / `hi` data-channel payloads (PROTOCOL.md §5, §6)

public enum CtrlType {
    public static let mouseDown = "mouse_down"
    public static let mouseUp = "mouse_up"
    public static let mouseDrag = "mouse_drag"
    public static let click = "click"
    public static let keyDown = "key_down"
    public static let keyUp = "key_up"
    public static let scroll = "scroll"
    public static let clipboardText = "clipboard_text"
    public static let gesture = "gesture"
    public static let inputReset = "input_reset"
    public static let displayInfo = "display_info"
    public static let quality = "quality"
    public static let ping = "ping"
    public static let pong = "pong"
    public static let sessionClose = "session_close"
    /// The only type permitted on `hi`.
    public static let mouseMove = "mouse_move"
}

public struct PingPayload: Codable, Equatable {
    public var t: Int64
    public init(t: Int64) { self.t = t }
}

public struct DisplayInfoPayload: Codable, Equatable {
    public var w: Int
    public var h: Int
    public var scale: Double
    public init(w: Int, h: Int, scale: Double) { self.w = w; self.h = h; self.scale = scale }
}

public struct SessionClosePayload: Codable, Equatable {
    public var reason: String
    public init(reason: String) { self.reason = reason }
}

public struct MouseMovePayload: Codable, Equatable {
    public var x: Double
    public var y: Double
    public var seq: Int64
    public init(x: Double, y: Double, seq: Int64) { self.x = x; self.y = y; self.seq = seq }
}
