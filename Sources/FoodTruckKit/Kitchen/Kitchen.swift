import Foundation

/// One complete pass over the machine.
public struct Service: Sendable {
    public var verb: Verb
    public var results: [VerbResult]
    public var started: Date
    public var duration: Double

    public var drifted: [VerbResult] { results.filter { $0.outcome == .drift } }
    public var failed: [VerbResult] {
        results.filter { if case .failed = $0.outcome { return true }; return false }
    }
    public var blocked: [VerbResult] { results.filter { $0.outcome == .blocked } }
    public var isClean: Bool { drifted.isEmpty && failed.isEmpty && blocked.isEmpty }
}

public enum KitchenError: Error, Sendable {
    /// `requires` forms a cycle. Named so the user can see which recipes.
    case dependencyCycle([String])
    /// A recipe names a `requires` that no recipe provides.
    case unknownDependency(recipe: String, missing: String)
}

/// The orchestrator. Owns the dependency graph, the parallelism policy, and
/// nothing else -- in particular it owns no knowledge of any tool.
public struct Kitchen: Sendable {
    public var locations: Locations
    public var recipes: [Recipe]
    /// The most damage any recipe in this kitchen may do. Read-only verbs are
    /// unaffected -- auditing a recipe you would not run is the normal case and
    /// is how the UI shows you what converging *would* cost.
    public var blastCeiling: Blast
    private let engines: [String: any RecipeEngine]
    /// The environment recipes are handed. Nil builds the usual one from
    /// `Locations`; a caller supplies its own to seal a run off from the host,
    /// which is what the self-test does so that auditing never reads -- or
    /// runs -- anything on the machine running the tests.
    private let environment: [String: String]?

    public init(
        locations: Locations,
        recipes: [Recipe],
        engines: [any RecipeEngine] = [BuiltinEngine(), TaskfileEngine()],
        blastCeiling: Blast = .privileged,
        environment: [String: String]? = nil
    ) {
        self.locations = locations
        self.recipes = recipes
        self.blastCeiling = blastCeiling
        self.engines = Dictionary(uniqueKeysWithValues: engines.map { ($0.id, $0) })
        self.environment = environment
    }

    /// Recipes grouped into waves: everything in wave *n* depends only on
    /// recipes in waves `< n`, so a wave can run fully in parallel.
    ///
    /// This is the whole parallelism policy. Nothing is serialised unless a
    /// declared `requires` edge forces it -- a recipe author gets concurrency by
    /// not lying about dependencies, and can never get it by accident.
    public func waves() throws -> [[Recipe]] {
        let byID = Dictionary(uniqueKeysWithValues: recipes.map { ($0.id, $0) })
        for r in recipes {
            for need in r.requires where byID[need] == nil {
                throw KitchenError.unknownDependency(recipe: r.id, missing: need)
            }
        }
        var remaining = recipes
        var placed = Set<String>()
        var out: [[Recipe]] = []
        while !remaining.isEmpty {
            let ready = remaining.filter { $0.requires.allSatisfy(placed.contains) }
            guard !ready.isEmpty else {
                throw KitchenError.dependencyCycle(remaining.map(\.id).sorted())
            }
            out.append(ready.sorted { $0.id < $1.id })
            placed.formUnion(ready.map(\.id))
            remaining.removeAll { placed.contains($0.id) }
        }
        return out
    }

    private func context(dryRun: Bool, vars: [String: String]) -> RunContext {
        RunContext(
            locations: locations,
            environment: environment ?? Exec.baseEnvironment(locations),
            dryRun: dryRun, vars: vars, blastCeiling: blastCeiling)
    }

    /// Read-only verbs ignore the dependency graph entirely and run every recipe
    /// at once. Audit does not change anything, so ordering buys nothing and
    /// costs the user the difference between one second and thirty.
    public func inspect(
        _ verb: Verb = .audit, vars: [String: String] = [:]
    ) async -> Service {
        precondition(verb.isReadOnly, "inspect() is for read-only verbs")
        let started = Date()
        let ctx = context(dryRun: true, vars: vars)
        let results = await withTaskGroup(of: VerbResult.self) { group in
            for recipe in recipes {
                group.addTask { await self.one(verb, recipe, ctx) }
            }
            var acc: [VerbResult] = []
            for await r in group { acc.append(r) }
            return acc.sorted { $0.recipe < $1.recipe }
        }
        return Service(verb: verb, results: results, started: started,
                       duration: Date().timeIntervalSince(started))
    }

