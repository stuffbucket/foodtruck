import Foundation
import CryptoKit

/// A recipe written in Swift instead of YAML.
///
/// These exist for exactly one reason: the root of the tech tree. A recipe that
/// installs the recipe runner cannot itself be run by the recipe runner. Keeping
/// that circularity in a named, tiny, closed set is better than pretending it
/// does not exist -- and better than re-implementing go-task in Swift, which
/// would be reinventing a wheel for no gain.
///
/// The rule: a builtin may only exist if it is a tech-tree root. Anything with
/// a parent is a Taskfile.
public protocol BuiltinRecipe: Sendable {
    var descriptor: Recipe { get }
    /// Read-only. Must not touch anything outside `context.locations`.
    func audit(_ context: RunContext) async -> RecipeReport
    /// The default carries only a report. Inventory overrides this to attach the
    /// exact scan the GUI may record after presenting the read-only result.
    func auditCapture(_ context: RunContext) async -> BuiltinAudit
    /// Idempotent. Called only when audit reported drift, but must still be
    /// safe if it is not.
    func converge(_ context: RunContext) async -> Result<RecipeReport, RecipeFault>
}


public struct BuiltinAudit: Sendable {
    var report: RecipeReport
    var inventory: Inventory?

    init(report: RecipeReport, inventory: Inventory? = nil) {
        self.report = report
        self.inventory = inventory
    }
}

extension BuiltinRecipe {
    func auditCapture(_ context: RunContext) async -> BuiltinAudit {
        BuiltinAudit(report: await audit(context))
    }
}

public struct BuiltinEngine: RecipeEngine {
    public let id = "builtin"
    private let recipes: [String: BuiltinRecipe]

    public init(_ recipes: [BuiltinRecipe] = BuiltinEngine.standard) {
        self.recipes = Dictionary(uniqueKeysWithValues: recipes.map { ($0.descriptor.id, $0) })
    }

    public static var standard: [BuiltinRecipe] {
        [WorkspaceRecipe(), SettingsRecipe(), CookbookRecipe(), ToolboxRecipe(), InventoryRecipe()]
    }
    public var descriptors: [Recipe] { recipes.values.map(\.descriptor).sorted { $0.id < $1.id } }

    public func availability(_ context: RunContext) async -> EngineAvailability { .ready }

    public func run(_ verb: Verb, recipe: Recipe, context: RunContext) async -> VerbResult {
        let started = Date()
        if recipe.id == "env.inventory", context.profile == nil {
            return VerbResult(recipe: recipe.id, verb: verb, outcome: .failed(
                RecipeFault(
                    kind: .settingsUnavailable, recipe: recipe.id, verb: verb,
                    args: ["path": context.locations.settings.path],
                    detail: "env.inventory requires a resolved settings profile")))
        }
        guard let impl = recipes[recipe.id] else {
            return VerbResult(recipe: recipe.id, verb: verb, outcome: .failed(
                RecipeFault(kind: .recipeMissing, recipe: recipe.id, verb: verb)))
        }
        func done(_ o: VerbOutcome, _ capture: BuiltinAudit) -> VerbResult {
            VerbResult(recipe: recipe.id, verb: verb, outcome: o,
                       report: capture.report,
                       duration: Date().timeIntervalSince(started),
                       inventory: capture.inventory)
        }
        func done(_ o: VerbOutcome, _ report: RecipeReport) -> VerbResult {
            done(o, BuiltinAudit(report: report))
        }

        switch verb {
        case .detect:
            return done(.converged, await impl.audit(context))

        case .audit:
            let capture = await impl.auditCapture(context)
            return done(capture.report.requiresAction ? .drift : .converged, capture)

        case .verify:
            let report = await impl.audit(context)
            return done(report.requiresAction ? .drift : .converged, report)

        case .plan:
            // A builtin's plan is its audit: each finding is one step, already
            // phrased as the difference it would close.
            return done(.converged, await impl.audit(context))

        case .converge:
            if context.dryRun {
                // A dry run must report the drift it declined to fix. Claiming
                // "converged" here would make --dry-run a liar, and a preview
                // you cannot trust is worse than no preview.
                let report = await impl.audit(context)
                return done(report.requiresAction ? .drift : .converged, report)
            }
            switch await impl.converge(context) {
            case .success(let r): return done(r.requiresAction ? .drift : .converged, r)
            case .failure(let f): return done(.failed(f), RecipeReport())
            }

        case .rollback:
            return done(.failed(RecipeFault(
                kind: .verbUnsupported, recipe: recipe.id, verb: verb,
                args: ["recipe": recipe.id, "verb": verb.rawValue])), RecipeReport())
        }
    }
}

// MARK: - Root 1: the workspace itself

/// Ensures FoodTruck's own four directories exist and are writable.
///
/// The most boring recipe in the system, and the one that proves the model: it
/// has an audit that never lies, a converge that is trivially idempotent, and a
/// blast radius of exactly FoodTruck's own folder. If this one is not clean,
/// nothing else can be trusted, so it is the root of everything.
struct WorkspaceRecipe: BuiltinRecipe {
    var descriptor: Recipe {
        Recipe(
            id: "core.locations",
            name: "recipe.core.locations.name",
            summary: "recipe.core.locations.summary",
            engine: "builtin",
            provides: ["workspace"],
            verbs: [.detect, .audit, .plan, .converge, .verify],
            blast: .contained,
            scope: .housekeeping,
            timeout: 10,
            symbol: "folder.badge.gearshape"
        )
    }

    func audit(_ context: RunContext) async -> RecipeReport {
        var report = RecipeReport()
        let fm = FileManager.default
        for url in context.locations.all + [context.locations.toolbox] {
            var isDir: ObjCBool = false
            let name = url.lastPathComponent
            report.facts[name] = url.path

            if !fm.fileExists(atPath: url.path, isDirectory: &isDir) {
                report.findings.append(Finding(
                    id: "dir.missing:\(name)", severity: .drift,
                    title: "finding.dir.missing", args: ["path": url.path],
                    observed: "absent", desired: "present"))
                report.checks.append(Check(id: "dir:\(name)", label: url.path, passed: false))
            } else if !fm.isWritableFile(atPath: url.path) || !isDir.boolValue {
                report.findings.append(Finding(
                    id: "dir.unwritable:\(name)", severity: .risk,
                    title: "finding.dir.unwritable", args: ["path": url.path],
                    observed: "unwritable", desired: "writable",
                    fixable: false, remedy: "fault.readOnlyViolation.remedy"))
                report.checks.append(Check(id: "dir:\(name)", label: url.path, passed: false))
            } else {
                report.checks.append(Check(id: "dir:\(name)", label: url.path, passed: true))
            }
        }
        return report
    }

    func converge(_ context: RunContext) async -> Result<RecipeReport, RecipeFault> {
        for url in context.locations.all + [context.locations.toolbox] {
            do {
                try FileManager.default.createDirectory(
                    at: url, withIntermediateDirectories: true,
                    attributes: [.posixPermissions: 0o700])
            } catch {
                return .failure(RecipeFault(
                    kind: .unexpectedExit, recipe: descriptor.id, verb: .converge,
                    args: ["recipe": descriptor.id, "verb": "converge"],
                    detail: "\(url.path): \(error.localizedDescription)"))
            }
        }
        return .success(await audit(context))
    }
}
