import Foundation

/// A disposable world. Every test that touches disk gets one.
///
/// `Locations(root:)` is the only door in, so a test cannot accidentally take a
/// second path to the real home directory. That matters more on macOS than it
/// sounds: `NSHomeDirectory()`, `FileManager.homeDirectoryForCurrentUser` and
/// `~` expansion all resolve through `getpwuid(getuid())` and **ignore `$HOME`**
/// -- measured on macOS 26.6. A test that trusted `$HOME` would quietly write
/// into the developer's real `~/Library`.
struct Sandbox {
    let root: URL
    let seed: URL?
    var locations: Locations { Locations(root: root, seed: seed) }

    init(seed: URL? = nil) {
        root = URL(filePath: NSTemporaryDirectory())
            .appending(path: "foodtruck-selftest-\(UUID().uuidString)")
        self.seed = seed
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    func destroy() { try? FileManager.default.removeItem(at: root) }

    /// Path plus size for everything under the sandbox. Comparing two of these
    /// is how "this verb changed nothing" becomes a fact rather than a claim.
    func fingerprint() -> Set<String> {
        var out: Set<String> = []
        let e = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)
        while let u = e?.nextObject() as? URL {
            out.insert("\(u.path):\((try? Data(contentsOf: u))?.count ?? -1)")
        }
        return out
    }
}

private func builtins(_ ids: Set<String>? = nil) -> [Recipe] {
    BuiltinEngine().descriptors.filter { ids == nil || ids!.contains($0.id) }
}

/// An environment that points every recipe at the sandbox and nowhere else.
///
/// Every `Kitchen` built in these tests uses it. The inventory recipe reads the
/// machine and runs a declared list of programs on it, and without this seal a
/// test that merely audits would scan the real `/usr/bin` and launch a couple
/// of dozen subprocesses against the developer's Mac -- multiplied by every
/// case that audits, and again by every mutant in a mutation run. That is not
/// a hypothetical: it cost one machine a hard restart.
///
/// A test must be able to run ten thousand times without the host noticing.
private func sealed(_ box: Sandbox) -> [String: String] {
    var environment = Exec.baseEnvironment(box.locations)
    environment["HOME"] = box.root.path
    environment["FOODTRUCK_SCAN_ROOT"] = box.root.path
    return environment
}

enum LocationSuite {
    static let suite = Suite("locations", [
        Case("FOODTRUCK_ROOT relocates every directory at once") { s in
            let l = Locations.resolved(environment: ["FOODTRUCK_ROOT": "/tmp/ft-x"])
            s.equal(l.config.path, "/tmp/ft-x/config", "config under root")
            s.require(l.all.allSatisfy { $0.path.hasPrefix("/tmp/ft-x") }, "nothing escaped the root")
            s.require(l.toolbox.path.hasPrefix("/tmp/ft-x"), "toolbox under root")
        },
        Case("XDG variables win over home-relative defaults") { s in
            let l = Locations.resolved(environment: [
                "HOME": "/Users/nobody", "XDG_CONFIG_HOME": "/xdg/cfg"])
            s.equal(l.config.path, "/xdg/cfg/foodtruck", "XDG_CONFIG_HOME honoured")
            s.equal(l.data.path, "/Users/nobody/.local/share/foodtruck", "unset falls back")
        },
        Case("An empty XDG variable is treated as unset, not as /") { s in
            // Shells export empty variables constantly. Reading "" as a path
            // would put the pantry in /foodtruck: wrong, and unwritable.
            let l = Locations.resolved(environment: [
                "HOME": "/Users/nobody", "XDG_DATA_HOME": ""])
            s.equal(l.data.path, "/Users/nobody/.local/share/foodtruck", "empty means unset")
        },
        Case("The recipe environment carries no ambient variables") { s in
            let env = Exec.baseEnvironment(Locations(root: URL(filePath: "/tmp/ft-y")))
            s.require(env["FOODTRUCK_COOKBOOK_SEED"] == nil, "host wiring must not leak to recipes")
            s.require(env["PATH"]!.hasPrefix("/tmp/ft-y/data/toolbox/bin"),
                      "the toolbox comes first on PATH")
            s.require(!env["PATH"]!.contains("/opt/homebrew"),
                      "Homebrew is unlocked by a recipe, never assumed")
        },
    ])
}

enum GraphSuite {
    private static func r(_ id: String, _ requires: [String] = []) -> Recipe {
        Recipe(id: id, name: id, summary: id, engine: "builtin", requires: requires)
    }
    private static func kitchen(_ recipes: [Recipe]) -> Kitchen {
        Kitchen(locations: Locations(root: URL(filePath: "/tmp/unused")),
                recipes: recipes, engines: [])
    }

