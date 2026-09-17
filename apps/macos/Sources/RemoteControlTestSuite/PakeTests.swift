import Foundation
import RCTestKit
import RemoteControlCore
import SkipperCore

private let deviceID = "482719351"
private let sessionID = "5e550000000000000000000000000ff1"
private let controllerKey = DeviceKey()
private let hostKey = DeviceKey()
private let controllerPubkey = ((try? controllerKey.publicKeyDER()) ?? Data()).base64EncodedString()
private let hostPubkey = ((try? hostKey.publicKeyDER()) ?? Data()).base64EncodedString()

public let pakeSuite = TestSuite("PakeExchange", [

    TestCase("a round trip agrees on one session key") {
        let code = try AccessCode.generate()
        let controller = try PakeExchange.controller(accessCode: AccessCode.formatted(code),
                                                     deviceID: deviceID, sessionID: sessionID,
                                                     ownPublicKey: controllerPubkey)
        let host = try PakeExchange.host(accessCode: code.lowercased(),
                                         deviceID: deviceID, sessionID: sessionID,
                                         ownPublicKey: hostPubkey)

        let step1 = try expectNotNil(try controller.step(nil), "the controller opens the exchange")
        try expectEqual(step1.step, 1)

        let step2 = try expectNotNil(try host.step(step1), "the host replies with its confirmation")
        try expectEqual(step2.step, 2)
        try expectLessThan(step2.payload.count, 4097, "payloads are capped at 4096 base64 characters")

        let step3 = try expectNotNil(try controller.step(step2), "the controller confirms")
        try expectEqual(step3.step, 3)

        try expectNil(try host.step(step3), "the host sends nothing back")

        try expect(controller.isComplete && host.isComplete)
        let offer = "v=0\r\na=fingerprint:sha-256 AA:01\r\n"
        let signable = try SdpAuth.signable(pake: controller, sessionID: sessionID,
                                            sdpType: "offer", sdp: offer)
        let hostView = try SdpAuth.signable(pake: host, sessionID: sessionID,
                                            sdpType: "offer", sdp: offer)
        try expectEqual(signable.mac, hostView.mac, "both sides derived the same sdp MAC key")

        try expectEqual(host.peerPublicKey, controllerPubkey,
                        "the host learned the controller's device key from step 1")
        try expectEqual(controller.peerPublicKey, hostPubkey,
                        "the controller learned the host's device key from step 2")
    },

    TestCase("a wrong code is refused by the host") {
        let controller = try PakeExchange.controller(accessCode: "K7FM3Q8PW2XY",
                                                     deviceID: deviceID, sessionID: sessionID,
                                                     ownPublicKey: controllerPubkey)
        let host = try PakeExchange.host(accessCode: "K7FM3Q8PW2X0",
                                         deviceID: deviceID, sessionID: sessionID,
                                         ownPublicKey: hostPubkey)

        let step1 = try expectNotNil(try controller.step(nil))
        let step2 = try expectNotNil(try host.step(step1))

        do {
            _ = try controller.step(step2)
            throw TestFailure(message: "the controller confirmation check did not throw")
        } catch let refused as SkipperCoreError {
            try expect(refused.isAuthenticationFailure, "a wrong code is an authentication failure")
        }

        let forged = PakeMessage(step: 3, payload: Data(repeating: 0, count: 32).base64EncodedString())
        try await expectThrows("the host's confirmation check") {
            _ = try host.step(forged)
        }
        try expectFalse(host.isComplete)
        try await expectThrows("an sdp before the exchange completes") {
            _ = try SdpAuth.signable(pake: host, sessionID: sessionID, sdpType: "offer",
                                     sdp: "v=0\r\na=fingerprint:sha-256 AA:01\r\n")
        }
    },

    TestCase("a code the core cannot use is rejected at construction") {
        try await expectThrows("an empty access code") {
            _ = try PakeExchange.controller(accessCode: "--", deviceID: deviceID,
                                            sessionID: sessionID,
                                            ownPublicKey: controllerPubkey)
        }
        try await expectThrows("a missing session") {
            _ = try PakeExchange.host(accessCode: "K7FM3Q8PW2XY", deviceID: deviceID,
                                      sessionID: "", ownPublicKey: hostPubkey)
        }
    },
])
