import Foundation

/// The machine-readable half of the API.md §0.3 error envelope.
///
/// Open on purpose: §0.5 allows the server to add members, and a client that
/// crashes on an unknown code is a client that cannot be fixed server-side.
public enum APIErrorCode: Equatable {
    case badRequest
    case unauthenticated
    case forbidden
    case notFound
    case conflict
    case idempotencyConflict
    case entitlement
    case rateLimited
    case unsupportedVersion
    case serverFault
    case unavailable
    /// The call never produced an envelope: DNS, TLS, timeout, or a body that is
    /// not the documented shape. Distinct from every server-stated code.
    case transport
    case other(String)

    public init(wire: String) {
        switch wire {
        case "bad_request": self = .badRequest
        case "unauthenticated": self = .unauthenticated
        case "forbidden": self = .forbidden
        case "not_found": self = .notFound
        case "conflict": self = .conflict
        case "idempotency_conflict": self = .idempotencyConflict
        case "entitlement": self = .entitlement
        case "rate_limited": self = .rateLimited
        case "unsupported_version": self = .unsupportedVersion
        case "internal": self = .serverFault
        case "unavailable": self = .unavailable
        default: self = .other(wire)
        }
    }

    public var wire: String {
        switch self {
        case .badRequest: return "bad_request"
        case .unauthenticated: return "unauthenticated"
        case .forbidden: return "forbidden"
        case .notFound: return "not_found"
        case .conflict: return "conflict"
        case .idempotencyConflict: return "idempotency_conflict"
        case .entitlement: return "entitlement"
        case .rateLimited: return "rate_limited"
        case .unsupportedVersion: return "unsupported_version"
        case .serverFault: return "internal"
        case .unavailable: return "unavailable"
        case .transport: return "transport"
        case .other(let raw): return raw
        }
    }
}

/// The ONE error type this surface throws — the API.md §0.3 envelope, plus the
/// transport failures that never reach a server at all.
public struct APIError: Error, LocalizedError, Equatable {

    public let code: APIErrorCode
    public let message: String
    public let requestId: String?
    /// Sub-reason. Defined for `entitlement` (§4.3) and `idempotency_conflict`.
    public let reason: String?
    public let retryAfterSec: Int?
    public let httpStatus: Int?

    public init(
        code: APIErrorCode,
        message: String,
        requestId: String? = nil,
        reason: String? = nil,
        retryAfterSec: Int? = nil,
        httpStatus: Int? = nil
    ) {
        self.code = code
        self.message = message
        self.requestId = requestId
        self.reason = reason
        self.retryAfterSec = retryAfterSec
        self.httpStatus = httpStatus
    }

    public var errorDescription: String? { message }

    /// Decodes a non-2xx body. A body that is not the documented envelope is
    /// reported as such rather than guessed at: the status code alone never
    /// becomes a code the client then branches on.
    public static func decode(status: Int, body: Data, retryAfterHeader: Int? = nil) -> APIError {
        struct Envelope: Decodable {
            struct Payload: Decodable {
                let code: String
                let message: String
                let requestId: String?
                let reason: String?
                let retryAfterSec: Int?
            }
            let error: Payload
        }

        guard let envelope = try? JSONDecoder().decode(Envelope.self, from: body) else {
            return APIError(
                code: .transport,
                message: "The server returned HTTP \(status) with a body this app does not understand.",
                retryAfterSec: retryAfterHeader,
                httpStatus: status
            )
        }
        return APIError(
            code: APIErrorCode(wire: envelope.error.code),
            message: envelope.error.message,
            requestId: envelope.error.requestId,
            reason: envelope.error.reason,
            retryAfterSec: envelope.error.retryAfterSec ?? retryAfterHeader,
            httpStatus: status
        )
    }

    public static func transport(_ message: String) -> APIError {
        APIError(code: .transport, message: message)
    }
}

/// Which credential class (API.md §0.2) a call presents.
public enum APICredential: Equatable {
    case none
    case deviceToken(String)
}

/// The REST client for `api.skipperdesk.app`, or for whatever implements the
/// same contract — the app holds one config value, `RCConfig.apiBaseURL`
/// (docs/SCOPE.md §4).
///
/// It owns exactly the mechanics of API.md §0: the client header, JSON
/// encoding, the error envelope, idempotency keys on mutating calls, and the
/// one retry policy the document allows. Everything above that lives in
/// `AccountLinker`.
public final class APIClient: @unchecked Sendable {

    public static let clientHeader = "X-SkipperDesk-Client"
    public static let idempotencyHeader = "Idempotency-Key"

    private let baseURL: URL
    private let session: URLSession
    private let clientIdentifier: String
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(
        baseURL: URL = RCConfig.current.apiBaseURL,
        session: URLSession = APIClient.defaultSession(),
        clientIdentifier: String = APIClient.defaultClientIdentifier()
    ) {
        self.baseURL = baseURL
        self.session = session
        self.clientIdentifier = clientIdentifier
        self.encoder = JSONEncoder()
        self.decoder = JSONDecoder()
    }

