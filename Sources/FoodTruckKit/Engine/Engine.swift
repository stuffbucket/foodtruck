import Foundation

/// Everything a verb needs to run, in one value so engines stay stateless.
public struct RunContext: Sendable {
    public var locations: Locations
    public var environment: [String: String]
    /// True for `plan` and for a converge the user asked to preview. An engine
    /// that cannot honour this must refuse rather than mutate.
    public var dryRun: Bool
    /// Desired-state variables from the active profile, handed to the recipe.
    public var vars: [String: String]
    /// The most damage any recipe is permitted to do in this run.
    ///
    /// This exists because one thing turned out not to be sandboxable at all:
    /// `HOMEBREW_PREFIX` is silently ignored -- `HOMEBREW_PREFIX=/tmp/x brew
    /// --prefix` still answers `/opt/homebrew`, measured on brew 6.0.21 -- so a
    /// `brew bundle` writes to the real machine no matter what the environment
    /// says. Since it cannot be contained, it is gated instead: the self-test
    /// runs at `.contained` and a recipe that would reach further is reported
    /// `blocked` rather than being trusted not to.
    public var blastCeiling: Blast

    public init(
        locations: Locations,
        environment: [String: String],
        dryRun: Bool = false,
        vars: [String: String] = [:],
        blastCeiling: Blast = .privileged
    ) {
        self.locations = locations
        self.environment = environment
        self.dryRun = dryRun
        self.vars = vars
        self.blastCeiling = blastCeiling
    }
}

public struct VerbResult: Sendable {
    public var recipe: String
    public var verb: Verb
    public var outcome: VerbOutcome
    public var report: RecipeReport
    public var duration: Double
    /// Raw combined output, for the diagnostics affordance only.
    public var log: String

    public init(
        recipe: String, verb: Verb, outcome: VerbOutcome,
        report: RecipeReport = RecipeReport(), duration: Double = 0, log: String = ""
    ) {
        self.recipe = recipe; self.verb = verb; self.outcome = outcome
        self.report = report; self.duration = duration; self.log = log
    }
}

/// Why an engine cannot run right now, if it cannot.
public enum EngineAvailability: Sendable, Equatable {
    case ready
    /// Names the recipe that would unlock it, so the UI can offer one button
    /// instead of an error. This is how the tech tree stays walkable.
    case needsRecipe(String)
}

/// The pluggable back end that actually executes verbs.
///
/// There are two implementations and they exist for different reasons.
/// `BuiltinEngine` is Swift and runs the handful of tech-tree roots that must
/// work on a machine with nothing installed. `TaskfileEngine` shells to
/// `go-task` and runs everything else. Keeping this a protocol means a future
/// engine -- a signed WASM module, a remote runner -- is an addition, not a
/// rewrite. FoodTruck's core never learns what a package manager is.
public protocol RecipeEngine: Sendable {
    var id: String { get }
    func availability(_ context: RunContext) async -> EngineAvailability
    func run(_ verb: Verb, recipe: Recipe, context: RunContext) async -> VerbResult
}

/// Shared decoding of a recipe's stdout, used by every engine so the contract
/// is defined in exactly one place.
enum ReportDecoder {
    /// Recipes print a JSON object on stdout. Anything before it (a shell
    /// `set -x` trace, a progress line) is tolerated: we take the last balanced
    /// top-level object. Being lenient here is deliberate -- a recipe author
    /// forgetting `>&2` should not become an incident.
    static func decode(
        stdout: String, recipe: String, verb: Verb
    ) -> Result<RecipeReport, RecipeFault> {
        let trimmed = stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return .success(RecipeReport()) }
        guard let start = trimmed.lastIndex(where: { $0 == "{" }).flatMap({ _ in trimmed.firstIndex(of: "{") }),
              let data = String(trimmed[start...]).data(using: .utf8)
        else {
            return .success(RecipeReport())   // no JSON at all: not an error
        }
        do {
            return .success(try JSONDecoder().decode(RecipeReport.self, from: data))
        } catch {
            return .failure(RecipeFault(
                kind: .malformedReport, recipe: recipe, verb: verb,
                args: ["reason": "\(error)"], detail: stdout
            ))
        }
    }

    /// Map a process exit code onto the verdict. The one place exit codes are
    /// interpreted.
    static func outcome(
        _ result: ExecResult, recipe: String, verb: Verb
    ) -> VerbOutcome {
        if result.timedOut {
            return .failed(RecipeFault(
                kind: .timedOut, recipe: recipe, verb: verb, detail: result.stderr))
        }
        switch result.status {
        case VerbOutcome.convergedCode: return .converged
        case VerbOutcome.driftCode:     return .drift
        case VerbOutcome.blockedCode:   return .blocked
        default:
            return .failed(RecipeFault(
                kind: .unexpectedExit, recipe: recipe, verb: verb,
                args: ["code": String(result.status)],
                detail: [result.stderr, result.stdout]
                    .filter { !$0.isEmpty }.joined(separator: "\n")
            ))
        }
    }
}
