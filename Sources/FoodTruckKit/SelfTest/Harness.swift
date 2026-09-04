import Foundation

/// A test harness that ships inside the product.
///
/// Neither swift-testing nor XCTest is present in Command Line Tools -- both
/// arrive with the full Xcode install, verified on macOS 26.6 -- and requiring a
/// 17 GB download to run `swift test` would make this project exactly the kind
/// of thing it exists to prevent. So the harness is here, in about a hundred
/// lines, with no dependencies.
///
/// Shipping it turns out to be the better design anyway. The people using
/// FoodTruck cannot debug it, but they can run `foodtruck selftest` and send the
/// output, and that output comes from the same signed binary that misbehaved --
/// not from a build someone made on a different machine six weeks ago. It also
/// gives the mutation-testing harness something to point at.
///
/// Output is TAP version 14, so CI reads it without a bespoke parser.
public struct Expectation: Sendable {
    let passed: Bool
    let describe: String
    let file: String
    let line: Int
}

public final class Scope: @unchecked Sendable {
    var expectations: [Expectation] = []
    private let lock = NSLock()

    /// `require` is the assertion. It records rather than aborting, so one bad
    /// assumption produces one failure line instead of hiding the twelve after it.
    public func require(
        _ condition: Bool, _ describe: @autoclosure () -> String,
        file: String = #fileID, line: Int = #line
    ) {
        lock.lock(); defer { lock.unlock() }
        expectations.append(Expectation(
            passed: condition, describe: describe(), file: file, line: line))
    }

    public func equal<T: Equatable>(
        _ actual: T, _ expected: T, _ describe: @autoclosure () -> String,
        file: String = #fileID, line: Int = #line
    ) {
        require(actual == expected,
                "\(describe()) — expected \(expected), got \(actual)", file: file, line: line)
    }
}

public struct Case: Sendable {
    public let name: String
    public let body: @Sendable (Scope) async throws -> Void
    public init(_ name: String, _ body: @escaping @Sendable (Scope) async throws -> Void) {
        self.name = name; self.body = body
    }
}

public struct Suite: Sendable {
    public let name: String
    public let cases: [Case]
    public init(_ name: String, _ cases: [Case]) { self.name = name; self.cases = cases }
}

public struct SelfTestReport: Sendable {
    public var passed = 0
    public var failed = 0
    public var duration: Double = 0
    public var failures: [String] = []
    public var isClean: Bool { failed == 0 }
}

public enum SelfTest {
    public static var suites: [Suite] {
        [LocationSuite.suite, GraphSuite.suite, ReportSuite.suite, EvidenceSuite.suite,
         ReadOnlySuite.suite, ConvergeSuite.suite, IntlSuite.suite]
    }

    /// - Parameter filter: substring match on `suite/case`, so a failing case can
    ///   be re-run alone without recompiling anything.
    public static func run(
        filter: String? = nil, emit: @Sendable (String) -> Void = { print($0) }
    ) async -> SelfTestReport {
        let started = Date()
        var report = SelfTestReport()
        var index = 0

        let selected = suites.map { suite in
            (suite, suite.cases.filter {
                filter == nil || "\(suite.name)/\($0.name)".localizedCaseInsensitiveContains(filter!)
            })
        }.filter { !$0.1.isEmpty }

        emit("TAP version 14")
        emit("1..\(selected.reduce(0) { $0 + $1.1.count })")

        for (suite, cases) in selected {
            emit("# \(suite.name)")
            for testCase in cases {
                index += 1
                let scope = Scope()
                var thrown: Error?
                do { try await testCase.body(scope) } catch { thrown = error }

                let bad = scope.expectations.filter { !$0.passed }
                if thrown == nil && bad.isEmpty {
                    report.passed += 1
                    emit("ok \(index) - \(suite.name)/\(testCase.name)")
                } else {
                    report.failed += 1
                    emit("not ok \(index) - \(suite.name)/\(testCase.name)")
                    emit("  ---")
                    if let thrown {
                        emit("  error: \(thrown)")
                        report.failures.append("\(suite.name)/\(testCase.name): \(thrown)")
                    }
                    for e in bad {
                        emit("  at: \(e.file):\(e.line)")
                        emit("  message: \(e.describe)")
                        report.failures.append(
                            "\(suite.name)/\(testCase.name) (\(e.file):\(e.line)): \(e.describe)")
                    }
                    emit("  ...")
                }
            }
        }
        report.duration = Date().timeIntervalSince(started)
        emit("# passed \(report.passed), failed \(report.failed), "
             + String(format: "%.2fs", report.duration))
        return report
    }
}
