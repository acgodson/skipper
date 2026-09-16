import CSkipperCore
import Foundation

/// One `pake` frame's body (PROTOCOL.md §2.17): the 1-based step and the
/// opaque payload, base64 exactly as it travels.
public struct PakeMessage: Equatable, Sendable {
    public let step: Int
    public let payload: String

    public init(step: Int, payload: String) {
        self.step = step
        self.payload = payload
    }
}

/// One side of the SPAKE2 access-code exchange, over the shared core.
///
/// The controller opens with `step(nil)`; after that each side hands in the
/// frame that arrived from the peer and sends back whatever it returns. A wrong
/// code throws — at the controller on step 2, and at the **host** on step 3,
/// which is the one that matters: the host learns the attempt was wrong before
/// it has done anything with the session.
///
/// Nothing here decides *policy*. Counting failures and locking a controller
/// out is `skipper_pake_guess_policy_*`, whose counters the platform stores.
public final class PakeExchange {

    private let handle: OpaquePointer
    public let role: SessionRole
    public private(set) var isComplete = false

    private struct StepResult: Decodable {
        struct Outgoing: Decodable {
            let step: Int
            let payload: String
        }
        let outgoing: Outgoing?
        let complete: Bool
    }

    private struct KeyResult: Decodable {
        let sessionKey: String
    }

    public init(role: SessionRole, accessCode: String, deviceID: String, sessionID: String) throws {
        self.role = role
        guard let handle = skipper_pake_new(
            role == .host ? Int32(SKIPPER_ROLE_HOST) : Int32(SKIPPER_ROLE_CONTROLLER),
            accessCode,
            deviceID,
            sessionID)
        else {
            throw SkipperCoreError("the shared core refused the access code or the session context")
        }
        self.handle = handle
    }

    public static func controller(
        accessCode: String,
        deviceID: String,
        sessionID: String
    ) throws -> PakeExchange {
        try PakeExchange(role: .controller, accessCode: accessCode,
                         deviceID: deviceID, sessionID: sessionID)
    }

    public static func host(
        accessCode: String,
        deviceID: String,
        sessionID: String
    ) throws -> PakeExchange {
        try PakeExchange(role: .host, accessCode: accessCode,
                         deviceID: deviceID, sessionID: sessionID)
    }

    deinit { skipper_pake_free(handle) }

    /// `nil` in starts the controller's step 1; `nil` out means the exchange is
    /// over and this side sends nothing further.
    @discardableResult
    public func step(_ incoming: PakeMessage?) throws -> PakeMessage? {
        let result: StepResult = try CoreBoundary.call {
            skipper_pake_step(handle, Int32(incoming?.step ?? 0), incoming?.payload)
        }
        isComplete = result.complete
        guard let outgoing = result.outgoing else { return nil }
        return PakeMessage(step: outgoing.step, payload: outgoing.payload)
    }

    /// The 32-byte key the two sides agreed on, once `isComplete`.
    public var sessionKey: Data? {
        guard isComplete else { return nil }
        guard let result: KeyResult = try? CoreBoundary.call({ skipper_pake_session_key(handle) })
        else { return nil }
        return Data(base64Encoded: result.sessionKey)
    }
}