    static let suite = Suite("graph", [
        Case("Independent recipes share a wave, so they run at once") { s in
            let waves = try kitchen([r("a"), r("b"), r("c", ["a"]), r("d", ["a", "b"])]).waves()
            s.equal(waves.count, 2, "two waves")
            s.equal(Set(waves[0].map(\.id)), ["a", "b"], "roots run together")
            s.equal(Set(waves[1].map(\.id)), ["c", "d"], "dependents run together")
        },
        Case("A cycle is named rather than hung on") { s in
            do {
                _ = try kitchen([r("a", ["b"]), r("b", ["a"])]).waves()
                s.require(false, "a cycle should not resolve")
            } catch KitchenError.dependencyCycle(let ids) {
                s.equal(ids, ["a", "b"], "the cycle names both recipes")
            }
        },
        Case("A dependency nothing provides names the recipe that wants it") { s in
            do {
                _ = try kitchen([r("a", ["ghost"])]).waves()
                s.require(false, "an unknown dependency should not resolve")
            } catch KitchenError.unknownDependency(let recipe, let missing) {
                s.equal(recipe, "a", "blamed the right recipe")
                s.equal(missing, "ghost", "named the missing dependency")
            }
        },
        Case("A builtin is housekeeping unless it is named here on purpose") { s in
            // The rule that keeps FoodTruck's plumbing off the user's list. A
            // builtin may be something a person should care about, but it has
            // to say so here, deliberately, and give the reason -- which is
            // what stops the next one drifting into visibility by default.
            //
            // `env.inventory` is the first: a builtin because knowing what is
            // installed cannot depend on something being installed, and the
            // user's business because it is entirely about their machine.
            let visibleOnPurpose: Set<String> = ["env.inventory"]
            for recipe in builtins() where !visibleOnPurpose.contains(recipe.id) {
                s.equal(recipe.scope, .housekeeping,
                        "\(recipe.id) would show up in the user's list")
            }
            for id in visibleOnPurpose {
                s.equal(builtins([id]).first?.scope, RecipeScope.environment,
                        "\(id) is listed as deliberately visible but is not")
            }
        },
        Case("A recipe.json with no scope loads as the user's business") { s in
            // Forward compatibility: a recipe written by someone else, before
            // scope existed, is about their machine -- that is the safe default.
            let json = #"{"id":"x","name":"n","summary":"s","engine":"taskfile"}"#
            let recipe = try JSONDecoder().decode(Recipe.self, from: Data(json.utf8))
            s.equal(recipe.scope, .environment, "defaults to environment")
            s.equal(recipe.blast, .contained, "defaults to the safest blast radius")
            s.require(!recipe.customised, "customised is derived, never decoded")
        },
        Case("The shipped recipes form a valid graph") { s in
            // Catches a typo in a `requires` before a user ever sees it.
            let waves = try kitchen(builtins()).waves()
            s.require(!waves.isEmpty, "builtins resolve")
            s.equal(waves[0].map(\.id), ["core.locations"], "the workspace is the only root")
        },
    ])
}

enum ReportSuite {
    private static func outcome(_ code: Int32) -> VerbOutcome {
        ReportDecoder.outcome(
            ExecResult(status: code, stdout: "", stderr: "", timedOut: false, duration: 0),
            recipe: "x", verb: .audit)
    }

    static let suite = Suite("report", [
        Case("A recipe that prints nothing is not a broken recipe") { s in
            guard case .success(let r) = ReportDecoder.decode(
                stdout: "", recipe: "x", verb: .audit) else {
                s.require(false, "empty output should decode"); return
            }
            s.require(r.findings.isEmpty, "no findings")
        },
        Case("Chatter before the JSON is tolerated") { s in
            let out = "+ checking\n{\"schema\":\"foodtruck.report/1\",\"findings\":[],\"facts\":{\"v\":\"1\"}}"
            guard case .success(let r) = ReportDecoder.decode(
                stdout: out, recipe: "x", verb: .audit) else {
                s.require(false, "should decode past the noise"); return
            }
            s.equal(r.facts["v"], "1", "facts survived")
        },
        Case("Broken JSON is a named fault with a remedy, never a crash") { s in
            guard case .failure(let f) = ReportDecoder.decode(
                stdout: "{ not json", recipe: "x", verb: .audit) else {
                s.require(false, "malformed JSON should fault"); return
            }
            s.equal(f.kind, .malformedReport, "correct fault kind")
            s.require(!f.remedy.isEmpty, "every fault carries a remedy")
        },
        Case("An unknown exit code is never mistaken for success") { s in
            s.equal(outcome(0), .converged, "0 is converged")
            s.equal(outcome(10), .drift, "10 is drift")
            s.equal(outcome(20), .blocked, "20 is blocked")
            // The one that matters: almost every CLI exits 1 when it breaks.
            for code: Int32 in [1, 2, 126, 127, 201] {
                if case .failed = outcome(code) {} else {
                    s.require(false, "exit \(code) must be a failure")
                }
            }
        },
        Case("Every fault kind has both a title and a remedy in English") { s in
            L10n.shared.configure(locales: ["en"])
            for kind in [RecipeFault.Kind.recipeMissing, .recipeMalformed, .verbUnsupported,
                         .engineUnavailable, .unexpectedExit, .malformedReport, .timedOut,
                         .readOnlyViolation, .integrityFailure, .cancelled] {
                let f = RecipeFault(kind: kind, recipe: "r", verb: .audit)
                s.require(t(f.title) != f.title, "missing title string for \(kind.rawValue)")
                s.require(t(f.remedy) != f.remedy, "missing remedy string for \(kind.rawValue)")
            }
        },
    ])
}

enum EvidenceSuite {
    static let suite = Suite("evidence", [
        Case("A vacuous check is never counted as proof") { s in
            // The distinction the whole type exists for: passing because
            // nothing was asked is not the same as passing because something
            // was verified.
            let report = RecipeReport(checks: [
                Check(id: "a", label: "real", passed: true),
                Check(id: "b", label: "empty", passed: true, vacuous: true),
                Check(id: "c", label: "failed", passed: false),
            ])
            s.equal(report.provenCount, 1, "only the real pass counts as proof")
        },
        Case("A converged recipe can show what it actually evaluated") { s in
            // A green result that cannot show its working is indistinguishable
            // from one that checked nothing, so converging must leave evidence.
            let box = Sandbox(); defer { box.destroy() }
            let kitchen = Kitchen(locations: box.locations, recipes: builtins(["core.locations"]), environment: sealed(box))
            _ = try await kitchen.converge(only: ["core.locations"])
            let service = await kitchen.inspect(.audit)
            let checks = service.results.flatMap(\.report.checks)
            s.require(!checks.isEmpty, "converged with no evidence of what was checked")
            s.require(checks.allSatisfy(\.passed), "every check should pass after converge")
        },
        Case("An older report with no checks still decodes") { s in
            let json = #"{"schema":"foodtruck.report/1","findings":[],"facts":{}}"#
            let report = try JSONDecoder().decode(RecipeReport.self, from: Data(json.utf8))
            s.require(report.checks.isEmpty, "absent checks decode as empty, not a failure")
            s.equal(report.provenCount, 0, "and prove nothing")
        },
    ])
}

