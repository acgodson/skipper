import Foundation
import RCTestKit
import RemoteControlTestSuite
import RemoteControlCore

@main
struct RCTests {

    @MainActor
    static func main() async {
        var arguments = Array(CommandLine.arguments.dropFirst())
        if arguments.first == "--emit-interop" {
            arguments.removeFirst()
            emitInterop(nonceBase64: arguments.first)
            return
        }

        print("RemoteControl \u{2014} test suite")
        let result = await run(allSuites)
        print("\n\(result.passed)/\(result.total) passed, \(result.failed) failed")
        if !result.failures.isEmpty {
            print("\nFailures:")
            result.failures.forEach { print("  \u{2022} \($0)") }
        }
        exit(result.failed == 0 ? 0 : 1)
    }

    /// Emits a real public key and a real signature over a caller-supplied nonce,
    /// as JSON on stdout, for `scripts/interop-sig.sh` to feed to the Go verifier.
    ///
    /// This is the only way to prove the two languages agree. The Swift-side unit
    /// tests can confirm the bytes *look* like DER SPKI and DER ECDSA, but only
    /// Go's own `auth.VerifyDeviceSig` can confirm Go accepts them.
    ///
    /// Everything printed here is public material: a public key, a nonce and a
    /// signature. The private key stays in the throwaway identity file and is
    /// never written to stdout.
    @MainActor
    static func emitInterop(nonceBase64: String?) {
        guard let nonceBase64, let nonce = Data(base64Encoded: nonceBase64) else {
            FileHandle.standardError.write(Data(
                "usage: rc-tests --emit-interop <base64-nonce>\n".utf8))
            exit(2)
        }
        // A scratch identity in a temp directory, so this never reads, writes or
        // disturbs the user's real ~/Library/Application Support/RemoteControl.
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("rc-interop-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        do {
            let identity = try IdentityStore(fileStore: IdentityFileStore(directory: directory))
            let payload: [String: String] = [
                "deviceId": identity.deviceID,
                "pubkey": identity.publicKeyBase64,
                "nonce": nonceBase64,
                "sig": try identity.signatureBase64(for: nonce),
            ]
            let json = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
            FileHandle.standardOutput.write(json)
            FileHandle.standardOutput.write(Data("\n".utf8))
        } catch {
            FileHandle.standardError.write(Data("emit-interop failed: \(error)\n".utf8))
            exit(1)
        }
    }
}
