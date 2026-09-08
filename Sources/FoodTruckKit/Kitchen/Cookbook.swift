import Foundation
import CryptoKit

/// The catalogue of recipes available on this machine.
///
/// Builtins are compiled in because they are what makes reading the pantry
/// possible at all. Everything else is a directory on disk containing
/// `recipe.json` and `Taskfile.yml`, which means adding a recipe is adding a
/// folder, and a bad recipe is a lint failure rather than a crash.
public enum Cookbook {
    public static func load(_ locations: Locations) -> (recipes: [Recipe], faults: [RecipeFault]) {
        var recipes = BuiltinEngine().descriptors
        var faults: [RecipeFault] = []

        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: locations.recipes, includingPropertiesForKeys: [.isDirectoryKey])
        else { return (recipes, faults) }

        for dir in entries.sorted(by: { $0.path < $1.path }) {
            let manifest = dir.appending(path: "recipe.json")
            guard fm.fileExists(atPath: manifest.path) else { continue }
            do {
                var recipe = try JSONDecoder().decode(
                    Recipe.self, from: Data(contentsOf: manifest))
                // The directory name is the identity. A manifest that disagrees
                // is a rename that went half-done, and silently trusting either
                // one would produce a recipe that cannot be found again.
                guard recipe.id == dir.lastPathComponent else {
                    faults.append(RecipeFault(
                        kind: .recipeMalformed, recipe: dir.lastPathComponent, verb: .audit,
                        args: ["recipe": dir.lastPathComponent],
                        detail: "manifest declares id '\(recipe.id)'"))
                    continue
                }
                // Derived here, never read from the file: a recipe must not be
                // able to declare itself unmodified. Surfaced as a quiet badge
                // on the recipe itself, because "you edited this" is a fact
                // about *this* recipe -- it has no business being a task
                // somewhere else with a Fix button on it.
                recipe.customised = Self.differsFromShipped(dir, locations)
                recipes.append(recipe)
            } catch {
                faults.append(RecipeFault(
                    kind: .recipeMalformed, recipe: dir.lastPathComponent, verb: .audit,
                    args: ["recipe": dir.lastPathComponent],
                    detail: error.localizedDescription))
            }
        }
        return (recipes, faults)
    }

    static func digest(_ dir: URL) -> String {
        var hasher = SHA256()
        for name in ["recipe.json", "Taskfile.yml"] {
            if let d = try? Data(contentsOf: dir.appending(path: name)) { hasher.update(data: d) }
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func differsFromShipped(_ installed: URL, _ locations: Locations) -> Bool {
        guard let seed = locations.seed else { return false }
        let shipped = seed.appending(path: installed.lastPathComponent)
        guard FileManager.default.fileExists(
            atPath: shipped.appending(path: "recipe.json").path) else {
            return false   // not one of ours; nothing to differ from
        }
        return digest(shipped) != digest(installed)
    }
}
