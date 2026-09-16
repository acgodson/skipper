import Foundation

/// A dependency-free assertion + test-registry kit.
///
/// WHY THIS EXISTS: this machine has Command Line Tools only, and CLT ships no
/// `XCTest.framework`, so `swift test` cannot link (`error: XCTest not available`).
/// The test bodies therefore live in a plain library target and are driven by two
/// front ends over the same single source of truth:
///
///   * `swift run rc-tests`  — works today, no Xcode required.
///   * `swift test`          — `Tests/RemoteControlCoreTests` bridges these same
///                             cases into XCTest for anyone with Xcode installed.
public struct TestFailure: Error, CustomStringConvertible {
    public let message: String
    public let file: StaticString
    public let line: UInt

    public init(message: String, file: StaticString = #file, line: UInt = #line) {
        self.message = message
        self.file = file
        self.line = line
    }

    public var description: String {
        "\(("\(file)" as NSString).lastPathComponent):\(line): \(message)"
    }
}

public struct TestCase {
    public let name: String
    public let run: @MainActor () async throws -> Void

    public init(_ name: String, _ run: @escaping @MainActor () async throws -> Void) {
        self.name = name
        self.run = run
    }
}

public struct TestSuite {
    public let name: String
    public let cases: [TestCase]

    public init(_ name: String, _ cases: [TestCase]) {
        self.name = name
        self.cases = cases
    }
}

// MARK: - Assertions

/// Unconditional failure. For the cases where the check is a `switch` or a
/// `guard` rather than a boolean — pattern-matching an enum, say.
public func fail(
    _ message: @autoclosure () -> String,
    file: StaticString = #file,
    line: UInt = #line
) -> TestFailure {
    TestFailure(message: message(), file: file, line: line)
}

public func expect(
    _ condition: Bool,
    _ message: @autoclosure () -> String = "expected true",
    file: StaticString = #file,
    line: UInt = #line
) throws {
    if !condition { throw TestFailure(message: message(), file: file, line: line) }
}

public func expectFalse(
    _ condition: Bool,
    _ message: @autoclosure () -> String = "expected false",
    file: StaticString = #file,
    line: UInt = #line
) throws {
    if condition { throw TestFailure(message: message(), file: file, line: line) }
}

public func expectEqual<T: Equatable>(
    _ actual: T,
    _ expected: T,
    _ message: @autoclosure () -> String = "",
    file: StaticString = #file,
    line: UInt = #line
) throws {
    if actual != expected {
        let suffix = message().isEmpty ? "" : " — \(message())"
        throw TestFailure(
            message: "expected \(expected), got \(actual)\(suffix)",
            file: file, line: line
        )
    }
}

public func expectNotEqual<T: Equatable>(
    _ actual: T,
    _ other: T,
    _ message: @autoclosure () -> String = "",
    file: StaticString = #file,
    line: UInt = #line
) throws {
    if actual == other {
        let suffix = message().isEmpty ? "" : " — \(message())"
        throw TestFailure(message: "expected a value other than \(other)\(suffix)", file: file, line: line)
    }
}

public func expectNil<T>(
    _ value: T?,
    _ message: @autoclosure () -> String = "",
    file: StaticString = #file,
    line: UInt = #line
) throws {
    if let value {
        let suffix = message().isEmpty ? "" : " — \(message())"
        throw TestFailure(message: "expected nil, got \(value)\(suffix)", file: file, line: line)
    }
}

@discardableResult
public func expectNotNil<T>(
    _ value: T?,
    _ message: @autoclosure () -> String = "",
    file: StaticString = #file,
    line: UInt = #line
) throws -> T {
    guard let value else {
        let suffix = message().isEmpty ? "" : " — \(message())"
        throw TestFailure(message: "expected a value, got nil\(suffix)", file: file, line: line)
    }
    return value
}

public func expectGreaterThanOrEqual<T: Comparable>(
    _ actual: T, _ bound: T,
    _ message: @autoclosure () -> String = "",
    file: StaticString = #file, line: UInt = #line
) throws {
    if !(actual >= bound) {
        throw TestFailure(message: "expected >= \(bound), got \(actual) \(message())", file: file, line: line)
    }
}

