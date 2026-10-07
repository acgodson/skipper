import Foundation
import RCTestKit
import RemoteControlCore

private let started = Date(timeIntervalSince1970: 1_800_000_000)
private let pendingNonce = "q2Vn5a0l3Yt0bKc9Qm1xR8wZp4uH6sJd7fGe2iLoNcA"

private func callback(code: String? = "one-time-code", nonce: String? = pendingNonce) -> URL {
    var parts = URLComponents()
    parts.scheme = AccountLinker.callbackScheme
    parts.host = AccountLinker.callbackHost
    parts.queryItems = [
        code.map { URLQueryItem(name: "code", value: $0) },
        nonce.map { URLQueryItem(name: "nonce", value: $0) },
    ].compactMap { $0 }
    return parts.url!
}

private func verdict(_ url: URL, pending: String? = pendingNonce, after seconds: TimeInterval = 5) -> LinkCallbackVerdict {
    AccountLinker.verdict(
        for: url, pendingNonce: pending, startedAt: pending == nil ? nil : started,
        now: started.addingTimeInterval(seconds))
}

@MainActor
private func withLinker(_ body: @MainActor (AccountLinker, () -> URL?) async throws -> Void) async throws {
    let directory = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("rc-tests-link-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let identity = try IdentityStore(fileStore: IdentityFileStore(directory: directory),
                                     secrets: SecretStore(blobs: InMemorySecretStore()))
    var opened: URL?
    let linker = AccountLinker(
        identity: identity,
        client: APIClient(baseURL: URL(string: "http://127.0.0.1:9")!),
        tokens: DeviceTokenStore(blobs: InMemoryDeviceTokenStore()),
        pendingUnlinks: PendingUnlinkStore(blobs: InMemoryDeviceTokenStore()),
        webBaseURL: URL(string: "https://skipperdesk.invalid")!,
        openInBrowser: { opened = $0 },
        hardwareIdentifier: { "test" }
    )
    try await body(linker, { opened })
}

private func nonce(in linkPage: URL?) throws -> String {
    let items = linkPage.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false)?.queryItems } ?? []
    return try expectNotNil(items.first(where: { $0.name == "nonce" })?.value)
}

public let linkCallbackSuite = TestSuite("LinkCallback", [

    TestCase("API.md §1.1: a callback echoing the pending nonce is accepted with its code") {
        try expectEqual(verdict(callback()), .accepted(code: "one-time-code", nonce: pendingNonce))
    },

    TestCase("a callback with another attempt's nonce is rejected") {
        try expectEqual(verdict(callback(nonce: "attacker-minted-nonce")), .nonceMismatch)
        var flipped = Array(pendingNonce)
        flipped[flipped.count - 1] = flipped.last == "A" ? "B" : "A"
        try expectEqual(verdict(callback(nonce: String(flipped))), .nonceMismatch)
        try expectEqual(verdict(callback(nonce: String(pendingNonce.dropLast()))), .nonceMismatch)
    },

    TestCase("a callback without a nonce is rejected, even when it carries a code") {
        try expectEqual(verdict(callback(nonce: nil)), .nonceMismatch)
        try expectEqual(verdict(callback(nonce: "")), .nonceMismatch)
    },

    TestCase("the nonce is checked before the code, so a bare callback reveals nothing") {
        try expectEqual(verdict(callback(code: nil, nonce: nil)), .nonceMismatch)
        try expectEqual(verdict(callback(code: nil)), .missingCode)
    },

    TestCase("with no attempt in progress every callback is ignored") {
        try expectEqual(verdict(callback(), pending: nil), .noAttempt)
    },

    TestCase("an attempt older than its lifetime is expired whatever the callback says") {
        try expectEqual(verdict(callback(), after: AccountLinker.linkAttemptLifetime), .expired)
        try expectEqual(verdict(callback(nonce: "wrong"), after: AccountLinker.linkAttemptLifetime * 2), .expired)
    },

    TestCase("the window fits a first-time sign-up, verification email and all") {
        try expect(AccountLinker.linkAttemptLifetime >= 10 * 60,
                   "a sign-up that waits for a verification email cannot finish in \(AccountLinker.linkAttemptLifetime) s")
        try expectEqual(verdict(callback(), after: 9 * 60), .accepted(code: "one-time-code", nonce: pendingNonce))
        try expectEqual(verdict(callback(), after: AccountLinker.linkAttemptLifetime - 1),
                        .accepted(code: "one-time-code", nonce: pendingNonce))
    },

    TestCase("other URLs are not ours") {
        try expectEqual(verdict(URL(string: "skipperdesk://other?code=c&nonce=\(pendingNonce)")!), .notOurs)
        try expectEqual(verdict(URL(string: "https://link?code=c&nonce=\(pendingNonce)")!), .notOurs)
    },

    TestCase("a wrong-nonce callback burns the attempt, so the real callback cannot follow it") {
        try await withLinker { linker, opened in
            linker.beginLink()
            let real = try nonce(in: opened())
            try expect(linker.hasPendingLink)

            try expect(linker.handleCallback(callback(nonce: "attacker-minted-nonce")))
            try expectFalse(linker.hasPendingLink, "a mismatch must end the pending attempt")
            try expectEqual(linker.state, .unlinked, "a mismatch is logged, not shown")

            try expect(linker.handleCallback(callback(nonce: real)))
            try expectFalse(linker.hasPendingLink)
            try expectEqual(linker.state, .unlinked, "the burned attempt accepts nothing afterwards")
        }
    },

    TestCase("a nonce-less callback during an attempt burns it without an error") {
        try await withLinker { linker, _ in
            linker.beginLink()
            try expect(linker.handleCallback(callback(nonce: nil)))
            try expectFalse(linker.hasPendingLink)
            try expectEqual(linker.state, .unlinked)
        }
    },

    TestCase("an accepted callback is single-use: a replay finds no attempt") {
        try await withLinker { linker, opened in
            linker.beginLink()
            let url = callback(nonce: try nonce(in: opened()))
            try expect(linker.handleCallback(url))
            try expectFalse(linker.hasPendingLink, "the attempt is consumed on acceptance")
            try expectEqual(
                AccountLinker.verdict(for: url, pendingNonce: nil, startedAt: nil, now: Date()), .noAttempt)
            try expect(linker.handleCallback(url))
            try expectFalse(linker.hasPendingLink)
        }
    },
])
