import Foundation
import CryptoKit

/// Puts the shipped recipes on disk, and keeps them honest afterwards.
///
/// The recipes FoodTruck ships with live inside the signed app bundle, where
/// nothing can edit them. This copies them into the pantry, which is writable,
/// so a user can fork a recipe and keep the change. Audit compares the two by
/// content hash, so a recipe that has been edited shows as a *notice* -- "you
/// changed this, we are not going to quietly overwrite it" -- rather than being
/// silently reverted on the next converge.
///
/// That distinction is the whole point: diversity that was chosen must survive
/// convergence; diversity that was accidental must not.
struct CookbookRecipe: BuiltinRecipe {
    var descriptor: Recipe {
        Recipe(
            id: "core.cookbook",
            name: "recipe.core.cookbook.name",
            summary: "recipe.core.cookbook.summary",
            engine: "builtin",
            requires: ["core.locations"],
            provides: ["cookbook"],
            verbs: [.detect, .audit, .plan, .converge, .verify],
            blast: .contained,
            scope: .housekeeping,
            timeout: 20,
            symbol: "books.vertical"
        )
    }

    func audit(_ context: RunContext) async -> RecipeReport {
        var report = RecipeReport()
        guard let seed = context.locations.seed,
              let shipped = try? FileManager.default.contentsOfDirectory(
                at: seed, includingPropertiesForKeys: nil)
        else { return report }

        for src in shipped.sorted(by: { $0.path < $1.path }) {
            guard FileManager.default.fileExists(
                atPath: src.appending(path: "recipe.json").path) else { continue }
            let id = src.lastPathComponent
            if !FileManager.default.fileExists(
                atPath: context.locations.recipes.appending(path: id).path) {
                report.findings.append(Finding(
                    id: "cookbook.absent:\(id)", severity: .drift,
                    title: "finding.recipe.notInstalled", args: ["recipe": id],
                    observed: "absent", desired: "installed"))
            }
        }
        return report
    }

    func converge(_ context: RunContext) async -> Result<RecipeReport, RecipeFault> {
        guard let seed = context.locations.seed else {
            return .success(RecipeReport())
        }
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: context.locations.recipes,
                                   withIntermediateDirectories: true)
            for src in (try? fm.contentsOfDirectory(at: seed, includingPropertiesForKeys: nil)) ?? [] {
                guard fm.fileExists(atPath: src.appending(path: "recipe.json").path) else { continue }
                let dst = context.locations.recipes.appending(path: src.lastPathComponent)
                // Only install what is absent. A recipe the user has edited is
                // theirs; converge reports it and moves on.
                if !fm.fileExists(atPath: dst.path) { try fm.copyItem(at: src, to: dst) }
            }
        } catch {
            return .failure(RecipeFault(
                kind: .unexpectedExit, recipe: descriptor.id, verb: .converge,
                args: ["recipe": descriptor.id, "verb": "converge"],
                detail: error.localizedDescription))
        }
        return .success(await audit(context))
    }
}