public func expectLessThan<T: Comparable>(
    _ actual: T, _ bound: T,
    _ message: @autoclosure () -> String = "",
    file: StaticString = #file, line: UInt = #line
) throws {
    if !(actual < bound) {
        throw TestFailure(message: "expected < \(bound), got \(actual) \(message())", file: file, line: line)
    }
}

public func expectGreaterThan<T: Comparable>(
    _ actual: T, _ bound: T,
    _ message: @autoclosure () -> String = "",
    file: StaticString = #file, line: UInt = #line
) throws {
    if !(actual > bound) {
        throw TestFailure(message: "expected > \(bound), got \(actual) \(message())", file: file, line: line)
    }
}

/// Floating-point equality with an explicit tolerance.
///
/// Every geometry assertion in the capture suite names the exact number it
/// expects; the tolerance is there for binary representation only (1e-9 is far
/// tighter than any real error — a one-pixel mistake is 1e0), never to let a
/// wrong answer through.
public func expectClose(
    _ actual: Double,
    _ expected: Double,
    tolerance: Double = 1e-9,
    _ message: @autoclosure () -> String = "",
    file: StaticString = #file,
    line: UInt = #line
) throws {
    if !(abs(actual - expected) <= tolerance) {
        let suffix = message().isEmpty ? "" : " — \(message())"
        throw TestFailure(
            message: "expected \(expected) ± \(tolerance), got \(actual)\(suffix)",
            file: file, line: line)
    }
}

#if canImport(CoreGraphics)
import CoreGraphics

public func expectClose(
    _ actual: CGPoint,
    _ expected: CGPoint,
    tolerance: Double = 1e-9,
    _ message: @autoclosure () -> String = "",
    file: StaticString = #file,
    line: UInt = #line
) throws {
    try expectClose(Double(actual.x), Double(expected.x), tolerance: tolerance,
                    "x of \(actual) vs \(expected) \(message())", file: file, line: line)
    try expectClose(Double(actual.y), Double(expected.y), tolerance: tolerance,
                    "y of \(actual) vs \(expected) \(message())", file: file, line: line)
}

public func expectClose(
    _ actual: CGRect,
    _ expected: CGRect,
    tolerance: Double = 1e-9,
    _ message: @autoclosure () -> String = "",
    file: StaticString = #file,
    line: UInt = #line
) throws {
    try expectClose(actual.origin, expected.origin, tolerance: tolerance, message(), file: file, line: line)
    try expectClose(Double(actual.width), Double(expected.width), tolerance: tolerance,
                    "width \(message())", file: file, line: line)
    try expectClose(Double(actual.height), Double(expected.height), tolerance: tolerance,
                    "height \(message())", file: file, line: line)
}
#endif

/// Asserts the operation throws. Fails if it returns normally.
public func expectThrows(
    _ description: String = "an error",
    file: StaticString = #file,
    line: UInt = #line,
    _ operation: () async throws -> Void
) async throws {
    do {
        try await operation()
    } catch {
        return
    }
    throw TestFailure(message: "expected \(description) to be thrown", file: file, line: line)
}

// MARK: - Runner

public struct TestRunResult {
    public var passed = 0
    public var failed = 0
    public var failures: [String] = []
    public var total: Int { passed + failed }
}

@MainActor
public func run(_ suites: [TestSuite], verbose: Bool = true) async -> TestRunResult {
    var result = TestRunResult()
    for suite in suites {
        if verbose { print("\n\(suite.name)") }
        for testCase in suite.cases {
            do {
                try await testCase.run()
                result.passed += 1
                if verbose { print("  ok    \(testCase.name)") }
            } catch {
                result.failed += 1
                let line = "\(suite.name).\(testCase.name): \(error)"
                result.failures.append(line)
                if verbose { print("  FAIL  \(testCase.name)\n        \(error)") }
            }
        }
    }
    return result
}