enum ReadOnlySuite {
    static let suite = Suite("read-only", [
        Case("audit changes nothing, on a machine where everything is missing") { s in
            let box = Sandbox(); defer { box.destroy() }
            let kitchen = Kitchen(locations: box.locations, recipes: builtins(), environment: sealed(box))
            let before = box.fingerprint()
            let service = await kitchen.inspect(.audit)
            s.equal(box.fingerprint(), before, "audit wrote to the sandbox")
            s.require(!service.isClean, "a bare sandbox must report drift")
        },
        Case("Every verb declares honestly whether it may write") { s in
            s.equal(Verb.allCases.filter(\.isReadOnly).count, 4, "four read-only verbs")
            s.require(!Verb.converge.isReadOnly, "converge writes")
            s.require(!Verb.rollback.isReadOnly, "rollback writes")
        },
        Case("A dry run reports the drift and repairs none of it") { s in
            let box = Sandbox(); defer { box.destroy() }
            let kitchen = Kitchen(locations: box.locations, recipes: builtins(["core.locations"]), environment: sealed(box))
            let before = box.fingerprint()
            let service = try await kitchen.converge(only: ["core.locations"], dryRun: true)
            s.equal(box.fingerprint(), before, "a dry run wrote to disk")
            s.require(!service.isClean, "a dry run still reports the drift")
        },
    ])
}

enum ConvergeSuite {
    static let suite = Suite("converge", [
        Case("Running it twice is running it once") { s in
            let box = Sandbox(); defer { box.destroy() }
            let kitchen = Kitchen(locations: box.locations, recipes: builtins(["core.locations"]), environment: sealed(box))
            let first = try await kitchen.converge(only: ["core.locations"])
            s.require(first.isClean, "first converge should settle")
            let settled = box.fingerprint()
            let second = try await kitchen.converge(only: ["core.locations"])
            s.require(second.isClean, "second converge should settle")
            s.equal(box.fingerprint(), settled, "the second converge changed something")
        },
        Case("It repairs damage done behind its back") { s in
            // The ansible property: an unknown starting state converges anyway.
            let box = Sandbox(); defer { box.destroy() }
            let kitchen = Kitchen(locations: box.locations, recipes: builtins(["core.locations"]), environment: sealed(box))
            _ = try await kitchen.converge(only: ["core.locations"])
            try FileManager.default.removeItem(at: box.locations.state)
            s.require(!(await kitchen.inspect(.audit).isClean), "deletion should show as drift")
            _ = try await kitchen.converge(only: ["core.locations"])
            s.require(await kitchen.inspect(.audit).isClean, "converge should have repaired it")
        },
        Case("A recipe that would reach past the ceiling is refused, not trusted") { s in
            // Homebrew is the reason this exists: HOMEBREW_PREFIX is ignored, so
            // `brew bundle` reaches /opt/homebrew whatever the environment says.
            // The gate must hold before any engine is consulted.
            let box = Sandbox(); defer { box.destroy() }
            let systemRecipe = Recipe(id: "fake.system", name: "n", summary: "n",
                                      engine: "builtin", blast: .system)
            let kitchen = Kitchen(locations: box.locations, recipes: [systemRecipe],
                                  blastCeiling: .contained, environment: sealed(box))
            let service = try await kitchen.converge()
            s.equal(service.blocked.count, 1, "the system-blast recipe was refused")
            s.require(service.failed.isEmpty, "a refusal is not a failure")
            s.equal(box.fingerprint().count, 0, "nothing was written")
        },
        Case("The ceiling never blocks an audit") { s in
            // Seeing what a recipe would cost is exactly why you audit it.
            let box = Sandbox(); defer { box.destroy() }
            let systemRecipe = Recipe(id: "fake.system", name: "n", summary: "n",
                                      engine: "builtin", blast: .privileged)
            let kitchen = Kitchen(locations: box.locations, recipes: [systemRecipe],
                                  blastCeiling: .contained, environment: sealed(box))
            let service = await kitchen.inspect(.audit)
            s.equal(service.blocked.count, 0, "audit is never gated by blast radius")
        },
        Case("A recipe whose dependency is unmet waits instead of failing") { s in
            let box = Sandbox(); defer { box.destroy() }
            // core.toolbox.task requires core.locations, which is excluded here.
            let kitchen = Kitchen(locations: box.locations, recipes: builtins(), environment: sealed(box))
            let service = try await kitchen.converge(only: ["core.toolbox.task"], dryRun: true)
            s.require(service.failed.isEmpty, "an unmet dependency is not a failure")
        },
    ])
}

