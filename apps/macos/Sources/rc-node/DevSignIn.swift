import Foundation
import RemoteControlCore

// Non-interactive API.md §1 sign-in against an rc-api running the dev identity provider:
// the dev user session stands in for the browser, AccountLinker does the rest.
@MainActor
final class DevSignIn {

    enum Failure: Error, LocalizedError {
        case linkRejected(Int, String)
        case malformedLinkRequest
        case timedOut
        case failed(String)

        var errorDescription: String? {
            switch self {
            case .linkRejected(let status, let body): return "POST /v1/auth/link answered \(status): \(body)"
            case .malformedLinkRequest: return "AccountLinker built a link URL without nonce and device"
            case .timedOut: return "the sign-in did not finish in time"
            case .failed(let message): return message
            }
        }
    }

    static let timeout: TimeInterval = 30

    private let email: String
    private let identity: IdentityStore
    private let apiBaseURL: URL
    private var linker: AccountLinker!
    private var linkFailure: Error?

    init(email: String, identity: IdentityStore, apiBaseURL: URL = RCConfig.current.apiBaseURL) {
        self.email = email
        self.identity = identity
        self.apiBaseURL = apiBaseURL
        let pubkey = identity.publicKeyBase64
        self.linker = AccountLinker(
            identity: identity,
            webBaseURL: apiBaseURL,
            openInBrowser: { [weak self] url in self?.actAsBrowser(url) },
            hardwareIdentifier: { "dev-sign-in:\(pubkey)" }
        )
    }

    func run() async throws -> (device: DeviceRecord, accountId: String, entitlement: Entitlement?) {
        linkFailure = nil
        linker.beginLink()
        let deadline = Date().addingTimeInterval(Self.timeout)
        while Date() < deadline {
            if let linkFailure { throw linkFailure }
            switch linker.state {
            case .linked(let accountId, let device):
                return (device, accountId ?? "", linker.entitlement?.value)
            case .error(let message):
                throw Failure.failed(message)
            case .unlinked, .linking:
                try await Task.sleep(nanoseconds: 100_000_000)
            }
        }
        throw Failure.timedOut
    }

    private func actAsBrowser(_ linkPage: URL) {
        let query = URLComponents(url: linkPage, resolvingAgainstBaseURL: false)?.queryItems ?? []
        guard let nonce = query.first(where: { $0.name == "nonce" })?.value,
              let device = query.first(where: { $0.name == "device" })?.value else {
            linkFailure = Failure.malformedLinkRequest
            return
        }
        Task {
            do {
                let code = try await mintLinkCode(nonce: nonce, pubkey: device)
                var callback = URLComponents()
                callback.scheme = AccountLinker.callbackScheme
                callback.host = AccountLinker.callbackHost
                callback.queryItems = [
                    URLQueryItem(name: "code", value: code),
                    URLQueryItem(name: "nonce", value: nonce),
                ]
                guard let url = callback.url, linker.handleCallback(url) else {
                    throw Failure.failed("the link callback was not accepted")
                }
            } catch {
                linkFailure = error
            }
        }
    }

    private func mintLinkCode(nonce: String, pubkey: String) async throws -> String {
        struct LinkAnswer: Decodable { let code: String }
        var request = URLRequest(url: apiBaseURL.appendingPathComponent("v1/auth/link"))
        request.httpMethod = "POST"
        request.setValue("Bearer dev:\(email)", forHTTPHeaderField: "Authorization")
        request.setValue(APIClient.newIdempotencyKey(), forHTTPHeaderField: APIClient.idempotencyHeader)
        request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode([
            "nonce": nonce,
            "pubkey": pubkey,
            "platform": "macos",
            "label": RCConfig.current.deviceLabel,
        ])
        let (data, response) = try await APIClient.defaultSession().data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 201 else {
            throw Failure.linkRejected(status, String(decoding: data, as: UTF8.self))
        }
        return try JSONDecoder().decode(LinkAnswer.self, from: data).code
    }
}