    /// Converge wave by wave. A recipe whose dependency did not reach
    /// `converged` is reported `blocked` and never attempted -- that is how a
    /// half-unlocked tech tree stays legible instead of producing a cascade of
    /// confusing failures.
    public func converge(
        only ids: Set<String>? = nil, dryRun: Bool = false, vars: [String: String] = [:]
    ) async throws -> Service {
        let started = Date()
        let ctx = context(dryRun: dryRun, vars: vars)
        var satisfied = Set<String>()
        var results: [VerbResult] = []

        for wave in try waves() {
            let runnable = wave.filter { ids == nil || ids!.contains($0.id) || !$0.requires.isEmpty }
            var batch: [Recipe] = []
            for recipe in runnable {
                let unmet = recipe.requires.filter { !satisfied.contains($0) }
                if unmet.isEmpty {
                    batch.append(recipe)
                } else {
                    results.append(VerbResult(
                        recipe: recipe.id, verb: .converge, outcome: .blocked,
                        report: RecipeReport(findings: [Finding(
                            id: "\(recipe.id).blocked", severity: .notice,
                            title: "fault.engineUnavailable.title",
                            args: ["recipe": recipe.id, "engine": unmet.joined(separator: ", "),
                                   "unlock": unmet.first ?? ""],
                            fixable: false, remedy: "fault.engineUnavailable.remedy")])))
                }
            }
            let waveResults = await withTaskGroup(of: VerbResult.self) { group in
                for recipe in batch where ids == nil || ids!.contains(recipe.id) {
                    group.addTask { await self.one(.converge, recipe, ctx) }
                }
                var acc: [VerbResult] = []
                for await r in group { acc.append(r) }
                return acc
            }
            // A recipe excluded from `only` still counts as satisfied if it is
            // already converged, so a targeted run does not falsely block.
            for recipe in batch where !(ids == nil || ids!.contains(recipe.id)) {
                let check = await one(.audit, recipe, ctx)
                if check.outcome == .converged { satisfied.insert(recipe.id) }
            }
            for r in waveResults where r.outcome == .converged { satisfied.insert(r.recipe) }
            results += waveResults
        }
        return Service(verb: .converge, results: results.sorted { $0.recipe < $1.recipe },
                       started: started, duration: Date().timeIntervalSince(started))
    }

    private func one(_ verb: Verb, _ recipe: Recipe, _ ctx: RunContext) async -> VerbResult {
        // Checked here rather than inside an engine, so no engine -- including
        // one written later, or by someone else -- can opt out of it.
        if !verb.isReadOnly && !ctx.dryRun && recipe.blast > ctx.blastCeiling {
            return VerbResult(recipe: recipe.id, verb: verb, outcome: .blocked,
                report: RecipeReport(findings: [Finding(
                    id: "\(recipe.id).blast", severity: .notice,
                    title: "finding.blast.refused",
                    args: ["recipe": recipe.id,
                           "blast": t("blast.\(recipe.blast.rawValue)"),
                           "ceiling": t("blast.\(ctx.blastCeiling.rawValue)")],
                    fixable: false, remedy: "finding.blast.refused.remedy")]))
        }
        guard let engine = engines[recipe.engine] else {
            return VerbResult(recipe: recipe.id, verb: verb, outcome: .failed(
                RecipeFault(kind: .engineUnavailable, recipe: recipe.id, verb: verb,
                            args: ["recipe": recipe.id, "engine": recipe.engine,
                                   "unlock": TaskfileEngine.unlockRecipe])))
        }
        if case .needsRecipe(let unlock) = await engine.availability(ctx) {
            return VerbResult(recipe: recipe.id, verb: verb, outcome: .blocked,
                report: RecipeReport(findings: [Finding(
                    id: "\(recipe.id).engine", severity: .notice,
                    title: "fault.engineUnavailable.title",
                    args: ["recipe": recipe.id, "engine": recipe.engine, "unlock": unlock],
                    fixable: false, remedy: "fault.engineUnavailable.remedy")]))
        }
        return await engine.run(verb, recipe: recipe, context: ctx)
    }
}
