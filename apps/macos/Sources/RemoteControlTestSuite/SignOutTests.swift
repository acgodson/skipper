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

    static func reset(accountEmail: String?) {
        lock.lock()
        defer { lock.unlock() }
        recorded = []
        self.accountEmail = accountEmail
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
            return (204, "")
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
    _ body: @MainActor (AccountLinker, DeviceTokenStore) async throws -> Void
) async throws {
    StubbedAPI.reset(accountEmail: accountEmail)
    let directory = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("rc-tests-signout-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let identity = try IdentityStore(fileStore: IdentityFileStore(directory: directory),
                                     secrets: SecretStore(blobs: InMemorySecretStore()))
    let tokens = DeviceTokenStore(blobs: InMemoryDeviceTokenStore())
    try tokens.save(StubbedAPI.token(deviceId: "736789140"))
    let session = StubbedAPI.session()
    let linker = AccountLinker(
        identity: identity,
        client: APIClient(baseURL: URL(string: "https://api.skipperdesk.invalid")!,
                          session: session),
        tokens: tokens,
        webBaseURL: URL(string: "https://skipperdesk.invalid")!,
        openInBrowser: { _ in },
        hardwareIdentifier: { "test" }
    )
    await linker.restore()
    try expect(linker.state.isLinked, "the linker did not restore a signed-in state: \(linker.state)")
    defer { session.invalidateAndCancel() }
    try await body(linker, tokens)
}

public let signOutSuite = TestSuite("Account/sign out", [

    TestCase("signing out unlinks this device instead of only revoking its token") {
        try await withSignedInLinker(accountEmail: "verify-onemac@example.com") { linker, tokens in
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
        try await withSignedInLinker(accountEmail: "verify-onemac@example.com") { linker, _ in
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

    TestCase("the account card names the signed-in email, never the account id") {
        try await withSignedInLinker(accountEmail: "verify-onemac@example.com") { linker, _ in
            try expectEqual(linker.state, .linked(
                accountLabel: "verify-onemac@example.com",
                device: try expectNotNil(linker.state.device)))
        }
        try await withSignedInLinker(accountEmail: nil) { linker, _ in
            guard case .linked(let label, _) = linker.state else {
                throw fail("state = \(linker.state)")
            }
            try expectNil(label)
        }
        try await withSignedInLinker(accountEmail: "   ") { linker, _ in
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