    public static func defaultSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 60
        configuration.httpAdditionalHeaders = nil
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpShouldSetCookies = false
        return URLSession(configuration: configuration)
    }

    /// `macos/<CFBundleShortVersionString>` (API.md §0.1). Advisory only.
    public static func defaultClientIdentifier() -> String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        return "macos/\(version ?? "0.0.0")"
    }

    /// A fresh `Idempotency-Key` for one logical mutating operation (§0.6).
    public static func newIdempotencyKey() -> String { UUID().uuidString }

    // MARK: - §1 Auth handoff

    public func deviceChallenge(code: String) async throws -> DeviceChallenge {
        try await send(.post, "/v1/auth/device/challenge", body: ["code": code], credential: .none)
    }

    public func deviceChallenge(deviceId: String) async throws -> DeviceChallenge {
        try await send(.post, "/v1/auth/device/challenge", body: ["deviceId": deviceId], credential: .none)
    }

    public func deviceToken(
        code: String,
        pubkey: String,
        signature: String,
        platform: String,
        hardwareId: String,
        label: String?,
        idempotencyKey: String = APIClient.newIdempotencyKey()
    ) async throws -> DeviceTokenGrant {
        var body: [String: String] = [
            "code": code,
            "pubkey": pubkey,
            "sig": signature,
            "platform": platform,
            "hardwareId": hardwareId,
        ]
        if let label { body["label"] = label }
        return try await send(
            .post, "/v1/auth/device/token", body: body, credential: .none, idempotencyKey: idempotencyKey)
    }

    public func refreshDeviceToken(
        deviceId: String,
        pubkey: String,
        signature: String,
        idempotencyKey: String = APIClient.newIdempotencyKey()
    ) async throws -> DeviceTokenGrant {
        try await send(
            .post,
            "/v1/auth/device/refresh",
            body: ["deviceId": deviceId, "pubkey": pubkey, "sig": signature],
            credential: .none,
            idempotencyKey: idempotencyKey
        )
    }

    public func revokeDeviceToken(
        _ token: String,
        idempotencyKey: String = APIClient.newIdempotencyKey()
    ) async throws {
        _ = try await sendExpectingNoContent(
            .post,
            "/v1/auth/device/revoke",
            body: [String: String](),
            credential: .deviceToken(token),
            idempotencyKey: idempotencyKey
        )
    }

    // MARK: - §3, §4 reads

    public func device(id: String, token: String) async throws -> DeviceRecord {
        try await send(
            .get,
            "/v1/devices/\(id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? id)",
            body: Optional<[String: String]>.none,
            credential: .deviceToken(token)
        )
    }

    public func entitlement(token: String) async throws -> Entitlement {
        try await send(.get, "/v1/entitlement", body: Optional<[String: String]>.none,
                       credential: .deviceToken(token))
    }

    // MARK: - Transport

    public enum Method: String {
        case get = "GET"
        case post = "POST"
    }

    private func send<Body: Encodable, Response: Decodable>(
        _ method: Method,
        _ path: String,
        body: Body?,
        credential: APICredential,
        idempotencyKey: String? = nil
    ) async throws -> Response {
        let data = try await perform(method, path, body: body, credential: credential,
                                     idempotencyKey: idempotencyKey)
        do {
            return try decoder.decode(Response.self, from: data)
        } catch {
            throw APIError.transport("The server's answer to \(path) was not in the expected shape.")
        }
    }

    private func sendExpectingNoContent<Body: Encodable>(
        _ method: Method,
        _ path: String,
        body: Body?,
        credential: APICredential,
        idempotencyKey: String? = nil
    ) async throws -> Data {
        try await perform(method, path, body: body, credential: credential, idempotencyKey: idempotencyKey)
    }

    /// One call, with the only retries API.md §0.4 permits: at most three
    /// attempts on `internal`, and a single honoured wait on `unavailable`.
    /// Every other code is returned to the caller on the first answer.
    private func perform<Body: Encodable>(
        _ method: Method,
        _ path: String,
        body: Body?,
        credential: APICredential,
        idempotencyKey: String?
    ) async throws -> Data {
        var attempt = 0
        while true {
            attempt += 1
            do {
                return try await performOnce(method, path, body: body, credential: credential,
                                             idempotencyKey: idempotencyKey)
            } catch let error as APIError {
                let retryable = (error.code == .serverFault && attempt < 3)
                    || (error.code == .unavailable && attempt < 2)
                guard retryable else { throw error }
                let wait = error.retryAfterSec.map { Double(min($0, 30)) } ?? Double(attempt) * 0.5
                try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
            }
        }
    }

    private func performOnce<Body: Encodable>(
        _ method: Method,
        _ path: String,
        body: Body?,
        credential: APICredential,
        idempotencyKey: String?
    ) async throws -> Data {
        guard let url = URL(string: path, relativeTo: baseURL) else {
            throw APIError.transport("'\(path)' is not a valid path on \(baseURL.absoluteString).")
        }

        var request = URLRequest(url: url)
        request.httpMethod = method.rawValue
        request.setValue(clientIdentifier, forHTTPHeaderField: Self.clientHeader)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if case .deviceToken(let token) = credential {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        if let idempotencyKey {
            request.setValue(idempotencyKey, forHTTPHeaderField: Self.idempotencyHeader)
        }
        if let body {
            request.httpBody = try encoder.encode(body)
            request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw APIError.transport("Could not reach \(baseURL.host ?? "the server"): \(error.localizedDescription)")
        }

        guard let http = response as? HTTPURLResponse else {
            throw APIError.transport("The server's answer was not an HTTP response.")
        }
        guard (200..<300).contains(http.statusCode) else {
            let header = (http.value(forHTTPHeaderField: "Retry-After")).flatMap(Int.init)
            throw APIError.decode(status: http.statusCode, body: data, retryAfterHeader: header)
        }
        return data
    }
}