enum IntlSuite {
    static let suite = Suite("intl", [
        Case("A missing key falls back visibly rather than blank") { s in
            L10n.shared.configure(locales: ["en"])
            s.equal(t("no.such.key.anywhere"), "no.such.key.anywhere", "shows the key")
            s.require(L10n.shared.misses.contains("no.such.key.anywhere"), "and records the miss")
        },
        Case("Named placeholders are substituted and may be reordered") { s in
            L10n.shared.configure(locales: ["en"])
            let out = t("finding.tool.stale",
                        ["tool": "node", "observed": "20", "desired": "22"])
            s.require(out.contains("node") && out.contains("20") && out.contains("22"),
                      "all placeholders filled: \(out)")
            s.require(!out.contains("%{"), "no placeholder left behind: \(out)")
        },
        Case("An unsupported locale still resolves, via English") { s in
            L10n.shared.configure(locales: ["xx-YY"])
            s.require(t("app.name") == "FoodTruck", "fell back to English")
            L10n.shared.configure(locales: ["en"])
        },
        Case("A translated locale actually resolves, rather than quietly falling back") { s in
            // The failure this guards against is the nasty one: a locale that
            // "works" because every lookup silently returns English, which looks
            // fine to a reviewer who does not read Spanish.
            L10n.shared.configure(locales: ["es"])
            s.equal(t("state.drift"), "Requiere atención", "Spanish resolved")
            s.require(t("action.converge") != "Fix What Can Be Fixed",
                      "the Spanish build is showing English")
            L10n.shared.configure(locales: ["en"])
        },
        Case("Placeholders survive translation in every shipped locale") { s in
            // A translator who drops %{tool} produces a sentence with a hole in
            // it. Catch that here rather than in a screenshot.
            for locale in L10n.supported {
                L10n.shared.configure(locales: [locale])
                let out = t("finding.tool.stale",
                            ["tool": "node", "observed": "20", "desired": "22"])
                guard out != "finding.tool.stale" else { continue }   // not translated yet
                s.require(out.contains("node") && out.contains("22"),
                          "\(locale): placeholders lost -> \(out)")
                s.require(!out.contains("%{"), "\(locale): unsubstituted placeholder -> \(out)")
            }
            L10n.shared.configure(locales: ["en"])
        },
        Case("Plural rules cover every shipped locale") { s in
            for locale in L10n.supported {
                s.require(L10n.hasExplicitPluralRule(locale),
                          "\(locale) has no plural rule; add one before shipping it")
            }
        },
        Case("Counts pick the right wording") { s in
            L10n.shared.configure(locales: ["en"])
            s.equal(tn("summary.attention", 1), "1 needs attention", "singular")
            s.equal(tn("summary.attention", 3), "3 need attention", "plural")
            L10n.shared.configure(locales: ["es"])
            s.equal(tn("summary.attention", 1), "1 requiere atención", "Spanish singular")
            s.equal(tn("summary.attention", 3), "3 requieren atención", "Spanish plural")
            L10n.shared.configure(locales: ["en"])
        },
        Case("Every string the code can emit exists in English") { s in
            // The lint that keeps the fallback from ever being what a user sees.
            L10n.shared.configure(locales: ["en"])
            L10n.shared.resetMisses()
            for severity in Severity.allCases { _ = t("severity.\(severity.rawValue)") }
            for blast in Blast.allCases { _ = t("blast.\(blast.rawValue)") }
            for state in ["converged", "drift", "blocked", "failed", "unknown"] {
                _ = t("state.\(state)")
            }
            for recipe in BuiltinEngine().descriptors {
                _ = t(recipe.name); _ = t(recipe.summary)
            }
            s.require(L10n.shared.misses.isEmpty,
                      "untranslated keys: \(L10n.shared.misses.sorted().joined(separator: ", "))")
        },
    ])
}

enum InventorySuite {
    private static let fm = FileManager.default

    private static func executable(_ url: URL, printing banner: String = "") throws {
        let body = banner.isEmpty ? "exit 9" : "echo \(banner)"
        try fm.createDirectory(at: url.deletingLastPathComponent(),
                               withIntermediateDirectories: true)
        try Data("#!/bin/sh\n\(body)\n".utf8).write(to: url)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }

