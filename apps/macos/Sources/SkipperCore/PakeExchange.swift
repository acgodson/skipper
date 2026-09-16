import CSkipperCore
import Foundation

/// `step` is 1-based; `payload` is opaque and base64, exactly as it travels on the wire.
public struct PakeMessage: Equatable, Sendable {
    public let step: Int
    public let payload: String

    public init(step: Int, payload: String) {
        self.step = step
        self.payload = payload
    }
}

public final class PakeExchange {

    private let handle: OpaquePointer
    public let role: SessionRole
    public private(set) var isComplete = false
    public private(set) var peerPublicKey: String?

    private struct StepResult: Decodable {
        struct Outgoing: Decodable {
            let step: Int
            let payload: String
        }
        let outgoing: Outgoing?
        let complete: Bool
        let peerPubkey: String
    }

    private struct KeyResult: Decodable {
        let sessionKey: String
    }

    public init(
        role: SessionRole,
        accessCode: String,
        deviceID: String,
        sessionID: String,
        ownPublicKey: String
    ) throws {
        self.role = role
        guard let handle = skipper_pake_new(
            role == .host ? Int32(SKIPPER_ROLE_HOST) : Int32(SKIPPER_ROLE_CONTROLLER),
            accessCode,
            deviceID,
            sessionID,
            ownPublicKey)
        else {
            throw SkipperCoreError("the shared core refused the access code, the session context or the device key")
        }
        self.handle = handle
    }

    public static func controller(
        accessCode: String,
        deviceID: String,
        sessionID: String,
        ownPublicKey: String
    ) throws -> PakeExchange {
        try PakeExchange(role: .controller, accessCode: accessCode,
                         deviceID: deviceID, sessionID: sessionID,
                         ownPublicKey: ownPublicKey)
    }

    public static func host(
        accessCode: String,
        deviceID: String,
        sessionID: String,
        ownPublicKey: String
    ) throws -> PakeExchange {
        try PakeExchange(role: .host, accessCode: accessCode,
                         deviceID: deviceID, sessionID: sessionID,
                         ownPublicKey: ownPublicKey)
    }

    deinit { skipper_pake_free(handle) }

    @discardableResult
    public func step(_ incoming: PakeMessage?) throws -> PakeMessage? {
        let result: StepResult = try CoreBoundary.call {
            skipper_pake_step(handle, Int32(incoming?.step ?? 0), incoming?.payload)
        }
        isComplete = result.complete
        peerPublicKey = result.peerPubkey.isEmpty ? nil : result.peerPubkey
        guard let outgoing = result.outgoing else { return nil }
        return PakeMessage(step: outgoing.step, payload: outgoing.payload)
    }

    public var sessionKey: Data? {
        guard isComplete else { return nil }
        guard let result: KeyResult = try? CoreBoundary.call({ skipper_pake_session_key(handle) })
        else { return nil }
        return Data(base64Encoded: result.sessionKey)
    }
}
