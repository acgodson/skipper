import Foundation
import RCTestKit
import RemoteControlCore

// TODO: the Keychain half is proven only through the blob-store protocol here.

private func envelope(_ json: String) -> Data { Data(json.utf8) }

public let accountSuite = TestSuite("Account", [

    // MARK: - API.md §0.3 error envelope

    TestCase("a full envelope decodes into every field the client branches on") {
        let error = APIError.decode(status: 402, body: envelope("""
        {"error":{"code":"entitlement","message":"trial has ended","requestId":"01J8Z2Q5C3N4K0",
        "reason":"trial_expired","retryAfterSec":0}}
        """))

        try expectEqual(error.code, .entitlement)
        try expectEqual(error.message, "trial has ended")
        try expectEqual(error.requestId, "01J8Z2Q5C3N4K0")
        try expectEqual(error.reason, "trial_expired")
        try expectEqual(error.retryAfterSec, 0)
        try expectEqual(error.httpStatus, 402)
    },

    TestCase("every §0.4 code maps to its own case, and back to the same wire value") {
        let wire = [
            "bad_request", "unauthenticated", "forbidden", "not_found", "conflict",
            "idempotency_conflict", "entitlement", "rate_limited", "unsupported_version",
            "internal", "unavailable",
        ]
        var seen: [APIErrorCode] = []
        for code in wire {
            let mapped = APIErrorCode(wire: code)
            try expectEqual(mapped.wire, code)
            try expectFalse(seen.contains(mapped), "\(code) collided with an earlier code")
            seen.append(mapped)
        }
        try expectEqual(APIErrorCode(wire: "internal"), .serverFault)
    },

    TestCase("an unknown code is carried through instead of being guessed at") {
        let error = APIError.decode(status: 418, body: envelope("""
        {"error":{"code":"teapot","message":"no","requestId":"r1"}}
        """))
        try expectEqual(error.code, .other("teapot"))
        try expectEqual(error.code.wire, "teapot")
        try expectEqual(error.reason, nil)
        try expectEqual(error.retryAfterSec, nil)
    },

    TestCase("a body that is not an envelope is a transport failure, never a code") {
        let html = APIError.decode(status: 502, body: envelope("<html>gateway</html>"))
        try expectEqual(html.code, .transport)
        try expectEqual(html.httpStatus, 502)

        let empty = APIError.decode(status: 500, body: Data())
        try expectEqual(empty.code, .transport)

        let wrongShape = APIError.decode(status: 400, body: envelope(#"{"message":"nope"}"#))
        try expectEqual(wrongShape.code, .transport)
    },

    TestCase("the Retry-After header fills in a retryAfterSec the body left out") {
        let error = APIError.decode(
            status: 429,
            body: envelope(#"{"error":{"code":"rate_limited","message":"slow down","requestId":"r2"}}"#),
            retryAfterHeader: 42
        )
        try expectEqual(error.code, .rateLimited)
        try expectEqual(error.retryAfterSec, 42)
    },

    TestCase("the body wins over the header when both state a wait") {
        let error = APIError.decode(
            status: 503,
            body: envelope("""
            {"error":{"code":"unavailable","message":"partial outage","requestId":"r3","retryAfterSec":5}}
            """),
            retryAfterHeader: 99
        )
        try expectEqual(error.retryAfterSec, 5)
    },

    TestCase("unknown members are ignored, as API.md §0 requires of every client") {
        let error = APIError.decode(status: 403, body: envelope("""
        {"error":{"code":"forbidden","message":"not yours","requestId":"r4","futureField":{"a":1}},
        "alsoNew":[1,2,3]}
        """))
        try expectEqual(error.code, .forbidden)
        try expectEqual(error.message, "not yours")
    },

    // MARK: - Device token storage

    TestCase("a token survives a store, a reload and a removal") {
        let blobs = InMemoryDeviceTokenStore()
        let store = DeviceTokenStore(blobs: blobs)
        try expectEqual(try store.load(), nil)

        let token = DeviceToken(
            token: "opaque.device.token",
            deviceId: "123456789",
            accountId: "acct_1",
            expiresAt: 1_756_000_000_000
        )
        try store.save(token)
        try expectEqual(try store.load(), token)

        try store.remove()
        try expectEqual(try store.load(), nil)
    },

    TestCase("the file backend round-trips the same bytes, owner-only") {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("rc-tests-token-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let file = DeviceTokenFile(directory: directory)
        let store = DeviceTokenStore(blobs: file)
        let token = DeviceToken(token: "t", deviceId: "987654321", accountId: "acct_2", expiresAt: 42)

        try store.save(token)
        try expectEqual(try store.load(), token)
        try expectEqual(try SecureFile.currentMode(of: file.fileURL), SecureFile.fileMode)

        try expectEqual(try DeviceTokenStore(blobs: DeviceTokenFile(directory: directory)).load(), token)
        try store.remove()
        try expectEqual(try store.load(), nil)
    },

    TestCase("a corrupt blob is reported, not silently treated as unlinked") {
        let blobs = InMemoryDeviceTokenStore()
        try blobs.save(Data("not json".utf8))
        do {
            _ = try DeviceTokenStore(blobs: blobs).load()
            throw fail("a corrupt token blob decoded")
        } catch is DeviceTokenStoreError {
        }
    },

    TestCase("a store that refuses surfaces the failure rather than losing the token") {
        let blobs = InMemoryDeviceTokenStore()
        blobs.isSealed = true
        do {
            try DeviceTokenStore(blobs: blobs).save(
                DeviceToken(token: "t", deviceId: "1", accountId: "a", expiresAt: 0))
            throw fail("a sealed store accepted a token")
        } catch is KeychainError {
        }
    },

    TestCase("API.md §1.5: a token inside seven days of expiry asks to be refreshed") {
        let soon = Date().addingTimeInterval(6 * 24 * 60 * 60)
        let later = Date().addingTimeInterval(30 * 24 * 60 * 60)
        let expiring = DeviceToken(
            token: "t", deviceId: "1", accountId: "a", expiresAt: Int64(soon.timeIntervalSince1970 * 1000))
        let fresh = DeviceToken(
            token: "t", deviceId: "1", accountId: "a", expiresAt: Int64(later.timeIntervalSince1970 * 1000))
        try expect(expiring.needsRefresh)
        try expectFalse(fresh.needsRefresh)
    },
])
