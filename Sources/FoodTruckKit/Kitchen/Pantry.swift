import Foundation

/// The catalogue of recipes available on this machine.
///
/// Builtins are compiled in because they are what makes reading the pantry
/// possible at all. Everything else is a directory on disk containing
/// `recipe.json` and `Taskfile.yml`, which means adding a recipe is adding a
/// folder, and a bad recipe is a lint failure rather than a crash.
public enum Pantry {
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
                let recipe = try JSONDecoder().decode(
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
}
