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

/// `Task.yield()` hands the main actor back; it does not wait for anything. A
/// URLSession answer is delivered off the main actor, so a hundred yields can
/// elapse in well under a millisecond and a test that spins on them is asserting
/// against whichever side won a footrace. These wait on the clock.
@MainActor
private func wait(upTo seconds: Double = 5, until ready: () -> Bool) async {
    let deadline = Date().addingTimeInterval(seconds)
    while !ready() && Date() < deadline {
        try? await Task.sleep(nanoseconds: 2_000_000)
    }
}

@MainActor
private func settle() async {
    try? await Task.sleep(nanoseconds: 300_000_000)
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
            await settle()
            try expectEqual(opened.count, 0, "a browser sign-in started while this Mac was still linked elsewhere")
            try expectEqual(linker.state, .error(message: AccountLinker.signOutUnfinished))
            try expectNotNil(try pending.load())

            StubbedAPI.answerUnlink(with: 204)
            linker.beginLink()
            await wait { !opened.isEmpty }
            try expectEqual(opened.count, 1, "sign-in never started once the sign-out finished")
            try expectNil(try pending.load())

            await settle()
            try expectEqual(opened.count, 1, "the finished sign-out opened a second browser sign-in")
        }
    },

    // Choosing Sign in twice while the sign-out retry is still on the wire is one
    // request, not two. Both retries can succeed — the second is a no-op server
    // side — and each used to go on to open its own browser window.
    TestCase("choosing sign-in twice during a pending sign-out opens one browser window") {
        var opened: [URL] = []
        try await withSignedInLinker(
            accountEmail: "verify-onemac@example.com",
            openInBrowser: { opened.append($0) }
        ) { linker, _, pending in
            StubbedAPI.answerUnlink(with: 503)
            await linker.unlink()
            try expect(linker.hasPendingUnlink)

            // APIClient retries a 503 of its own accord, so only the growth from
            // here is the sign-out being retried.
            let unlinksBefore = StubbedAPI.calls.filter { $0.method == "DELETE" }.count

            StubbedAPI.answerUnlink(with: 204)
            linker.beginLink()
            linker.beginLink()
            linker.beginLink()

            await wait { !opened.isEmpty }
            await settle()
            try expectEqual(opened.count, 1, "each choice of Sign in opened its own browser window")
            try expectNil(try pending.load())
            try expectEqual(StubbedAPI.calls.filter { $0.method == "DELETE" }.count - unlinksBefore, 1,
                            "the queued sign-out was retried once per choice of Sign in")
        }
    },

    // Two sign-ins can be waiting on a pending sign-out at once, and the one
    // whose retry failed used to read the other one's success out of the store
    // and open a second browser window. Each retry now reports its own outcome.
    TestCase("a sign-out retry reports its own outcome, not whatever the store says now") {
        try await withSignedInLinker(accountEmail: "verify-onemac@example.com") { linker, _, pending in
            StubbedAPI.answerUnlink(with: 503)
            await linker.unlink()
            try expect(linker.hasPendingUnlink)

            try expectFalse(await linker.retryPendingUnlink(),
                            "a retry the server refused reported success")
            try expectNotNil(try pending.load())

            StubbedAPI.answerUnlink(with: 204)
            try expect(await linker.retryPendingUnlink(),
                       "a retry the server accepted reported failure")
            try expectFalse(linker.hasPendingUnlink)

            try expect(await linker.retryPendingUnlink(),
                       "with nothing queued there is nothing to report as unfinished")
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
