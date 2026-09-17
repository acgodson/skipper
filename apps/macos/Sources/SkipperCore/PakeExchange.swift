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

/// The derived keys never leave the core; a completed exchange is used by
/// handing it to `SdpAuth`, which MACs and checks every `sdp` with it.
public final class PakeExchange {

    let handle: OpaquePointer
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

    public init(
        role: SessionRole,
        accessCode: String,
        deviceID: String,
        sessionID: String,
        ownPublicKey: String
    ) throws {
        self.role = role
        let created = CoreBoundary.withText([accessCode, deviceID, sessionID, ownPublicKey]) { text in
            skipper_pake_new(
                role == .host ? Int32(SKIPPER_ROLE_HOST) : Int32(SKIPPER_ROLE_CONTROLLER),
                text[0].base, text[0].count, text[1].base, text[1].count,
                text[2].base, text[2].count, text[3].base, text[3].count)
        }
        guard let created else {
            throw SkipperCoreError("the shared core refused the access code, the session context or the device key")
        }
        self.handle = created
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

    /// A wrong access code throws a `SkipperCoreError` whose
    /// `isAuthenticationFailure` is true; any other failure is a broken exchange.
    @discardableResult
    public func step(_ incoming: PakeMessage?) throws -> PakeMessage? {
        let result: StepResult = try CoreBoundary.withText([incoming?.payload]) { text in
            Result {
                try CoreBoundary.call {
                    skipper_pake_step(handle, Int32(incoming?.step ?? 0), text[0].base, text[0].count)
                }
            }
        }.get()
        isComplete = result.complete
        peerPublicKey = result.peerPubkey.isEmpty ? nil : result.peerPubkey
        guard let outgoing = result.outgoing else { return nil }
        return PakeMessage(step: outgoing.step, payload: outgoing.payload)
    }
}
