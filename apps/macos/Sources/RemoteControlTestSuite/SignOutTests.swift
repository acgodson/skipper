import Foundation
import RCTestKit
import RemoteControlCore

// The sign-out path of API.md §3.6: the app unlinks this device, and it ends the
// live session first. A stub URLProtocol records what actually went on the wire.

final class StubbedAPI: URLProtocol {

    struct Call: Equatable {
        let method: String
        let path: String
        let authorization: String?
    }

    private static let lock = NSLock()
    private static var recorded: [Call] = []
    private static var accountEmail: String?
    private static var unlinkStatus = 204

    static func reset(accountEmail: String?) {
        lock.lock()
        defer { lock.unlock() }
        recorded = []
        unlinkStatus = 204
        self.accountEmail = accountEmail
    }

    /// What `DELETE /v1/devices/{id}` answers: 503 is rc-api saying it could not
    /// confirm the live session was closed.
    static func answerUnlink(with status: Int) {
        lock.lock()
        defer { lock.unlock() }
        unlinkStatus = status
    }

    static var calls: [Call] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubbedAPI.self]
        configuration.connectionProxyDictionary = [:]
        return URLSession(configuration: configuration)
    }

    static func token(deviceId: String) -> DeviceToken {
        lock.lock()
        let email = accountEmail
        lock.unlock()
        return DeviceToken(
            token: "opaque.device.token", deviceId: deviceId, accountId: "acct_01HQ9",
            accountEmail: email,
            expiresAt: Int64(Date().addingTimeInterval(90 * 24 * 60 * 60).timeIntervalSince1970 * 1000))
    }

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let path = request.url?.path ?? ""
        let method = request.httpMethod ?? ""
        Self.lock.lock()
        Self.recorded.append(Call(
            method: method, path: path,
            authorization: request.value(forHTTPHeaderField: "Authorization")))
        Self.lock.unlock()

        let (status, body) = Self.answer(method: method, path: path)
        let response = HTTPURLResponse(
            url: request.url!, statusCode: status,
            httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if !body.isEmpty { client?.urlProtocol(self, didLoad: Data(body.utf8)) }
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private static func answer(method: String, path: String) -> (Int, String) {
        switch (method, path) {
        case ("DELETE", let path) where path.hasPrefix("/v1/devices/"):
            lock.lock()
            let status = unlinkStatus
            lock.unlock()
            if status == 204 { return (204, "") }
            return (status, #"{"error":{"code":"unavailable","message":"try again","requestId":"r"}}"#)
        case ("GET", let path) where path.hasPrefix("/v1/devices/"):
            return (200, """
            {"deviceId":"736789140","label":"Verify Host","platform":"macos","pubkey":"",
            "createdAt":1,"linkedAt":1,"lastSeen":1,"trialEndsAt":1900000000000}
            """)
        case ("GET", "/v1/entitlement"):
            return (200, """
            {"status":"trial","tier":"base","trialEndsAt":1900000000000,
            "concurrency":{"maxActivePairs":1},"refreshAfterSec":60}
            """)
        default:
            return (404, #"{"error":{"code":"not_found","message":"no such path","requestId":"r"}}"#)
        }
    }
}

@MainActor
private func withSignedInLinker(
    accountEmail: String?,
    openInBrowser: @escaping (URL) -> Void = { _ in },
    _ body: @MainActor (AccountLinker, DeviceTokenStore, PendingUnlinkStore) async throws -> Void
) async throws {
    StubbedAPI.reset(accountEmail: accountEmail)
    let directory = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("rc-tests-signout-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let identity = try IdentityStore(fileStore: IdentityFileStore(directory: directory),
                                     secrets: SecretStore(blobs: InMemorySecretStore()))
    let tokens = DeviceTokenStore(blobs: InMemoryDeviceTokenStore())
    let pending = PendingUnlinkStore(blobs: InMemoryDeviceTokenStore())
    try tokens.save(StubbedAPI.token(deviceId: "736789140"))
    let session = StubbedAPI.session()
    let linker = AccountLinker(
        identity: identity,
        client: APIClient(baseURL: URL(string: "https://api.skipperdesk.invalid")!,
                          session: session),
        tokens: tokens,
        pendingUnlinks: pending,
        webBaseURL: URL(string: "https://skipperdesk.invalid")!,
        openInBrowser: openInBrowser,
        hardwareIdentifier: { "test" }
    )
    await linker.restore()
    try expect(linker.state.isLinked, "the linker did not restore a signed-in state: \(linker.state)")
    defer { session.invalidateAndCancel() }
    try await body(linker, tokens, pending)
}

public let signOutSuite = TestSuite("Account/sign out", [

    TestCase("signing out unlinks this device instead of only revoking its token") {
        try await withSignedInLinker(accountEmail: "verify-onemac@example.com") { linker, tokens, _ in
            await linker.unlink()

            let unlink = try expectNotNil(StubbedAPI.calls.last)
            try expectEqual(unlink.method, "DELETE")
            try expectEqual(unlink.path, "/v1/devices/736789140")
            try expectEqual(unlink.authorization, "Bearer opaque.device.token")
            try expectFalse(StubbedAPI.calls.contains(where: { $0.path.contains("revoke") }),
                            "sign-out still calls the revoke endpoint")
            try expectEqual(linker.state, .unlinked)
            try expectNil(linker.entitlement)
            try expectNil(try tokens.load())
        }
    },

    TestCase("sign-out ends the live session before it clears the account") {
        var steps: [String] = []
        var sessionOpen = true
        try await withSignedInLinker(accountEmail: "verify-onemac@example.com") { linker, _, _ in
            let signOut = AfterSessionEnds(
                sessionIsOpen: { sessionOpen },
                endSession: { steps.append("end session"); sessionOpen = false },
                forceStop: { steps.append("force stop") },
                then: {
                    steps.append(sessionOpen ? "sign out while the session is open" : "sign out")
                    await linker.unlink()
                    steps.append(linker.state == .unlinked ? "account cleared" : "account kept")
                },
                pollInterval: 0.001, gracePeriod: 1)
            try await signOut.run()
        }
        try expectEqual(steps, ["end session", "sign out", "account cleared"])
    },

    TestCase("a sign-out the server refused keeps this Mac signed in and says so") {
        try await withSignedInLinker(accountEmail: "verify-onemac@example.com") { linker, tokens, pending in
            StubbedAPI.answerUnlink(with: 503)
            await linker.unlink()

            try expectEqual(linker.state, .error(message: AccountLinker.signOutUnfinished))
            try expectNotNil(try tokens.load(), "the credential was thrown away before the server confirmed")
            let queued = try expectNotNil(try pending.load())
            try expectEqual(queued.deviceId, "736789140")
            try expectEqual(queued.token, "opaque.device.token")
            try expect(linker.hasPendingUnlink)
        }
    },

    TestCase("the unfinished sign-out is retried at the next launch") {
        try await withSignedInLinker(accountEmail: "verify-onemac@example.com") { linker, tokens, pending in
            StubbedAPI.answerUnlink(with: 503)
            await linker.unlink()
            try expect(linker.hasPendingUnlink)

            StubbedAPI.answerUnlink(with: 204)
            await linker.restore()

            try expectFalse(linker.hasPendingUnlink, "the pending sign-out survived a successful retry")
            try expectNil(try pending.load())
            try expectNil(try tokens.load())
            try expectEqual(linker.state, .unlinked)
            try expectNil(linker.entitlement)
        }
    },

    TestCase("signing in again finishes the unfinished sign-out first") {
        var opened: [URL] = []
        try await withSignedInLinker(
            accountEmail: "verify-onemac@example.com",
            openInBrowser: { opened.append($0) }
        ) { linker, _, pending in
            StubbedAPI.answerUnlink(with: 503)
            await linker.unlink()

            linker.beginLink()
            await Task.yield()
            try expectEqual(opened.count, 0, "a browser sign-in started while this Mac was still linked elsewhere")
            try expectEqual(linker.state, .error(message: AccountLinker.signOutUnfinished))
            try expectNotNil(try pending.load())

            StubbedAPI.answerUnlink(with: 204)
            linker.beginLink()
            for _ in 0..<100 where opened.isEmpty { await Task.yield() }
            try expectEqual(opened.count, 1, "sign-in never started once the sign-out finished")
            try expectNil(try pending.load())
        }
    },

    TestCase("the account card names the signed-in email, never the account id") {
        try await withSignedInLinker(accountEmail: "verify-onemac@example.com") { linker, _, _ in
            try expectEqual(linker.state, .linked(
                accountLabel: "verify-onemac@example.com",
                device: try expectNotNil(linker.state.device)))
        }
        try await withSignedInLinker(accountEmail: nil) { linker, _, _ in
            guard case .linked(let label, _) = linker.state else {
                throw fail("state = \(linker.state)")
            }
            try expectNil(label)
        }
        try await withSignedInLinker(accountEmail: "   ") { linker, _, _ in
            guard case .linked(let label, _) = linker.state else {
                throw fail("state = \(linker.state)")
            }
            try expectNil(label)
        }
    },
])

extension AccountState {
    var device: DeviceRecord? {
        if case .linked(_, let device) = self { return device }
        return nil
    }
}
