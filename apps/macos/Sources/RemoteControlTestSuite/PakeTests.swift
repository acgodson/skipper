import Foundation
import RCTestKit
import SkipperCore

/// The SPAKE2 exchange of PROTOCOL.md §2.17, driven the way the app will drive
/// it: two `PakeExchange` handles in one process, passing each other exactly
/// what a `pake` frame would carry.
///
/// The rules themselves are proven in `core/crates/rc-identity` — these cases
/// exist to prove the FFI path carries them, including the failure that matters
/// most: the host refusing a wrong code.

private let deviceID = "482719351"
private let sessionID = "sess-ffi-1"

public let pakeSuite = TestSuite("PakeExchange", [

    TestCase("a round trip agrees on one session key") {
        let code = try AccessCode.generate()
        let controller = try PakeExchange.controller(accessCode: AccessCode.formatted(code),
                                                     deviceID: deviceID, sessionID: sessionID)
        let host = try PakeExchange.host(accessCode: code.lowercased(),
                                         deviceID: deviceID, sessionID: sessionID)

        let step1 = try expectNotNil(try controller.step(nil), "the controller opens the exchange")
        try expectEqual(step1.step, 1)

        let step2 = try expectNotNil(try host.step(step1), "the host replies with its confirmation")
        try expectEqual(step2.step, 2)
        try expectLessThan(step2.payload.count, 4097, "payloads are capped at 4096 base64 characters")

        let step3 = try expectNotNil(try controller.step(step2), "the controller confirms")
        try expectEqual(step3.step, 3)

        try expectNil(try host.step(step3), "the host sends nothing back")

        try expect(controller.isComplete && host.isComplete)
        let key = try expectNotNil(controller.sessionKey, "the controller has a session key")
        try expectEqual(key.count, 32)
        try expectEqual(key, host.sessionKey)
    },

    TestCase("a wrong code is refused by the host") {
        let controller = try PakeExchange.controller(accessCode: "K7FM3Q8PW2XY",
                                                     deviceID: deviceID, sessionID: sessionID)
        let host = try PakeExchange.host(accessCode: "K7FM3Q8PW2X0",
                                         deviceID: deviceID, sessionID: sessionID)

        let step1 = try expectNotNil(try controller.step(nil))
        let step2 = try expectNotNil(try host.step(step1))

        try await expectThrows("the controller's confirmation check") {
            _ = try controller.step(step2)
        }

        let forged = PakeMessage(step: 3, payload: Data(repeating: 0, count: 32).base64EncodedString())
        try await expectThrows("the host's confirmation check") {
            _ = try host.step(forged)
        }
        try expectFalse(host.isComplete)
        try expectNil(host.sessionKey)
    },

    TestCase("a code the core cannot use is rejected at construction") {
        try await expectThrows("an empty access code") {
            _ = try PakeExchange.controller(accessCode: "--", deviceID: deviceID, sessionID: sessionID)
        }
        try await expectThrows("a missing session") {
            _ = try PakeExchange.host(accessCode: "K7FM3Q8PW2XY", deviceID: deviceID, sessionID: "")
        }
    },
])
