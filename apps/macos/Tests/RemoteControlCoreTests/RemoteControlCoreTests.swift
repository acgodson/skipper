import XCTest
import RCTestKit
@testable import RemoteControlTestSuite

/// XCTest front end over the shared suite in `Sources/RemoteControlTestSuite`.
///
/// NOTE: `swift test` requires `XCTest.framework`, which ships with Xcode and
/// NOT with the Command Line Tools. On a CLT-only machine this target cannot be
/// built (`error: XCTest not available`) — run `swift run rc-tests` instead,
/// which executes exactly the same cases.
final class RemoteControlCoreTests: XCTestCase {

    func testAllSuites() async throws {
        var failures: [String] = []
        var passed = 0
        for suite in allSuites {
            for testCase in suite.cases {
                do {
                    try await testCase.run()
                    passed += 1
                } catch {
                    failures.append("\(suite.name).\(testCase.name): \(error)")
                }
            }
        }
        for failure in failures { XCTFail(failure) }
        XCTAssertGreaterThan(passed, 0, "no test cases ran")
        XCTAssertTrue(failures.isEmpty, "\(failures.count) case(s) failed")
    }
}
