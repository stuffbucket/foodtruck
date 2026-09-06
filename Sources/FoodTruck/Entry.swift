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
            return await inspect(locations, verb: .audit, json: args.contains("--json"),
                                 all: args.contains("--all"))
        case "plan":
            return await inspect(locations, verb: .plan, json: args.contains("--json"),
                                 all: args.contains("--all"))
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
            let (recipes, _) = Cookbook.load(locations)
            for r in recipes {
                print("\(r.id.padding(toLength: 28, withPad: " ", startingAt: 0)) "
                      + "\(r.engine.padding(toLength: 10, withPad: " ", startingAt: 0)) "
                      + "\(t(r.name))")
            }
            return 0
        case "inventory":
            return await inventory(locations, args)
        case "lint":
            return await Lint.run(locations, args)
        case "selftest":
            // Ships in the product on purpose: when something misbehaves on a
            // machine we cannot reach, this is the same signed binary proving
            // -- or failing to prove -- itself in situ.
            // Order is randomised by default and the seed is printed, so a
            // failure that only shows up in one order can be reproduced.
            let seedIndex = args.firstIndex(of: "--seed").map { $0 + 1 }
            let seed = seedIndex.flatMap { $0 < args.count ? UInt64(args[$0]) : nil }
            // The seed's value is not a filter. `selftest --seed 12345` used to
            // run every case whose name contained "12345", which is none.
            let filter = args.enumerated()
                .first { index, arg in !arg.hasPrefix("-") && index != seedIndex }?.element
            let report = await SelfTest.run(
                filter: filter, seed: seed, shuffle: !args.contains("--in-order"))
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

      audit [--json] [--all]
                            Report what has drifted. Changes nothing.
                            --all also shows FoodTruck's own housekeeping.
      plan  [--json]        Show what converge would do. Changes nothing.
      converge [--dry-run] [recipe...]
                            Make it so. Safe to run twice.
      inventory [--all] [--duplicates] [--history]
                            What is installed on this Mac and where it came
                            from. --history needs `converge` to have run.
      recipes               List every recipe FoodTruck can run.
      where                 Show the four directories FoodTruck uses.
      lint pins             Re-derive every pinned digest from upstream.
      lint strings          Translation coverage for every shipped language.
      selftest [filter] [--seed N] [--in-order]
                            Prove this binary works, here, now. TAP output.
                            Case order is random; the seed is printed so a
                            failure can be replayed with --seed.
      version

    Everything FoodTruck writes lives under the XDG directories shown by
    `foodtruck where`. Set FOODTRUCK_ROOT to relocate all of them at once.
    """

    // MARK: - Commands

    static func inspect(
        _ locations: Locations, verb: Verb, json: Bool, all: Bool
    ) async -> Int32 {
        let (recipes, faults) = Cookbook.load(locations)
        let kitchen = Kitchen(locations: locations, recipes: recipes)
        var service = await kitchen.inspect(verb)
        // Same rule as the window: FoodTruck's own housekeeping is not news.
        // `--all` is for us, and for anyone debugging FoodTruck itself.
        // Housekeeping is hidden, but it must never be hidden *dishonestly*.
        // On a machine where FoodTruck has not set itself up, there are no
        // environment recipes to report, and silently answering "everything is
        // fine" would be the worst possible lie -- confidently wrong about a
        // machine we have not looked at. The window settles itself on launch;
        // `audit` cannot, because it promises to change nothing. So it says so.
        let chores = recipes.filter { $0.scope == .housekeeping }.map(\.id)
        let unsettled = service.results.contains {
            chores.contains($0.recipe) && $0.outcome != .converged
        }
        if !all {
            let visible = Set(recipes.filter { $0.scope == .environment }.map(\.id))
            service.results = service.results.filter { visible.contains($0.recipe) }
        }
        if unsettled && !all {
            if json { return emitJSON(service, setupNeeded: true) }
            Render.setupNeeded()
            Render.service(service, faults: faults)
            return 10
        }
        if json { return emitJSON(service) }
        Render.service(service, faults: faults)
        return service.isClean ? 0 : 10
    }

    /// The inventory, for reading rather than for judging.
    ///
    /// `audit` says whether the machine has changed; this says what is on it.
    /// Splitting them keeps the audit summary short enough to read while still
    /// giving the notices somewhere to point -- "some command names are
    /// installed twice" is only useful if you can then ask which.
    static func inventory(_ locations: Locations, _ args: [String]) async -> Int32 {
        let environment = Exec.baseEnvironment(locations)
        let store = InventoryStore(root: locations.inventory)

        if args.contains("--history") {
            let entries = await store.history(limit: 20, environment: environment)
            if entries.isEmpty {
                print(Render.paint("No history yet. `foodtruck converge` records the first one.", "90"))
                return 0
            }
            for entry in entries { print(entry) }
            return 0
        }

        // Probes as well as scans, so this shows the same versions the audit
        // records rather than a weaker view of the same machine.
        let home = URL(filePath: environment["HOME"] ?? NSHomeDirectory())
        let current = await Inventory
            .scan(home: home, locations: locations)
            .probingVersions(home: home, environment: environment)

        if args.contains("--duplicates") {
            let groups = current.duplicated.sorted { $0.key < $1.key }
            if groups.isEmpty {
                print(Render.paint("No command name is installed more than once.", "90"))
                return 0
            }
            for (name, copies) in groups {
                print(Render.paint(name, "1"))
                for copy in copies.sorted(by: { $0.path < $1.path }) {
                    let origin = copy.origin.rawValue
                        .padding(toLength: 10, withPad: " ", startingAt: 0)
                    print("  \(Render.paint(origin, "90")) \(copy.path)")
                }
            }
            return 0
        }

        if args.contains("--all") {
            print(current.text, terminator: "")
            return 0
        }

        print(Render.paint(current.host.describe, "1")
              + "  \(current.host.arch)  kernel \(current.host.kernel)")
        print(Render.paint(
            "command line tools: " + (current.host.commandLineTools ?? "not installed"), "90"))
        print("")

        for (origin, count) in current.countsByOrigin.sorted(by: { $0.value > $1.value }) {
            let name = origin.rawValue.padding(toLength: 12, withPad: " ", startingAt: 0)
            let bar = String(repeating: " ", count: max(0, 6 - String(count).count))
            print("  \(name)\(bar)\(count)")
        }

        if !current.managers.isEmpty {
            print("")
            print(Render.paint("Environment managers", "1"))
            for manager in current.managers {
                let id = manager.id.padding(toLength: 10, withPad: " ", startingAt: 0)
                let version = manager.version
                    ?? (manager.shellFunction ? "shell function" : "unknown")
                print("  \(id) \(version.padding(toLength: 16, withPad: " ", startingAt: 0))"
                      + Render.paint(manager.evidence, "90"))
            }
            let contested = current.contested
            if !contested.isEmpty {
                print("")
                print(Render.paint("Contested — more than one of these wants the same runtime", "33"))
                for (runtime, managers) in contested.sorted(by: { $0.key < $1.key }) {
                    let name = runtime.padding(toLength: 10, withPad: " ", startingAt: 0)
                    print("  ! \(name) \(managers.joined(separator: ", "))")
                }
            }
        }

        let conflicting = current.conflictingVersions
        if !conflicting.isEmpty {
            print("")
            print(Render.paint("Installed twice at different versions", "33"))
            for (name, copies) in conflicting.sorted(by: { $0.key < $1.key }) {
                print("  ! \(Render.paint(name, "1"))")
                for copy in copies {
                    let version = (copy.version ?? "unknown")
                        .padding(toLength: 14, withPad: " ", startingAt: 0)
                    print("      \(version) \(Render.paint(copy.path, "90"))")
                }
            }
        }

        let shadowed = current.shadowedShims
        if !shadowed.isEmpty {
            print("")
            print(Render.paint("Shimmed and installed — PATH order decides which runs", "33"))
            for (name, copies) in shadowed.sorted(by: { $0.key < $1.key }) {
                print("  ! \(Render.paint(name, "1"))")
                for copy in copies {
                    let label = copy.shim
                        ? "\(copy.origin.rawValue) shim"
                        : (copy.version ?? "unknown")
                    print("      \(label.padding(toLength: 14, withPad: " ", startingAt: 0))"
                          + Render.paint(copy.path, "90"))
                }
            }
        }

        let unmanaged = current.unmanaged
        if !unmanaged.isEmpty {
            print("")
            print(Render.paint("Unmanaged — nothing on this Mac accounts for these", "33"))
            for tool in unmanaged {
                let name = tool.name.padding(toLength: 20, withPad: " ", startingAt: 0)
                print("  · \(name) \(Render.paint(tool.path, "90"))")
            }
        }

        // Says its own scope, for the same reason the audit summary does: a
        // list of what was found means nothing without where it was looked for.
        print("")
        print(Render.paint(
            "\(current.tools.count) programs across \(current.roots.count) directories. "
            + "Anywhere not listed by `--all` was not searched.", "90"))
        if store.load() == nil {
            print(Render.paint(
                "Not recorded yet — `foodtruck converge` starts the history.", "90"))
        }
        return 0
    }

    static func converge(_ locations: Locations, dryRun: Bool, only: Set<String>) async -> Int32 {
        let (recipes, faults) = Cookbook.load(locations)
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

    static func emitJSON(_ service: Service, setupNeeded: Bool = false) -> Int32 {
        let payload: [String: Any] = [
            "verb": service.verb.rawValue,
            "duration": service.duration,
            "clean": service.isClean && !setupNeeded,
            "setupNeeded": setupNeeded,
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
        return (service.isClean && !setupNeeded) ? 0 : 10
    }
}

enum Build {
    static let version = Bundle.main
        .object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
}
