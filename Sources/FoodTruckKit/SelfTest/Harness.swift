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

/// A seedable generator, so a shuffled run can be replayed exactly.
///
/// `SystemRandomNumberGenerator` cannot be seeded, and an unreproducible random
/// order is worse than no random order: it turns a real order dependency into
/// a failure nobody can make happen again. SplitMix64 is twelve lines and is
/// the reference seeder for exactly this job.
struct SplitMix64: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

public enum SelfTest {
    public static var suites: [Suite] {
        [LocationSuite.suite, GraphSuite.suite, ReportSuite.suite, EvidenceSuite.suite,
         ReadOnlySuite.suite, ConvergeSuite.suite, InventorySuite.suite, IntlSuite.suite]
    }

    /// - Parameters:
    ///   - filter: substring match on `suite/case`, so a failing case can be
    ///     re-run alone without recompiling anything.
    ///   - seed: replays a specific order. Nil picks a fresh one.
    ///   - shuffle: false runs in declaration order.
    ///
    /// Shuffling is the default, and deliberately so. These cases share real
    /// global state -- `L10n.shared` is a singleton every case reads and some
    /// cases reconfigure -- and a fixed order lets a case that depends on what
    /// ran before it pass forever. The seed is printed on every run, so a
    /// failure that only happens in one order is still reproducible: the
    /// alternative, an unseeded shuffle, would trade a hidden bug for an
    /// unrepeatable one.
    public static func run(
        filter: String? = nil, seed: UInt64? = nil, shuffle: Bool = true,
        emit: @Sendable (String) -> Void = { print($0) }
    ) async -> SelfTestReport {
        let started = Date()
        var report = SelfTestReport()
        var index = 0

        var selected = suites.map { suite in
            (suite, suite.cases.filter {
                filter == nil || "\(suite.name)/\($0.name)".localizedCaseInsensitiveContains(filter!)
            })
        }.filter { !$0.1.isEmpty }

        let chosenSeed = seed ?? UInt64.random(in: UInt64.min...UInt64.max)
        if shuffle {
            var rng = SplitMix64(seed: chosenSeed)
            // Both levels. Shuffling only the suites would leave every case
            // still sitting behind the same neighbour inside its own suite,
            // which is where the sharing actually happens.
            selected = selected.map { ($0.0, $0.1.shuffled(using: &rng)) }
                .shuffled(using: &rng)
        }

        emit("TAP version 14")
        emit("1..\(selected.reduce(0) { $0 + $1.1.count })")
        if shuffle {
            emit("# order random, seed \(chosenSeed)")
            emit("# replay: foodtruck selftest --seed \(chosenSeed)")
        } else {
            emit("# order declaration")
        }

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
