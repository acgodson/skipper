// swift-tools-version:5.9
import Foundation
import PackageDescription

// The shared Rust core, built by scripts/build-core.sh. The path is derived from
// this manifest rather than from the working directory so `swift build` works
// from anywhere, and a missing library is reported here instead of as a wall of
// undefined _skipper_session_* symbols from the linker.
let repoRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .deletingLastPathComponent()
let coreLibraryDirectory = repoRoot.appendingPathComponent("core/target/release").path
let coreLibrary = coreLibraryDirectory + "/librc_ffi.a"
if !FileManager.default.fileExists(atPath: coreLibrary) {
    fatalError("""

        The shared Rust core is not built.

        \(coreLibraryDirectory)/librc_ffi.a is missing, and SkipperCore — which
        owns the session state machine — cannot link without it.

        Run this first, from the repository root:

            ./scripts/build-core.sh

        (./scripts/build.sh does it for you.)

        """)
}

let package = Package(
    name: "RemoteControl",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "RemoteControl", targets: ["RemoteControl"]),
        .library(name: "RemoteControlCore", targets: ["RemoteControlCore"]),
        .executable(name: "rc-tests", targets: ["rc-tests"]),
    ],
    // Exactly one third-party dependency: Google's libwebrtc, prebuilt as a binary
    // xcframework by stasel/WebRTC and pinned to one exact version and checksum.
    dependencies: [
        .package(url: "https://github.com/stasel/WebRTC.git", exact: "125.0.0"),
    ],
    targets: [
        .executableTarget(
            name: "RemoteControl",
            dependencies: ["RemoteControlCore", "SkipperCore", "SkipperDesign"],
            path: "Sources/RemoteControl"
        ),

        // The design system (docs/DESIGN.md): tokens and components only, never RemoteControlCore.
        .target(
            name: "SkipperDesign",
            path: "Sources/SkipperDesign"
        ),
        // The C ABI of the shared Rust core. Nothing but the module map lives
        // here; the header itself stays next to the crate that implements it.
        .systemLibrary(name: "CSkipperCore", path: "Sources/CSkipperCore"),

        // The shared core, as Swift sees it: the ONE session state machine,
        // plus the types its actions are made of. The implementation is
        // core/crates/rc-session; this target only marshals.
        .target(
            name: "SkipperCore",
            dependencies: ["CSkipperCore"],
            path: "Sources/SkipperCore",
            linkerSettings: [
                .unsafeFlags([coreLibrary]),
            ]
        ),
        .target(
            name: "RemoteControlCore",
            dependencies: ["SkipperCore", .product(name: "WebRTC", package: "WebRTC")],
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
            dependencies: ["RCTestKit", "RemoteControlCore", "SkipperCore"],
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