    /// A fake machine, so every claim below is tested against a shape rather
    /// than against whatever the machine running the tests happens to have.
    /// Nothing here is installed anywhere; these are five-line shell scripts.
    ///
    /// The layout reproduces the specific things that have been got wrong:
    /// Homebrew's prefix being its own checkout, a Cellar path that disagrees
    /// with the tool it holds, and a shim whose link leads through a second
    /// symlink into a completely unrelated Cellar.
    private static func fixture(_ box: Sandbox) throws -> [URL] {
        let brewBin = box.root.appending(path: "opt/homebrew/bin")
        let cellar = box.root.appending(path: "opt/homebrew/Cellar")
        let shims = box.root.appending(path: "mise/shims")
        let vendorBin = box.root.appending(path: "usr/local/bin")

        // The two markers that make a directory a Homebrew installation rather
        // than a directory that happens to be named after one.
        try fm.createDirectory(at: box.root.appending(path: "opt/homebrew/Library/Homebrew"),
                               withIntermediateDirectories: true)
        for dir in [brewBin, shims, vendorBin] {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        func link(_ from: URL, _ to: URL) throws {
            try fm.createSymbolicLink(at: from, withDestinationURL: to)
        }

        // brew itself: a plain file inside its own prefix, as on Apple silicon.
        try executable(brewBin.appending(path: "brew"))

        // An ordinary formula: bin symlink into a Cellar that tells the truth.
        let gh = cellar.appending(path: "gh/2.76.0/bin/gh")
        try executable(gh)
        try link(brewBin.appending(path: "gh"), gh)

        // A Cellar path that disagrees with the tool inside it.
        let jq = cellar.appending(path: "jq/9.9.9/bin/jq")
        try executable(jq, printing: "jq-1.7.1")
        try link(brewBin.appending(path: "jq"), jq)

        // A real node, so it can be caught shadowing the shim below.
        let node = cellar.appending(path: "node/26.5.0/bin/node")
        try executable(node)
        try link(brewBin.appending(path: "node"), node)

        // mise, installed by Homebrew, so it is itself a Cellar symlink...
        let mise = cellar.appending(path: "mise/2026.8.8/bin/mise")
        try executable(mise)
        try link(brewBin.appending(path: "mise"), mise)
        // ...and a shim pointing at it. Resolving this chain all the way lands
        // in `Cellar/mise/2026.8.8`, which is how `node` once acquired both
        // Homebrew as its installer and mise's version as its version.
        try link(shims.appending(path: "node"), brewBin.appending(path: "mise"))

        // A bin directory with no Cellar above it: nobody's.
        try executable(vendorBin.appending(path: "handplaced"))

        return [brewBin, shims, vendorBin]
    }

    private static func scan(_ box: Sandbox, _ roots: [URL] = []) -> Inventory {
        Inventory.scan(home: box.root, locations: box.locations,
                       systemRoot: box.root, roots: roots)
    }

    private static func tool(_ inventory: Inventory, _ name: String) -> Installed? {
        inventory.tools.first { $0.name == name }
    }

    static let suite = Suite("inventory", [

        // MARK: attribution

        Case("A Homebrew prefix is recognised by what it contains, not what it is called") { s in
            let box = Sandbox(); defer { box.destroy() }
            let inventory = scan(box, try fixture(box))
            guard let gh = tool(inventory, "gh"), let brew = tool(inventory, "brew"),
                  let loose = tool(inventory, "handplaced") else {
                s.require(false, "fixture missing: \(inventory.tools.map(\.name))"); return
            }
            s.equal(gh.origin, Origin.homebrew, "the Cellar symlink names its installer")
            // On Apple silicon the prefix *is* the Homebrew checkout, so `brew`
            // is a plain file in `<prefix>/bin`. Reporting the tool that manages
            // everything as managed by nothing costs a list its credibility.
            s.equal(brew.origin, Origin.homebrew, "brew lives inside its own prefix")
            s.equal(loose.origin, Origin.unmanaged,
                    "a bin directory that is not a Homebrew prefix owns nothing")
            s.require(loose.version == nil, "a version was invented for it")
        },
        Case("Following a shim's link describes the manager, never the tool") { s in
            // Regression, and the subtlest thing here. The shim points at mise,
            // mise is itself a Cellar symlink, so resolving the whole chain
            // reports `node` as installed by Homebrew at mise's version. Both
            // wrong, and wrong in the confident way.
            let box = Sandbox(); defer { box.destroy() }
            let inventory = scan(box, try fixture(box))
            guard let shim = inventory.tools.first(where: { $0.name == "node" && $0.shim })
            else { s.require(false, "fixture missing the node shim"); return }
            s.equal(shim.origin, Origin.mise, "the shim was credited to mise's own installer")
            s.require(shim.version == nil, "mise's version was attached to node")
        },
        Case("The scan alone runs nothing, and says so about what it reports") { s in
            let box = Sandbox(); defer { box.destroy() }
            let inventory = scan(box, try fixture(box))
            s.equal(inventory.tools.count, 7, "all seven found")
            s.require(inventory.tools.allSatisfy { $0.versionSource != .probed },
                      "the scan claimed a probed version without running anything")
            s.require(inventory.unmanaged.allSatisfy { $0.version == nil },
                      "a hand-installed program has no layout to read a version out of")
        },

        // MARK: versions

        Case("A tool is believed over the directory it was unpacked into") { s in
            // Install layouts are a convention. Things get moved, renamed and
            // unpacked in odd places, and only the tool actually knows.
            let box = Sandbox(); defer { box.destroy() }
            let scanned = scan(box, try fixture(box))
            guard let inferred = tool(scanned, "jq") else {
                s.require(false, "fixture missing jq"); return
            }
            s.equal(inferred.version, "9.9.9", "the path claims 9.9.9")
            s.equal(inferred.versionSource, VersionSource.inferred, "and only claims it")

            let probed = await scanned.probingVersions(
                home: box.root, environment: Exec.baseEnvironment(box.locations))
            guard let jq = tool(probed, "jq") else {
                s.require(false, "jq lost in probing"); return
            }
            s.equal(jq.version, "1.7.1", "the tool's own answer wins")
            s.equal(jq.versionSource, VersionSource.probed, "recorded as its own answer")
        },
        Case("A shim is never run, because running one installs a toolchain") { s in
            // The probe once ran `mise/shims/node --version`; mise answered by
            // downloading and installing Node 22 into the sandbox, from a verb
            // that promises to change nothing.
            let box = Sandbox(); defer { box.destroy() }
            let scanned = scan(box, try fixture(box))
            guard let shim = scanned.tools.first(where: { $0.name == "node" && $0.shim })
            else { s.require(false, "fixture missing the node shim"); return }
            s.require(scanned.probeTarget(for: shim, home: box.root.path,
                                          systemRoot: box.root,
                                          developerDirectory: nil) == nil,
                      "the shim would have been run")
        },
        Case("Only declared tools are run, wherever they happen to live") { s in
            let box = Sandbox(); defer { box.destroy() }
            let probed = await scan(box, try fixture(box)).probingVersions(
                home: box.root, environment: Exec.baseEnvironment(box.locations))
            let asked = Set(probed.tools.filter { $0.versionSource == .probed }.map(\.name))
            // brew, mise and node are on the list and were found; the shim is
            // excluded above, and `handplaced` is nobody's business.
            s.require(!asked.contains("handplaced"), "an undeclared program was run")
            s.require(asked.contains("jq"), "a declared program was skipped")
        },
        Case("A developer-tool stub is resolved, never run, and skipped if empty") { s in
            // Apple's stubs are all hard links to one file -- on macOS 26.6,
            // `git`, `clang`, `swift`, `make` and `cmpdylib` share an inode
            // with 78 links, while `ruby` and `zsh` have one each. So the
            // family is identified by shape, with no list of names to maintain.
            //
            // The stub is a forwarder, and running one whose tool is not
            // installed is what puts up "requires the command line developer
            // tools". That dialog is not a question a user can answer, so it
            // must never be asked: resolve the stub to the real tool, and if
            // there is no real tool, run nothing.
            let box = Sandbox(); defer { box.destroy() }
            let usrbin = box.root.appending(path: "usr/bin")
            let developer = box.root.appending(path: "Developer")
            try fm.createDirectory(at: developer.appending(path: "usr/bin"),
                                   withIntermediateDirectories: true)
            try executable(usrbin.appending(path: "git"))
            // cmpdylib as a hard link to git: one file, two names, exactly the
            // shape of the real thing.
            try fm.linkItem(at: usrbin.appending(path: "git"),
                            to: usrbin.appending(path: "cmpdylib"))
            // The developer directory backs git, and nothing else.
            try executable(developer.appending(path: "usr/bin/git"))

            let inventory = Inventory(
                host: Inventory.host(systemRoot: box.root), roots: [],
                tools: [Installed(name: "git", path: usrbin.appending(path: "git").path,
                                  origin: .apple),
                        Installed(name: "cmpdylib",
                                  path: usrbin.appending(path: "cmpdylib").path,
                                  origin: .apple),
                        Installed(name: "jq", path: "~/.local/bin/jq", origin: .unmanaged)])
            func target(_ name: String) -> String? {
                guard let tool = inventory.tools.first(where: { $0.name == name })
                else { return nil }
                return inventory.probeTarget(for: tool, home: box.root.path,
                                             systemRoot: box.root,
                                             developerDirectory: developer.path)
            }
            s.equal(target("git"), developer.appending(path: "usr/bin/git").path,
                    "the stub should resolve to the tool behind it, not run itself")
            s.require(target("cmpdylib") == nil,
                      "a stub with nothing behind it was going to be run")
            s.equal(target("jq"), box.root.path + "/.local/bin/jq",
                    "an ordinary program is still run where it is")
        },
        Case("A candidate set larger than the declared list runs nothing at all") { s in
            // The ceiling, and the reason it exists. Inverting one `return` in
            // the gate turned "run twenty-odd declared tools" into "run every
            // executable on this machine", and it reached a real Mac. A bound
            // derived from the size of the declared list cannot be undone by
            // that mistake, because it does not consult the gate's reasoning.
            let box = Sandbox(); defer { box.destroy() }
            let bin = box.root.appending(path: "bin")
            var tools: [Installed] = []
            for index in 0...Inventory.probeCeiling {
                let url = bin.appending(path: "tool\(index)")
                try executable(url, printing: "1.0.0")
                // Every one of them declared, so only the ceiling can stop it.
                tools.append(Installed(name: "jq", path: url.path, origin: .unmanaged))
            }
            let flooded = Inventory(host: Inventory.host(systemRoot: box.root),
                                    roots: [], tools: tools)
            let result = await flooded.probingVersions(
                home: box.root, environment: Exec.baseEnvironment(box.locations),
                systemRoot: box.root)
            s.require(result.probeRefused, "the flood was not refused")
            s.require(result.tools.allSatisfy { $0.versionSource != .probed },
                      "something was run despite the refusal")
        },

        // MARK: more than one copy

        Case("A shim beside a real install is named, not folded into a count") { s in
            // The most consequential thing here, and invisible to every other
            // check: both are on PATH, the shim has no version to compare, and
            // two lines in a shell startup file decide which one you get.
            let box = Sandbox(); defer { box.destroy() }
            let inventory = scan(box, try fixture(box))
            guard let copies = inventory.shadowedShims["node"] else {
                s.require(false, "the shadowed node was not reported"); return
            }
            s.equal(copies.count, 2, "both copies listed")
            s.require(copies.contains(where: \.shim) && copies.contains(where: { !$0.shim }),
                      "one of each")
        },
        Case("With two managers shimming one tool, the finding names the one in front") { s in
            // The case the inventory exists for, and the one no fixture had:
            // mise and asdf both shimming `node` over a real Homebrew install.
            // Naming a manager at all is a claim about which one is in play, so
            // picking whichever sorted last would blame the wrong tool -- and
            // the sentence reads just as confidently either way.
            let box = Sandbox(); defer { box.destroy() }
            // Two direct installs and two shims, and nothing else: what makes
            // each of them a Homebrew formula or not is decided elsewhere and
            // no assertion here reads it, so building a Cellar would only give
            // a later reader something load-bearing to wonder about.
            try executable(box.root.appending(path: "opt/homebrew/bin/node"))
            try executable(box.root.appending(path: "usr/local/bin/node"))
            // Both shim directories are found by the declared search order:
            // mise's comes before asdf's, and neither is on any PATH here.
            try executable(box.root.appending(path: ".local/share/mise/shims/node"))
            try executable(box.root.appending(path: ".asdf/shims/node"))

            let kitchen = Kitchen(locations: box.locations,
                                  recipes: builtins(["env.inventory"]),
                                  environment: sealed(box))
            let service = await kitchen.inspect(.audit)
            let findings = service.results.flatMap { $0.report.findings }
            guard let shadow = findings.first(where: { $0.id == "inventory.shimShadowed:node" })
            else {
                s.require(false, "the shadowed node was not reported: \(findings.map(\.id))")
                return
            }
            s.equal(shadow.args["manager"], "mise", "the wrong manager was blamed")
            s.equal(shadow.args["shim"], "~/.local/share/mise/shims/node",
                    "the quoted shim is not the one searched first")
            s.equal(shadow.args["direct"], "~/opt/homebrew/bin/node",
                    "the quoted install is not the one searched first")
        },
        Case("A copy with no known version is not evidence of a conflict") { s in
            // "I could not tell" must not become "these differ". The shim has
            // no version by construction, so counting it as different would
            // report a conflict on every managed tool on the machine.
            let box = Sandbox(); defer { box.destroy() }
            let inventory = scan(box, try fixture(box))
            s.require(inventory.conflictingVersions["node"] == nil,
                      "an unknown version was treated as a differing one")
        },

        Case("Which of several copies is quoted follows search order, not the alphabet") { s in
            // Two copies of a manager is the ordinary case: Homebrew installs
            // mise, mise's own installer puts one in ~/.local/bin, and both
            // stay. Something has to decide which one the reported version
            // belongs to. Sorting the tool list by path -- which is done for a
            // stable snapshot, not for this -- decides it by ASCII, so `/opt`
            // beats `~/.local` for no reason anyone could defend.
            let box = Sandbox(); defer { box.destroy() }
            let brewBin = box.root.appending(path: "opt/homebrew/bin")
            let localBin = box.root.appending(path: ".local/bin")
            try executable(brewBin.appending(path: "mise"))
            try executable(localBin.appending(path: "mise"))

            // In the sandbox home and system root are the same directory, so
            // `/opt/homebrew` is written `~/opt/homebrew` like everything else.
            func evidence(_ roots: [URL]) -> String? {
                scan(box, roots).managers.first { $0.id == "mise" }?.evidence
            }
            s.equal(evidence([localBin, brewBin]), "~/.local/bin/mise",
                    "the earliest searched copy should be the one quoted")
            // The same two files, searched the other way round. If the answer
            // does not move, the order is not being consulted at all.
            s.equal(evidence([brewBin, localBin]), "~/opt/homebrew/bin/mise",
                    "search order was ignored in favour of something else")
        },

        // MARK: the tools that decide what the other tools are

        Case("A manager that is not a program at all is still found") { s in
            // nvm is a shell function sourced from ~/.nvm/nvm.sh. Nothing on
            // PATH names it, so a scan of executables concludes it is absent
            // while it is deciding which node you get.
            let box = Sandbox(); defer { box.destroy() }
            try fm.createDirectory(at: box.root.appending(path: ".nvm"),
                                   withIntermediateDirectories: true)
            guard let nvm = scan(box).managers.first(where: { $0.id == "nvm" }) else {
                s.require(false, "a directory-only manager was missed"); return
            }
            s.require(nvm.shellFunction, "nvm is not an executable")
            s.require(nvm.version == nil, "there is no binary to have asked")
            s.equal(nvm.manages, ["node"], "and it is a node manager")
        },
        Case("Two managers wanting one runtime is known before either is run") { s in
            // Declared rather than discovered: what a manager is capable of
            // managing is a fact about the tool. So the overlap is knowable
            // without interrogating anything, which is the only way to see it
            // before PATH order has already silently decided.
            let box = Sandbox(); defer { box.destroy() }
            for dir in [".pyenv", "miniconda3"] {
                try fm.createDirectory(at: box.root.appending(path: dir),
                                       withIntermediateDirectories: true)
            }
            let contested = scan(box).contested
            s.equal(contested["python"] ?? [], ["conda", "pyenv"], "both named")
            s.require(contested["ruby"] == nil, "a runtime neither manages is not contested")
        },
        Case("A tool that only sometimes manages things must show that it does") { s in
            // pnpm can install Node with `pnpm env use`, and almost nobody
            // does. Counting every machine with pnpm as having a second node
            // manager announces a conflict that is not happening.
            let box = Sandbox(); defer { box.destroy() }
            let bin = box.root.appending(path: "opt/homebrew/bin")
            try executable(bin.appending(path: "pnpm"))
            s.require(!scan(box, [bin]).managers.contains { $0.id == "pnpm" },
                      "pnpm counted as a node manager on presence alone")

            try fm.createDirectory(at: box.root.appending(path: "Library/pnpm/nodejs"),
                                   withIntermediateDirectories: true)
            s.require(scan(box, [bin]).managers.contains { $0.id == "pnpm" },
                      "pnpm is managing node here and was not counted")
        },

        // MARK: the record

        Case("Two scans of an unchanged machine produce identical bytes") { s in
            // Without this the history is a heartbeat: a commit on every run,
            // none of which mean anything. It is also why the record carries no
            // timestamp of its own.
            let box = Sandbox(); defer { box.destroy() }
            let roots = try fixture(box)
            s.equal(scan(box, roots), scan(box, roots), "the record differs from itself")
            s.equal(scan(box, roots).text, scan(box, roots).text, "the rendering drifts")
        },
        Case("A recorded inventory reads back as the same value") { s in
            let box = Sandbox(); defer { box.destroy() }
            let inventory = scan(box, try fixture(box))
            let store = InventoryStore(root: box.locations.inventory)
            try store.write(inventory)
            guard let reloaded = store.load() else {
                s.require(false, "nothing read back"); return
            }
            s.equal(reloaded, inventory, "round trip lost something")
        },
        Case("A snapshot written before a field existed still loads") { s in
            // A history whose older entries cannot be read is not a history,
            // and re-recording from scratch erases the comparison it is kept for.
            let json = #"{"schema":"foodtruck.inventory/1","host":{"product":"macOS","version":"26.6","build":"25G83","arch":"arm64","kernel":"25.6.0"},"roots":[],"tools":[]}"#
            let old = try JSONDecoder().decode(Inventory.self, from: Data(json.utf8))
            s.require(old.managers.isEmpty, "absent managers decode as none, not as a failure")
            s.equal(old.host.version, "26.6", "the rest survived")
        },
        Case("Auditing writes nothing, not even its own directory") { s in
            let box = Sandbox(); defer { box.destroy() }
            let kitchen = Kitchen(locations: box.locations, recipes: builtins(["env.inventory"]), environment: sealed(box))
            let before = box.fingerprint()
            _ = await kitchen.inspect(.audit)
            s.equal(box.fingerprint(), before, "audit wrote to the sandbox")
            s.require(!FileManager.default.fileExists(atPath: box.locations.inventory.path),
                      "audit created the inventory directory")
        },
        Case("Once the machine is recorded there is nothing left to fix") { s in
            let box = Sandbox(); defer { box.destroy() }
            let kitchen = Kitchen(locations: box.locations,
                                  recipes: builtins(["core.locations", "env.inventory"]), environment: sealed(box))
            _ = try await kitchen.converge()
            let service = await kitchen.inspect(.audit)
            // Notices -- unmanaged programs, contested runtimes -- are expected
            // on any real machine and are deliberately not drift.
            s.require(service.drifted.isEmpty,
                      "still drifted: \(service.drifted.flatMap { $0.report.findings.map(\.id) })")
        },
        Case("A version already asked for is not asked for again") { s in
            // The cache is a safety feature, not an optimisation. Without it
            // every audit re-launches every declared tool, which is how one
            // mutation run turned into a few thousand process launches.
            let box = Sandbox(); defer { box.destroy() }
            let bin = box.root.appending(path: "bin")
            let jq = bin.appending(path: "jq")
            try executable(jq, printing: "jq-1.7.1")
            let env = Exec.baseEnvironment(box.locations)

            let first = await Inventory
                .scan(home: box.root, locations: box.locations,
                      systemRoot: box.root, roots: [bin])
                .probingVersions(home: box.root, environment: env, systemRoot: box.root)
            s.equal(first.tools.first?.version, "1.7.1", "asked once")

            // Change what the program says while leaving its size and mtime
            // alone, so the stamp is identical. If the answer still comes back
            // 1.7.1, the program was not run a second time -- which is the
            // only way to observe "did not run" from the outside.
            let modified = try fm.attributesOfItem(atPath: jq.path)[.modificationDate]
            try Data("#!/bin/sh\necho jq-9.9.9\n".utf8).write(to: jq)
            try fm.setAttributes([.posixPermissions: 0o755,
                                  .modificationDate: modified as Any],
                                 ofItemAtPath: jq.path)
            let second = await Inventory
                .scan(home: box.root, locations: box.locations,
                      systemRoot: box.root, roots: [bin])
                .probingVersions(home: box.root, environment: env,
                                 systemRoot: box.root, reusing: first)
            s.equal(second.tools.first?.version, "1.7.1",
                    "the program was run again instead of its answer being reused")
        },
        Case("A manager that is a program reports its own version") { s in
            // Managers move faster than the things they install, so a stale one
            // is its own problem. A shell function has no binary to ask and
            // says so instead of going quiet.
            let box = Sandbox(); defer { box.destroy() }
            let bin = box.root.appending(path: "bin")
            try executable(bin.appending(path: "mise"), printing: "2026.8.8")
            try fm.createDirectory(at: box.root.appending(path: ".nvm"),
                                   withIntermediateDirectories: true)
            let probed = await Inventory
                .scan(home: box.root, locations: box.locations,
                      systemRoot: box.root, roots: [bin])
                .probingVersions(home: box.root,
                                 environment: Exec.baseEnvironment(box.locations),
                                 systemRoot: box.root)
            guard let mise = probed.managers.first(where: { $0.id == "mise" }),
                  let nvm = probed.managers.first(where: { $0.id == "nvm" }) else {
                s.require(false, "managers missing: \(probed.managers.map(\.id))"); return
            }
            s.require(!mise.shellFunction, "mise is a program, not a shell function")
            s.equal(mise.version, "2026.8.8", "a manager's own version was not asked for")
            s.require(nvm.shellFunction, "nvm is a shell function")
            s.require(nvm.version == nil, "there was no binary to have asked")
        },
        Case("A path component that is not a version is not read as one") { s in
            // The guard is "starts with a digit". Checking the wrong end of the
            // string accepts `v2.1` as a version, which is a directory naming
            // convention rather than something the tool ever said.
            s.equal(Inventory.version(from: "/opt/homebrew/Cellar/foo/2.1/bin/foo"), "2.1",
                    "a real version was rejected")
            s.require(Inventory.version(from: "/opt/homebrew/Cellar/foo/v2.1/bin/foo") == nil,
                      "a component that does not begin with a digit was read as a version")
            s.require(Inventory.version(from: "/opt/homebrew/Cellar/foo/stable/bin/foo") == nil,
                      "a word was read as a version")
        },
        Case("What the recipe reports matches what it found") { s in
            let box = Sandbox(); defer { box.destroy() }
            // A program nobody manages, and one name installed twice at
            // different versions -- neither directory has a Cellar above it.
            try executable(box.root.appending(path: "usr/local/bin/handplaced"))
            try executable(box.root.appending(path: "usr/local/bin/jq"), printing: "jq-2.0.0")
            try executable(box.root.appending(path: "opt/homebrew/bin/jq"), printing: "jq-1.7.1")

            let kitchen = Kitchen(locations: box.locations,
                                  recipes: builtins(["core.locations", "env.inventory"]),
                                  environment: sealed(box))
            let service = await kitchen.inspect(.audit)
            guard let report = service.results
                .first(where: { $0.recipe == "env.inventory" })?.report else {
                s.require(false, "the inventory did not report"); return
            }
            func finding(_ prefix: String) -> Finding? {
                report.findings.first { $0.id.hasPrefix(prefix) }
            }
            func check(_ id: String) -> Check? { report.checks.first { $0.id == id } }

            // `fixable` is what puts a Fix button on a finding. Whether to
            // adopt a hand-installed program, or which of two copies to keep,
            // is a decision FoodTruck has no business claiming it can make.
            guard let unmanaged = finding("inventory.unmanaged:"),
                  let conflict = finding("inventory.versionConflict:") else {
                s.require(false, "expected findings missing: \(report.findings.map(\.id))")
                return
            }
            s.require(!unmanaged.fixable, "converge cannot adopt a program for you")
            s.require(unmanaged.remedy != nil, "a finding that cannot be fixed must say what to do")
            s.require(!conflict.fixable, "converge cannot choose which copy you meant")

            guard let traceable = check("traceable"), let unique = check("unique"),
                  let managers = check("managers") else {
                s.require(false, "expected checks missing"); return
            }
            s.require(!traceable.passed, "two unmanaged programs, and the check passed")
            s.require(!traceable.vacuous, "programs were found, so it proved something")
            s.require(!unique.passed, "jq is installed twice at different versions")
            s.require(managers.vacuous, "no manager here, so that check proves nothing")
        },
        Case("Recording the machine actually writes a commit") { s in
            let box = Sandbox(); defer { box.destroy() }
            // A machine with no usable git still records the snapshot; only the
            // history is lost. Nothing to assert there, so step aside.
            guard InventoryStore.executable() != nil else { return }
            let kitchen = Kitchen(locations: box.locations,
                                  recipes: builtins(["core.locations", "env.inventory"]),
                                  environment: sealed(box))
            _ = try await kitchen.converge()
            let store = InventoryStore(root: box.locations.inventory)
            let history = await store.history(
                limit: 5, environment: Exec.baseEnvironment(box.locations))
            s.require(!history.isEmpty, "converge reported success but committed nothing")
        },
        Case("A system binary we cannot inspect is treated as a stub") { s in
            // The two wrong answers here cost different amounts. Guessing
            // "stub" loses a version string; guessing "not a stub" runs it,
            // and if it was a stub with nothing behind it that is the install
            // dialog. Uncertainty takes the side that cannot interrupt anyone.
            let box = Sandbox(); defer { box.destroy() }
            s.require(
                Inventory.isDeveloperStub(
                    box.root.appending(path: "usr/bin/vanished").path, systemRoot: box.root),
                "a system binary that could not be inspected would have been run")
            s.require(
                !Inventory.isDeveloperStub(
                    box.root.appending(path: "elsewhere/thing").path, systemRoot: box.root),
                "only the system directories are Apple's to stub")
        },
        Case("The git stub in /usr/bin is never what we run") { s in
            let box = Sandbox(); defer { box.destroy() }
            let stub = box.root.appending(path: "usr/bin/git")
            try executable(stub)
            s.require(InventoryStore.executable(systemRoot: box.root) == nil,
                      "the stub was mistaken for a usable git")
        },
    ])
}
