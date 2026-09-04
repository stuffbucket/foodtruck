import Foundation
import FoodTruckKit

// FoodTruck is one binary with two faces.
//
// Double-clicked in Finder it is a Mac app; run from a terminal with arguments
// it is a CLI. One binary means one signature, one notarization, and -- the part
// that matters -- exactly one implementation of every behaviour, so the app can
// never drift from the command line the way a GUI wrapped around a separate
// tool always eventually does.

@main
enum Main {
    static func main() async {
        let argv = Array(CommandLine.arguments.dropFirst())
        L10n.shared.configure(locales: Locale.preferredLanguages)

        // Launch Services passes `-psn_...` when an app is opened from Finder.
        let fromFinder = argv.contains { $0.hasPrefix("-psn_") } || argv.isEmpty
        if fromFinder && isatty(STDIN_FILENO) == 0 {
            await GUI.run()
            return
        }
        exit(await CLI.run(argv))
    }
}

enum CLI {
    static func run(_ argv: [String]) async -> Int32 {
        let locations = Locations.resolved()
        var args = argv
        let command = args.isEmpty ? "audit" : args.removeFirst()

        switch command {
        case "audit", "status":
            return await inspect(locations, verb: .audit, json: args.contains("--json"))
        case "plan":
            return await inspect(locations, verb: .plan, json: args.contains("--json"))
        case "converge", "apply":
            return await converge(locations, dryRun: args.contains("--dry-run"),
                                  only: Set(args.filter { !$0.hasPrefix("-") }))
        case "where", "paths":
            for (label, url) in [("config", locations.config), ("data", locations.data),
                                 ("state", locations.state), ("cache", locations.cache),
                                 ("toolbox", locations.toolbox)] {
                print("\(label.padding(toLength: 8, withPad: " ", startingAt: 0)) \(url.path)")
            }
            return 0
        case "recipes", "list":
            let (recipes, _) = Pantry.load(locations)
            for r in recipes {
                print("\(r.id.padding(toLength: 28, withPad: " ", startingAt: 0)) "
                      + "\(r.engine.padding(toLength: 10, withPad: " ", startingAt: 0)) "
                      + "\(t(r.name))")
            }
            return 0
        case "lint":
            return await Lint.run(locations, args)
        case "selftest":
            // Ships in the product on purpose: when something misbehaves on a
            // machine we cannot reach, this is the same signed binary proving
            // -- or failing to prove -- itself in situ.
            let filter = args.first { !$0.hasPrefix("-") }
            let report = await SelfTest.run(filter: filter)
            return report.isClean ? 0 : 1
        case "help", "--help", "-h":
            print(usage)
            return 0
        case "version", "--version":
            print("foodtruck \(Build.version)")
            return 0
        default:
            FileHandle.standardError.write(Data(
                "foodtruck: unknown command '\(command)'\n\n\(usage)\n".utf8))
            return 64   // EX_USAGE
        }
    }

    static let usage = """
    foodtruck — keeps your Mac's development environment honest.

      audit [--json]        Report what has drifted. Changes nothing.
      plan  [--json]        Show what converge would do. Changes nothing.
      converge [--dry-run] [recipe...]
                            Make it so. Safe to run twice.
      recipes               List every recipe FoodTruck can run.
      where                 Show the four directories FoodTruck uses.
      lint pins             Re-derive every pinned digest from upstream.
      lint strings          Translation coverage for every shipped language.
      selftest [filter]     Prove this binary works, here, now. TAP output.
      version

    Everything FoodTruck writes lives under the XDG directories shown by
    `foodtruck where`. Set FOODTRUCK_ROOT to relocate all of them at once.
    """

    // MARK: - Commands

    static func inspect(_ locations: Locations, verb: Verb, json: Bool) async -> Int32 {
        let (recipes, faults) = Pantry.load(locations)
        let kitchen = Kitchen(locations: locations, recipes: recipes)
        let service = await kitchen.inspect(verb)
        if json { return emitJSON(service) }
        Render.service(service, faults: faults)
        return service.isClean ? 0 : 10
    }

    static func converge(_ locations: Locations, dryRun: Bool, only: Set<String>) async -> Int32 {
        let (recipes, faults) = Pantry.load(locations)
        let kitchen = Kitchen(locations: locations, recipes: recipes)
        do {
            let service = try await kitchen.converge(
                only: only.isEmpty ? nil : only, dryRun: dryRun)
            Render.service(service, faults: faults)
            return service.failed.isEmpty ? (service.isClean ? 0 : 10) : 1
        } catch {
            FileHandle.standardError.write(Data("\(error)\n".utf8))
            return 1
        }
    }

    static func emitJSON(_ service: Service) -> Int32 {
        let payload: [String: Any] = [
            "verb": service.verb.rawValue,
            "duration": service.duration,
            "clean": service.isClean,
            "recipes": service.results.map { r -> [String: Any] in
                ["id": r.recipe, "outcome": Render.outcomeToken(r.outcome),
                 "findings": r.report.findings.map {
                     ["id": $0.id, "severity": $0.severity.rawValue,
                      "message": t($0.title, $0.args),
                      "observed": $0.observed ?? "", "desired": $0.desired ?? ""]
                 }]
            },
        ]
        if let d = try? JSONSerialization.data(
            withJSONObject: payload, options: [.prettyPrinted, .sortedKeys]) {
            FileHandle.standardOutput.write(d)
            print("")
        }
        return service.isClean ? 0 : 10
    }
}

enum Build {
    static let version = Bundle.main
        .object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
}
