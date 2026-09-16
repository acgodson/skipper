// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "RemoteControl",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "RemoteControl", targets: ["RemoteControl"]),
        .library(name: "RemoteControlCore", targets: ["RemoteControlCore"]),
        .executable(name: "rc-tests", targets: ["rc-tests"]),
    ],
    // Exactly one third-party dependency: Google's libwebrtc, shipped as a binary
    // xcframework. SwiftPM consumes it under Command Line Tools alone (no Xcode).
    dependencies: [
        .package(url: "https://github.com/stasel/WebRTC.git", from: "125.0.0"),
    ],
    targets: [
        .executableTarget(
            name: "RemoteControl",
            dependencies: ["RemoteControlCore"],
            path: "Sources/RemoteControl"
        ),
        // BLAKE2b + Argon2id. Its own target for exactly one reason: it is
        // compiled with -O even in debug builds. Argon2id at the protocol's
        // parameters (64 MiB, 3 passes) takes ~30 s per call under -Onone, which
        // would make both `swift run rc-tests` and a debug app unusable. Nothing
        // in here is platform-specific, so the flag is safe.
        .target(
            name: "RCCrypto",
            path: "Sources/RCCrypto",
            swiftSettings: [.unsafeFlags(["-O"], .when(configuration: .debug))]
        ),
        .target(
            name: "RemoteControlCore",
            dependencies: ["RCCrypto", .product(name: "WebRTC", package: "WebRTC")],
            path: "Sources/RemoteControlCore"
        ),

        // Headless driver used by scripts/test-transport.sh to run two real
        // app-core instances against the live server. Not shipped in the .app.
        .executableTarget(
            name: "rc-node",
            dependencies: ["RemoteControlCore"],
            path: "Sources/rc-node"
        ),

        // Test plumbing. The suite bodies live in a plain library so that both
        // `swift run rc-tests` (works with Command Line Tools only) and
        // `swift test` (needs Xcode for XCTest.framework) run the same cases.
        .target(name: "RCTestKit", path: "Sources/RCTestKit"),
        .target(
            name: "RemoteControlTestSuite",
            dependencies: ["RCTestKit", "RemoteControlCore"],
            path: "Sources/RemoteControlTestSuite"
        ),
        .executableTarget(
            name: "rc-tests",
            dependencies: ["RCTestKit", "RemoteControlTestSuite"],
            path: "Sources/rc-tests"
        ),
        .testTarget(
            name: "RemoteControlCoreTests",
            dependencies: ["RCTestKit", "RemoteControlTestSuite"],
            path: "Tests/RemoteControlCoreTests"
        ),
    ]
)
