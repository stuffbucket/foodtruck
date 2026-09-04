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
        Case("Every builtin is housekeeping, and no recipe on disk is") { s in
            // The rule that keeps FoodTruck's plumbing off the user's list. If a
            // builtin ever becomes something a person should care about, it
            // needs a real name and a real reason, not a default.
            for recipe in builtins() {
                s.equal(recipe.scope, .housekeeping,
                        "\(recipe.id) would show up in the user's list")
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
            let kitchen = Kitchen(locations: box.locations, recipes: builtins(["core.locations"]))
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
            let kitchen = Kitchen(locations: box.locations, recipes: builtins())
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
            let kitchen = Kitchen(locations: box.locations, recipes: builtins(["core.locations"]))
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
            let kitchen = Kitchen(locations: box.locations, recipes: builtins(["core.locations"]))
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
            let kitchen = Kitchen(locations: box.locations, recipes: builtins(["core.locations"]))
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
                                  blastCeiling: .contained)
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
                                  blastCeiling: .contained)
            let service = await kitchen.inspect(.audit)
            s.equal(service.blocked.count, 0, "audit is never gated by blast radius")
        },
        Case("A recipe whose dependency is unmet waits instead of failing") { s in
            let box = Sandbox(); defer { box.destroy() }
            // core.toolbox.task requires core.locations, which is excluded here.
            let kitchen = Kitchen(locations: box.locations, recipes: builtins())
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
