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
        Case("A recipe can explain what converge will do") { s in
            let json = #"{"id":"x","name":"n","summary":"s","engine":"taskfile","convergeLabel":"action.x","convergeHelp":"action.x.help"}"#
            let recipe = try JSONDecoder().decode(Recipe.self, from: Data(json.utf8))
            s.equal(recipe.convergeLabel, "action.x", "button label survives decoding")
            s.equal(recipe.convergeHelp, "action.x.help", "action explanation survives decoding")
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
        Case("Finding sections round trip and remain backwards compatible") { s in
            let finding = Finding(
                id: "history", severity: .notice, title: "history",
                fixable: false, section: .history)
            let encoded = try JSONEncoder().encode(finding)
            let decoded = try JSONDecoder().decode(Finding.self, from: encoded)
            s.equal(decoded.section, .history, "the typed section did not round trip")

            let legacy = #"{"id":"legacy","severity":"notice","title":"legacy","args":{},"observed":null,"desired":null,"fixable":false,"remedy":null}"#
            let oldFinding = try JSONDecoder().decode(Finding.self, from: Data(legacy.utf8))
            s.require(oldFinding.section == nil,
                      "a report written before sections no longer decodes")
        },
        Case("Reports separate required action from observations") { s in
            let report = RecipeReport(findings: [
                Finding(id: "notice", severity: .notice, title: "notice"),
                Finding(id: "risk", severity: .risk, title: "risk", fixable: false),
                Finding(id: "ok", severity: .ok, title: "ok", fixable: false),
                Finding(id: "drift", severity: .drift, title: "drift"),
            ])
            s.equal(report.findingsRequiringAction.map(\.id), ["risk", "drift"],
                    "risk and drift require action, most urgent first")
            s.equal(report.observations.map(\.id), ["notice", "ok"],
                    "notice and ok remain optional context")
            s.equal(report.fixableActionFindings.map(\.id), ["drift"],
                    "only fixable action enables converge")
            s.require(report.requiresAction, "action findings make the report actionable")

            let noticeOnly = RecipeReport(findings: [
                Finding(id: "notice", severity: .notice, title: "notice")
            ])
            s.require(!noticeOnly.requiresAction, "a fixable notice is still not required work")
            s.require(noticeOnly.fixableActionFindings.isEmpty,
                      "a fixable notice must not enable converge")
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
        Case("Grouped shim conflicts interpolate in English and Spanish") { s in
            let args = [
                "tools": "node, npm", "manager": "mise",
                "shim": "~/.local/share/mise/shims", "direct": "/opt/homebrew/bin",
            ]
            for locale in ["en", "es"] {
                L10n.shared.configure(locales: [locale])
                let title = t("finding.inventory.shimShadowed", args)
                let remedy = t("finding.inventory.shimShadowed.remedy", args)
                for value in args.values {
                    s.require(title.contains(value), "\(locale): lost \(value) -> \(title)")
                }
                s.require(!title.contains("%{") && !remedy.contains("%{"),
                          "\(locale): unsubstituted placeholder")
                s.require(remedy.contains("PATH"), "\(locale): remedy lost the PATH decision")
            }
            L10n.shared.configure(locales: ["en"])
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
            s.equal(tn("detail.observations", 3), "3 observations", "observation count")
            s.equal(tn("summary.unmet", 1), "1 check did not pass", "unmet singular")
            s.equal(tn("summary.unmet", 3), "3 checks did not pass", "unmet plural")
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
            for key in ["detail.noAction", "detail.action", "detail.changeScope",
                        "detail.nextSteps", "detail.diagnostics", "detail.current",
                        "detail.expected", "detail.runLog"] {
                _ = t(key)
            }
            let inventoryArgs = [
                "tool": "example", "path": "~/bin/example", "origin": "homebrew",
                "version": "1.0", "before": "1.0", "after": "2.0", "paths": "~/bin",
            ]
            for key in [
                "value.unknown", "value.none", "value.notInstalled",
                "inventory.kind.shim", "inventory.kind.direct",
                "inventory.overview.clean", "inventory.overview.attention",
                "inventory.overview.programs", "inventory.overview.locations",
                "inventory.overview.managers", "inventory.changes.title",
                "inventory.changes.explanation", "inventory.history.title",
                "finding.inventory.firstObservation",
                "finding.inventory.host.changed", "finding.inventory.coverage.added",
                "finding.inventory.coverage.removed",
                "finding.inventory.coverage.reordered",
                "finding.inventory.managers.changed",
                "finding.inventory.program.added", "finding.inventory.program.removed",
                "finding.inventory.program.versionChanged",
                "finding.inventory.program.originChanged",
                "finding.inventory.program.targetChanged",
                "finding.inventory.program.kindChanged",
                "finding.inventory.program.replaced", "finding.inventory.recordFailed",
                "finding.inventory.recordFailed.remedy",
                "finding.inventory.probeRefused", "finding.inventory.probeRefused.remedy",
                "finding.inventory.snapshotUnreadable",
                "finding.inventory.snapshotUnreadable.remedy",
                "finding.inventory.historyFailed.remedy",
            ] {
                _ = t(key, inventoryArgs)
            }
            for origin in Origin.allCases { _ = t("inventory.origin.\(origin.rawValue)") }
            for key in ["detail.observations", "a11y.recipe.actions",
                        "inventory.worthKnowing"] {
                _ = tn(key, 2, ["name": "Recipe", "state": "Ready"])
            }
            for recipe in BuiltinEngine().descriptors {
                _ = t(recipe.name); _ = t(recipe.summary)
                if let label = recipe.convergeLabel { _ = t(label) }
                if let help = recipe.convergeHelp { _ = t(help) }
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
        let shims = box.root.appending(path: ".local/share/mise/shims")
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

    /// Load the same defaults shipped with the product, then resolve them
    /// against the sandbox rather than the machine running the self-test.
    private static func profile(
        _ box: Sandbox, environment suppliedEnvironment: [String: String]? = nil,
        home suppliedHome: URL? = nil, systemRoot suppliedSystemRoot: URL? = nil,
        configuring configure: (inout FoodTruckSettings) -> Void = { _ in }
    ) throws -> SettingsProfile {
        let sourceSeed = URL(filePath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: "Cookbook/recipes")
        let seed = Locations.resolved(environment: [:]).seed ?? sourceSeed
        let locations = Locations(root: box.root, seed: seed)
        let loaded = SettingsLoader.load(locations)
        guard var settings = loaded.settings else {
            if case .invalid(let failure) = loaded { throw failure }
            throw SettingsValidationError("bundled defaults are unavailable")
        }
        configure(&settings)
        return try SettingsProfile(
            settings: settings, home: suppliedHome ?? box.root,
            systemRoot: suppliedSystemRoot ?? box.root,
            environment: suppliedEnvironment ?? sealed(box))
    }

    private static func scan(_ box: Sandbox, _ roots: [URL] = []) throws -> Inventory {
        let profile = try profile(box) { settings in
            settings.inventory.discovery = InventoryDiscoverySettings()
        }
        return Inventory.scan(
            home: profile.home, locations: box.locations, settings: profile.inventory,
            systemRoot: profile.systemRoot, roots: roots)
    }

    private static func inventoryStore(
        _ box: Sandbox, profile supplied: SettingsProfile? = nil
    ) throws -> InventoryStore {
        let policy = try supplied ?? profile(box)
        return InventoryStore(
            root: box.locations.inventory, systemRoot: policy.systemRoot,
            gitCandidates: policy.inventory.gitCandidates)
    }

    /// Copy one configured, non-stub host Git into the same candidate path in
    /// the sealed machine. Tests can then exercise real history behavior
    /// without allowing InventoryStore to discover or execute outside its root.
    private static func installConfiguredGit(_ box: Sandbox) throws -> SettingsProfile? {
        let policy = try profile(box)
        let prefix = box.root.resolvingSymlinksInPath().standardizedFileURL.path + "/"
        let hostCandidates = policy.inventory.gitCandidates.compactMap { candidate -> URL? in
            let path = candidate.standardizedFileURL.path
            guard path.hasPrefix(prefix) else { return nil }
            return URL(filePath: "/" + String(path.dropFirst(prefix.count)))
        }
        let hostStore = InventoryStore(
            root: box.locations.inventory, systemRoot: URL(filePath: "/"),
            gitCandidates: hostCandidates)
        guard let source = hostStore.executable(),
              let offset = hostCandidates.firstIndex(of: source) else { return nil }
        let destination = policy.inventory.gitCandidates[offset]
        try fm.createDirectory(
            at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.copyItem(at: source, to: destination)
        return policy
    }

    private static func tool(_ inventory: Inventory, _ name: String) -> Installed? {
        inventory.tools.first { $0.name == name }
    }

    private static func writeJSON(_ value: Any, to url: URL) throws {
        try fm.createDirectory(at: url.deletingLastPathComponent(),
                               withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]).write(to: url)
    }

    private static func writePlist(_ value: [String: Any], to url: URL) throws {
        try fm.createDirectory(at: url.deletingLastPathComponent(),
                               withIntermediateDirectories: true)
        try PropertyListSerialization.data(
            fromPropertyList: value, format: .binary, options: 0).write(to: url)
    }

    private static func discoveryProfile(
        _ box: Sandbox, roots: [SoftwareDiscoveryRoot],
        exclusions: [SettingsPathSource] = []
    ) throws -> SettingsProfile {
        try profile(box) { settings in
            settings.inventory.discovery = InventoryDiscoverySettings(
                roots: roots, exclusions: exclusions)
        }
    }

    static let suite = Suite("inventory", [

        // MARK: software discovery

        Case("Software discovery identifies packages apps and footprints without running them") { s in
            let box = Sandbox(); defer { box.destroy() }
            let prefix = box.root.appending(path: "opt/homebrew")
            try fm.createDirectory(
                at: prefix.appending(path: "Library/Homebrew"),
                withIntermediateDirectories: true)

            let formula = prefix.appending(path: "Cellar/alpha")
            for version in ["1.2.3", "1.2.3_1"] {
                let keg = formula.appending(path: version)
                try writeJSON([
                    "source": ["spec": "stable", "versions": ["stable": "1.2.3"]]
                ], to: keg.appending(path: "INSTALL_RECEIPT.json"))
                let ruby = keg.appending(path: ".brew/alpha.rb")
                try fm.createDirectory(
                    at: ruby.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Data().write(to: ruby)
            }
            let fake = prefix.appending(path: "Cellar/fake/9.9")
            try writeJSON([:], to: fake.appending(path: "INSTALL_RECEIPT.json"))
            let fakeRuby = fake.appending(path: ".brew/fake.rb")
            try fm.createDirectory(
                at: fakeRuby.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data().write(to: fakeRuby)

            let cask = prefix.appending(path: "Caskroom/useful/latest")
            try writeJSON(["source": ["version": "latest"]],
                          to: cask.appending(path: ".metadata/INSTALL_RECEIPT.json"))
            try fm.createDirectory(
                at: cask.appending(path: ".metadata/latest"),
                withIntermediateDirectories: true)
            try fm.createDirectory(
                at: prefix.appending(path: "Caskroom/incomplete/2.0"),
                withIntermediateDirectories: true)

            let applications = box.root.appending(path: "Applications")
            try writePlist([
                "CFBundleIdentifier": "example.useful",
                "CFBundleDisplayName": "Useful App",
                "CFBundleShortVersionString": "3.4",
                "CFBundleVersion": "56",
            ], to: applications.appending(path: "Useful.app/Contents/Info.plist"))
            let malformed = applications.appending(path: "Broken.app/Contents/Info.plist")
            try fm.createDirectory(
                at: malformed.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("not a plist".utf8).write(to: malformed)

            let config = box.root.appending(path: ".config")
            try fm.createDirectory(
                at: config.appending(path: "durable"), withIntermediateDirectories: true)
            try fm.createDirectory(
                at: config.appending(path: "foodtruck"), withIntermediateDirectories: true)
            let witness = box.root.appending(path: "discovery-executed")
            try executable(
                config.appending(path: "durable/run-me"),
                printing: "touch '\(witness.path)'")

            let policy = try discoveryProfile(box, roots: [
                SoftwareDiscoveryRoot(
                    source: SettingsPathSource(literal: "/opt/homebrew/Cellar"),
                    strategy: .homebrewCellar),
                SoftwareDiscoveryRoot(
                    source: SettingsPathSource(literal: "/opt/homebrew/Caskroom"),
                    strategy: .homebrewCaskroom),
                SoftwareDiscoveryRoot(
                    source: SettingsPathSource(literal: "/Applications"),
                    strategy: .applicationBundles),
                SoftwareDiscoveryRoot(
                    source: SettingsPathSource(literal: "~/.config"),
                    strategy: .topLevelFootprints, exclusions: ["foodtruck"]),
            ])
            let inventory = Inventory.scan(
                home: policy.home, locations: box.locations, settings: policy.inventory,
                systemRoot: policy.systemRoot, roots: [])

            s.require(!inventory.softwareDiscoveryRefused,
                      "valid bounded software discovery was refused")
            s.equal(inventory.softwareRoots.count, 4, "successful coverage was not recorded")
            s.equal(inventory.software.count, 4,
                    "invalid or excluded artifacts leaked into software inventory")
            guard let alpha = inventory.software.first(where: { $0.name == "alpha" }),
                  let useful = inventory.software.first(where: { $0.name == "useful" }),
                  let app = inventory.software.first(where: { $0.name == "Useful App" }),
                  let footprint = inventory.software.first(where: { $0.name == "durable" })
            else {
                s.require(false, "expected artifacts missing: \(inventory.software.map(\.name))")
                return
            }
            s.equal(alpha.kind, .formula, "Cellar package was not a formula")
            s.equal(alpha.versions, ["1.2.3", "1.2.3_1"],
                    "formula versions were not grouped")
            s.equal(useful.kind, .cask, "Caskroom package was not a cask")
            s.equal(useful.versions, ["latest"], "nonnumeric cask version was rejected")
            s.equal(app.identifier, "example.useful", "bundle identifier was not read")
            s.equal(app.versions, ["3.4", "56"], "bundle versions were not read")
            s.equal(footprint.kind, .footprint, "configuration directory became a package")
            s.require(inventory.tools.isEmpty && inventory.unmanaged.isEmpty,
                      "software artifacts polluted executable inventory")
            s.require(!fm.fileExists(atPath: witness.path),
                      "software discovery executed a discovered file")
        },
        Case("Software discovery rejects protected roots and escaping metadata") { s in
            let box = Sandbox(); defer { box.destroy() }
            let ssh = box.root.appending(path: ".ssh")
            try fm.createDirectory(at: ssh.appending(path: "private"),
                                   withIntermediateDirectories: true)
            let protectedPolicy = try discoveryProfile(box, roots: [
                SoftwareDiscoveryRoot(
                    source: SettingsPathSource(literal: "~/.ssh"),
                    strategy: .topLevelFootprints),
            ])
            let protected = Inventory.discoverSoftware(
                home: protectedPolicy.home, settings: protectedPolicy.inventory,
                systemRoot: protectedPolicy.systemRoot)
            s.require(protected.refused, "a compiled protected root was accepted")
            s.require(protected.artifacts.isEmpty && protected.roots.isEmpty,
                      "protected discovery produced a partial snapshot")

            let loop = box.root.appending(path: "exclusion-loop")
            try fm.createSymbolicLink(atPath: loop.path, withDestinationPath: "exclusion-loop")
            let invalidGate = DiscoverySafetyGate(
                home: box.root, systemRoot: box.root,
                configuredExclusions: [loop])
            s.require(!invalidGate.isValid,
                      "an unresolvable exclusion was dropped instead of failing closed")

            let applications = box.root.appending(path: "Applications")
            let outside = box.root.appending(path: "outside")
            try writePlist([
                "CFBundleIdentifier": "example.escape", "CFBundleName": "Escape"
            ], to: outside.appending(path: "Escape.app/Contents/Info.plist"))
            try fm.createDirectory(at: applications, withIntermediateDirectories: true)
            try fm.createSymbolicLink(
                at: applications.appending(path: "Escape.app"),
                withDestinationURL: outside.appending(path: "Escape.app"))

            let linked = applications.appending(path: "Linked.app/Contents")
            try fm.createDirectory(at: linked, withIntermediateDirectories: true)
            try fm.createSymbolicLink(
                at: linked.appending(path: "Info.plist"),
                withDestinationURL: outside.appending(path: "Escape.app/Contents/Info.plist"))
            let appPolicy = try discoveryProfile(box, roots: [
                SoftwareDiscoveryRoot(
                    source: SettingsPathSource(literal: "/Applications"),
                    strategy: .applicationBundles),
            ])
            let apps = Inventory.discoverSoftware(
                home: appPolicy.home, settings: appPolicy.inventory,
                systemRoot: appPolicy.systemRoot)
            s.require(!apps.refused, "unsafe entries invalidated otherwise complete coverage")
            s.require(apps.artifacts.isEmpty, "a symlink escaped its configured discovery root")
            s.equal(apps.roots.count, 1, "safe root coverage was lost")
        },
        Case("Every compiled software discovery ceiling refuses partial results") { s in
            let box = Sandbox(); defer { box.destroy() }
            let root = box.root.appending(path: "footprints")
            try fm.createDirectory(at: root.appending(path: "one"),
                                   withIntermediateDirectories: true)
            try fm.createDirectory(at: root.appending(path: "two"),
                                   withIntermediateDirectories: true)
            let policy = try discoveryProfile(box, roots: [
                SoftwareDiscoveryRoot(
                    source: SettingsPathSource(literal: "/footprints"),
                    strategy: .topLevelFootprints),
            ])

            let rootLimit = Inventory.discoverSoftware(
                home: policy.home, settings: policy.inventory,
                systemRoot: policy.systemRoot,
                limits: DiscoveryLimits(roots: 0))
            s.require(rootLimit.refused && rootLimit.artifacts.isEmpty,
                      "root ceiling returned partial results")

            let entryLimit = Inventory.discoverSoftware(
                home: policy.home, settings: policy.inventory,
                systemRoot: policy.systemRoot,
                limits: DiscoveryLimits(entriesPerRoot: 1))
            s.require(entryLimit.refused && entryLimit.artifacts.isEmpty,
                      "entry ceiling returned partial results")

            let artifactLimit = Inventory.discoverSoftware(
                home: policy.home, settings: policy.inventory,
                systemRoot: policy.systemRoot,
                limits: DiscoveryLimits(artifacts: 1))
            s.require(artifactLimit.refused && artifactLimit.artifacts.isEmpty,
                      "artifact ceiling returned partial results")

            let applications = box.root.appending(path: "Applications")
            try writePlist(["CFBundleName": "Large"],
                           to: applications.appending(path: "Large.app/Contents/Info.plist"))
            let appPolicy = try discoveryProfile(box, roots: [
                SoftwareDiscoveryRoot(
                    source: SettingsPathSource(literal: "/Applications"),
                    strategy: .applicationBundles),
            ])
            let fileLimit = Inventory.discoverSoftware(
                home: appPolicy.home, settings: appPolicy.inventory,
                systemRoot: appPolicy.systemRoot,
                limits: DiscoveryLimits(metadataFileBytes: 1))
            s.require(fileLimit.refused && fileLimit.artifacts.isEmpty,
                      "metadata-file ceiling returned partial results")
            let totalLimit = Inventory.discoverSoftware(
                home: appPolicy.home, settings: appPolicy.inventory,
                systemRoot: appPolicy.systemRoot,
                limits: DiscoveryLimits(metadataFileBytes: 1_048_576,
                                        metadataTotalBytes: 1))
            s.require(totalLimit.refused && totalLimit.artifacts.isEmpty,
                      "metadata-total ceiling returned partial results")
        },

        Case("Software deltas compare only common strategy coverage") { s in
            let host = Host(
                product: "macOS", version: "1", build: "1", arch: "arm64",
                kernel: "1", commandLineTools: nil)
            let cellar = SoftwareDiscoveryCoverage(
                path: "/opt/homebrew/Cellar", strategy: .homebrewCellar)
            let apps = SoftwareDiscoveryCoverage(
                path: "/Applications", strategy: .applicationBundles)
            let alpha1 = SoftwareArtifact(
                kind: .formula, name: "alpha", path: "/opt/homebrew/Cellar/alpha",
                versions: ["1.0"], provider: .homebrew, evidence: .homebrewReceipt)
            let alpha2 = SoftwareArtifact(
                kind: .formula, name: "alpha", path: "/opt/homebrew/Cellar/alpha",
                versions: ["2.0"], provider: .homebrew, evidence: .homebrewReceipt)
            let beta = SoftwareArtifact(
                kind: .formula, name: "beta", path: "/opt/homebrew/Cellar/beta",
                versions: ["1.0"], provider: .homebrew, evidence: .homebrewReceipt)
            let oldApp = SoftwareArtifact(
                kind: .application, name: "Old", path: "/Applications/Old.app",
                evidence: .bundleInfoPlist)

            let first = Inventory(host: host, roots: [], tools: [])
            let introduced = Inventory(
                host: host, roots: [], tools: [], software: [alpha1, oldApp],
                softwareRoots: [cellar, apps])
            let migration = InventoryDelta(previous: first, current: introduced)
            s.equal(migration.addedSoftwareRoots.count, 2,
                    "new software coverage was not recorded")
            s.require(migration.addedSoftware.isEmpty,
                      "first v2 coverage became a wall of package additions")

            let current = Inventory(
                host: host, roots: [], tools: [], software: [alpha2, beta],
                softwareRoots: [cellar, apps])
            let delta = InventoryDelta(previous: introduced, current: current)
            s.equal(delta.modifiedSoftware.map(\.after.name), ["alpha"],
                    "version change was not tied to stable package identity")
            s.equal(delta.addedSoftware.map(\.name), ["beta"],
                    "new package under common coverage was missed")
            s.equal(delta.removedSoftware.map(\.name), ["Old"],
                    "removed app under common coverage was missed")

            let strategyChanged = Inventory(
                host: host, roots: [], tools: [], software: [],
                softwareRoots: [SoftwareDiscoveryCoverage(
                    path: "/Applications", strategy: .topLevelFootprints)])
            let coverageDelta = InventoryDelta(previous: introduced, current: strategyChanged)
            s.equal(coverageDelta.addedSoftwareRoots.count, 1,
                    "strategy change did not add new coverage")
            s.equal(coverageDelta.removedSoftwareRoots.count, 2,
                    "strategy change did not remove prior coverage")
            s.require(coverageDelta.removedSoftware.isEmpty,
                      "strategy change fabricated software removals")
        },
        Case("Software history text is stable and incomplete scans cannot be written") { s in
            let box = Sandbox(); defer { box.destroy() }
            let host = Host(
                product: "macOS", version: "1", build: "1", arch: "arm64",
                kernel: "1", commandLineTools: nil)
            var inventory = Inventory(
                host: host, roots: [], tools: [], software: [
                    SoftwareArtifact(
                        kind: .footprint, name: "zeta", path: "~/.config/zeta",
                        evidence: .directoryEntry),
                    SoftwareArtifact(
                        kind: .application, name: "Alpha", path: "/Applications/Alpha.app",
                        identifier: "example.alpha", versions: ["2", "1"],
                        evidence: .bundleInfoPlist),
                ], softwareRoots: [
                    SoftwareDiscoveryCoverage(
                        path: "~/.config", strategy: .topLevelFootprints),
                    SoftwareDiscoveryCoverage(
                        path: "/Applications", strategy: .applicationBundles),
                ])
            let text = inventory.text
            guard let apps = text.range(of: "applicationBundles  /Applications"),
                  let footprints = text.range(of: "topLevelFootprints  ~/.config"),
                  let software = text.range(of: "software:"),
                  let searched = text.range(of: "software searched:") else {
                s.require(false, "software history sections were missing"); return
            }
            s.require(software.lowerBound < searched.lowerBound,
                      "software coverage appeared before its artifacts")
            s.require(apps.lowerBound < footprints.lowerBound,
                      "software coverage was not sorted deterministically")

            inventory.softwareDiscoveryRefused = true
            let store = try inventoryStore(box)
            do {
                try store.write(inventory)
                s.require(false, "an incomplete software observation was recorded")
            } catch InventoryStore.WriteError.incompleteObservation {
                s.require(!fm.fileExists(atPath: store.recordURL.path),
                          "refused write left a partial snapshot")
            }
        },

        // MARK: attribution

        Case("A Homebrew prefix is recognised by what it contains, not what it is called") { s in
            let box = Sandbox(); defer { box.destroy() }
            let inventory = try scan(box, try fixture(box))
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
        Case("A Cellar-shaped path is not proof of Homebrew") { s in
            let box = Sandbox(); defer { box.destroy() }
            let fakeBin = box.root.appending(path: ".local/Cellar/example/1.2.3/bin")
            try executable(fakeBin.appending(path: "example"))

            let inventory = try scan(box, [fakeBin])
            guard let example = tool(inventory, "example") else {
                s.require(false, "fixture missing example"); return
            }
            s.equal(example.origin, Origin.unmanaged,
                    "an unrelated Cellar directory was attributed to Homebrew")
        },
        Case("Following a shim's link describes the manager, never the tool") { s in
            // Regression, and the subtlest thing here. The shim points at mise,
            // mise is itself a Cellar symlink, so resolving the whole chain
            // reports `node` as installed by Homebrew at mise's version. Both
            // wrong, and wrong in the confident way.
            let box = Sandbox(); defer { box.destroy() }
            let inventory = try scan(box, try fixture(box))
            guard let shim = inventory.tools.first(where: { $0.name == "node" && $0.shim })
            else { s.require(false, "fixture missing the node shim"); return }
            s.equal(shim.origin, Origin.mise, "the shim was credited to mise's own installer")
            s.require(shim.version == nil, "mise's version was attached to node")
        },
        Case("The scan alone runs nothing, and says so about what it reports") { s in
            let box = Sandbox(); defer { box.destroy() }
            let inventory = try scan(box, try fixture(box))
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
            let scanned = try scan(box, try fixture(box))
            guard let inferred = tool(scanned, "jq") else {
                s.require(false, "fixture missing jq"); return
            }
            s.equal(inferred.version, "9.9.9", "the path claims 9.9.9")
            s.equal(inferred.versionSource, VersionSource.inferred, "and only claims it")

            let policy = try profile(box)
            let probed = await scanned.probingVersions(
                home: policy.home, environment: sealed(box), settings: policy.inventory,
                systemRoot: policy.systemRoot)
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
            let scanned = try scan(box, try fixture(box))
            guard let shim = scanned.tools.first(where: { $0.name == "node" && $0.shim })
            else { s.require(false, "fixture missing the node shim"); return }
            let policy = try profile(box)
            s.require(scanned.probeTarget(
                for: shim, eligibleNames: Set(policy.inventory.probes.names),
                home: policy.home.path, systemRoot: policy.systemRoot,
                developerDirectory: nil) == nil,
                      "the shim would have been run")
        },
        Case("Only declared tools are run, wherever they happen to live") { s in
            let box = Sandbox(); defer { box.destroy() }
            let policy = try profile(box)
            let probed = await (try scan(box, try fixture(box))).probingVersions(
                home: policy.home, environment: sealed(box), settings: policy.inventory,
                systemRoot: policy.systemRoot)
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
            let jq = box.root.appending(path: ".local/bin/jq")
            try executable(jq, printing: "jq-1.7.1")

            let inventory = Inventory(
                host: Inventory.host(systemRoot: box.root), roots: [],
                tools: [Installed(name: "git", path: usrbin.appending(path: "git").path,
                                  origin: .apple),
                        Installed(name: "cmpdylib",
                                  path: usrbin.appending(path: "cmpdylib").path,
                                  origin: .apple),
                        Installed(name: "jq", path: "~/.local/bin/jq", origin: .unmanaged)])
            let policy = try profile(box)
            let eligibleNames = Set(policy.inventory.probes.names)
            func target(_ name: String) -> String? {
                guard let tool = inventory.tools.first(where: { $0.name == name })
                else { return nil }
                return inventory.probeTarget(
                    for: tool, eligibleNames: eligibleNames, home: policy.home.path,
                    systemRoot: policy.systemRoot, developerDirectory: developer.path)
            }
            s.equal(target("git"), try CanonicalPath.resolve(
                developer.appending(path: "usr/bin/git")).path,
                    "the stub should resolve to the tool behind it, not run itself")
            s.require(target("cmpdylib") == nil,
                      "a stub with nothing behind it was going to be run")
            s.equal(target("jq"), try CanonicalPath.resolve(jq).path,
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
            let policy = try profile(box)
            let result = await flooded.probingVersions(
                home: policy.home, environment: sealed(box), settings: policy.inventory,
                systemRoot: policy.systemRoot)
            s.require(result.probeRefused, "the flood was not refused")
            s.require(result.tools.allSatisfy { $0.versionSource != .probed },
                      "something was run despite the refusal")
        },

        Case("Tool and directory-manager requests share one ceiling after cache hits") { s in
            let box = Sandbox(); defer { box.destroy() }
            let toolURL = box.root.appending(path: "tools/jq")
            try executable(toolURL, printing: "jq-1.7.1")

            var declarations: [ManagerDeclaration] = []
            var managers: [Manager] = []
            for index in 0..<Inventory.probeCeiling {
                let id = "manager\(index)"
                let relative = "managers/\(id)"
                let directory = box.root.appending(path: relative)
                try executable(directory.appending(path: "bin/manager"), printing: "1.0.0")
                declarations.append(ManagerDeclaration(
                    id: id, binaries: ["manager"],
                    directories: [SettingsPathSource(literal: "~/\(relative)")],
                    manages: ["node"]))
                managers.append(Manager(
                    id: id, evidence: "~/\(relative)", manages: ["node"]))
            }
            let policy = try profile(box) { settings in
                settings.inventory.probes.names = ["jq"]
                settings.inventory.managers = declarations
            }
            for index in managers.indices {
                managers[index].evidence = Inventory.abbreviate(
                    policy.inventory.managers[index].directories[0].path,
                    home: policy.home.path)
            }
            let inventory = Inventory(
                host: Inventory.host(systemRoot: box.root), roots: [],
                tools: [Installed(name: "jq", path: toolURL.path, origin: .unmanaged)],
                managers: managers)
            let refused = await inventory.probingVersions(
                home: policy.home, environment: sealed(box), settings: policy.inventory,
                systemRoot: policy.systemRoot)
            s.require(refused.probeRefused,
                      "manager requests were not counted with the scanned tool")
            s.require(refused.tools.first?.versionSource != .probed,
                      "the tool ran before the combined batch was refused")
            s.require(refused.managers.allSatisfy { $0.version == nil },
                      "a directory-only manager ran before the batch was refused")

            var cachedManagers = managers
            for index in cachedManagers.indices {
                cachedManagers[index].version = "0.9.0"
                let executable = policy.inventory.managers[index].directories[0]
                    .appending(path: "bin/manager").path
                cachedManagers[index].stamp = Inventory.stamp(of: executable)
            }
            let previous = Inventory(
                host: inventory.host, roots: [], tools: [], managers: cachedManagers)
            let cached = await inventory.probingVersions(
                home: policy.home, environment: sealed(box), settings: policy.inventory,
                systemRoot: policy.systemRoot, reusing: previous)
            s.require(!cached.probeRefused,
                      "cached manager hits were counted as uncached work")
            s.equal(cached.tools.first?.version, "1.7.1",
                    "the remaining uncached tool was not probed")
            s.require(cached.managers.allSatisfy { $0.version == "0.9.0" },
                      "cached directory-manager versions were not reused")
        },
        Case("A directory-only manager passes through the developer-stub gate") { s in
            let box = Sandbox(); defer { box.destroy() }
            let candidate = box.root.appending(path: "bin/git")
            let markerURL = box.root.appending(path: "manager-ran")
            try fm.createDirectory(at: candidate.deletingLastPathComponent(),
                                   withIntermediateDirectories: true)
            try Data("#!/bin/sh\ntouch '\(markerURL.path)'\necho 1.0.0\n".utf8)
                .write(to: candidate)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: candidate.path)
            try fm.linkItem(at: candidate, to: box.root.appending(path: "bin/stub-peer"))
            let policy = try profile(box) { settings in
                settings.inventory.managers = [ManagerDeclaration(
                    id: "sealed-manager", binaries: ["git"],
                    directories: [SettingsPathSource(literal: "/")],
                    manages: ["node"])]
            }
            let evidence = Inventory.abbreviate(
                policy.inventory.managers[0].directories[0].path, home: policy.home.path)
            let inventory = Inventory(
                host: Inventory.host(systemRoot: box.root), roots: [], tools: [],
                managers: [Manager(
                    id: "sealed-manager", evidence: evidence, manages: ["node"])])
            let result = await inventory.probingVersions(
                home: policy.home, environment: sealed(box), settings: policy.inventory,
                systemRoot: policy.systemRoot)
            s.require(result.managers.first?.version == nil,
                      "a directory-only Apple-style stub was probed")
            s.require(!fm.fileExists(atPath: markerURL.path),
                      "the refused manager executable actually ran")
        },

        Case("Replacing managers cannot turn an inherited shim into a probe target") { s in
            let box = Sandbox(); defer { box.destroy() }
            let shim = box.root.appending(path: ".local/share/mise/shims/node")
            let marker = box.root.appending(path: "shim-ran")
            try fm.createDirectory(
                at: shim.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("#!/bin/sh\ntouch '\(marker.path)'\necho 9.9.9\n".utf8).write(to: shim)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: shim.path)
            let policy = try profile(box) { settings in
                settings.inventory.scan.declarations = []
                settings.inventory.managers = []
                settings.inventory.origins = []
                settings.inventory.probes.names = ["node"]
            }
            let scanned = Inventory.scan(
                home: policy.home, locations: box.locations, settings: policy.inventory,
                systemRoot: policy.systemRoot)
            guard let node = scanned.tools.first(where: { $0.name == "node" }) else {
                s.require(false, "the inherited shim source was not scanned"); return
            }
            s.require(node.shim, "replacing managers erased scan-source shim safety")
            s.equal(node.origin, Origin.unmanaged,
                    "an unclaimed inherited shim was assigned to a removed manager")
            let probed = await scanned.probingVersions(
                home: policy.home, environment: sealed(box), settings: policy.inventory,
                systemRoot: policy.systemRoot)
            s.require(probed.tools.first?.version == nil,
                      "the inherited shim supplied a version")
            s.require(!fm.fileExists(atPath: marker.path),
                      "the inherited shim was executed after managers were replaced")
        },
        Case("A directory-manager symlink cannot escape the sealed system") { s in
            let box = Sandbox(); defer { box.destroy() }
            let outside = URL(filePath: NSTemporaryDirectory())
                .appending(path: "foodtruck-manager-outside-\(UUID().uuidString)")
            defer { try? fm.removeItem(at: outside) }
            let markerURL = box.root.appending(path: "escaped-manager-ran")
            try executable(outside, printing: "9.9.9")
            // Replace the simple banner with an observable side effect. If the
            // target escapes the gate, this marker proves it executed.
            try Data("#!/bin/sh\ntouch '\(markerURL.path)'\necho 9.9.9\n".utf8)
                .write(to: outside)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: outside.path)
            let directory = box.root.appending(path: "escaped-manager")
            let candidate = directory.appending(path: "bin/manager")
            try fm.createDirectory(at: candidate.deletingLastPathComponent(),
                                   withIntermediateDirectories: true)
            try fm.createSymbolicLink(at: candidate, withDestinationURL: outside)
            let policy = try profile(box) { settings in
                settings.inventory.managers = [ManagerDeclaration(
                    id: "escaped-manager", binaries: ["manager"],
                    directories: [SettingsPathSource(literal: "~/escaped-manager")],
                    manages: ["node"])]
            }
            let evidence = Inventory.abbreviate(
                policy.inventory.managers[0].directories[0].path, home: policy.home.path)
            let inventory = Inventory(
                host: Inventory.host(systemRoot: box.root), roots: [], tools: [],
                managers: [Manager(
                    id: "escaped-manager", evidence: evidence, manages: ["node"])])
            let result = await inventory.probingVersions(
                home: policy.home, environment: sealed(box), settings: policy.inventory,
                systemRoot: policy.systemRoot)
            s.require(result.managers.first?.version == nil,
                      "the outside manager supplied a version")
            s.require(!fm.fileExists(atPath: markerURL.path),
                      "a manager symlink escaped the sealed system and executed")
        },

        // MARK: more than one copy

        Case("A shim beside a real install is named, not folded into a count") { s in
            // The most consequential thing here, and invisible to every other
            // check: both are on PATH, the shim has no version to compare, and
            // two lines in a shell startup file decide which one you get.
            let box = Sandbox(); defer { box.destroy() }
            let inventory = try scan(box, try fixture(box))
            guard let copies = inventory.shadowedShims["node"] else {
                s.require(false, "the shadowed node was not reported"); return
            }
            s.equal(copies.count, 2, "both copies listed")
            s.require(copies.contains(where: \.shim) && copies.contains(where: { !$0.shim }),
                      "one of each")
        },
        Case("Shim conflicts are grouped by the two directories involved") { s in
            let box = Sandbox(); defer { box.destroy() }
            let inventory = Inventory(
                host: Inventory.host(systemRoot: box.root),
                roots: ["~/.local/share/mise/shims", "~/opt/homebrew/bin",
                        "~/.asdf/shims", "/"],
                tools: [
                    Installed(name: "pnpx", path: "~/.local/share/mise/shims/pnpx",
                              origin: .mise, shim: true),
                    Installed(name: "pnpx", path: "~/opt/homebrew/bin/pnpx",
                              origin: .homebrew),
                    Installed(name: "node", path: "~/.local/share/mise/shims/node",
                              origin: .mise, shim: true),
                    Installed(name: "node", path: "~/opt/homebrew/bin/node",
                              origin: .homebrew),
                    Installed(name: "npm", path: "~/.local/share/mise/shims/npm",
                              origin: .mise, shim: true),
                    Installed(name: "npm", path: "~/opt/homebrew/bin/npm",
                              origin: .homebrew),
                    Installed(name: "python", path: "~/.asdf/shims/python",
                              origin: .asdf, shim: true),
                    Installed(name: "python", path: "/python", origin: .apple),
                ])

            let groups = inventory.shimShadowGroups
            s.equal(groups.count, 2, "distinct directory decisions were merged")
            guard let mise = groups.first(where: {
                $0.shimDirectory == "~/.local/share/mise/shims"
            }) else { s.require(false, "the mise group is missing"); return }
            s.equal(mise.commands, ["node", "npm", "pnpx"],
                    "commands were not sorted into one group")
            s.equal(mise.directDirectory, "~/opt/homebrew/bin", "wrong direct directory")
            s.equal(mise.manager, .mise, "wrong manager")

            guard let root = groups.first(where: { $0.shimDirectory == "~/.asdf/shims" })
            else { s.require(false, "the distinct asdf group is missing"); return }
            s.equal(root.commands, ["python"], "wrong commands in the second group")
            s.equal(root.directDirectory, "/", "a root-level executable lost its directory")
        },
        Case("One directory conflict produces one actionable finding") { s in
            let box = Sandbox(); defer { box.destroy() }
            let brewBin = box.root.appending(path: "opt/homebrew/bin")
            let localBin = box.root.appending(path: "usr/local/bin")
            let miseShims = box.root.appending(path: ".local/share/mise/shims")
            let asdfShims = box.root.appending(path: ".asdf/shims")

            // The command family all asks for the same directory-level choice.
            // Deliberately create it out of name order so the output must sort.
            for name in ["pnpx", "node", "npm", "npx", "pnpm"] {
                try executable(miseShims.appending(path: name))
                try executable(brewBin.appending(path: name))
            }
            // These extra node copies prove that the first shim and direct
            // install still follow search order rather than alphabetic paths.
            try executable(asdfShims.appending(path: "node"))
            try executable(localBin.appending(path: "node"))
            // A genuinely harmless duplicate remains in the informational count.
            try executable(brewBin.appending(path: "gh"))
            try executable(localBin.appending(path: "gh"))

            let kitchen = Kitchen(locations: box.locations,
                                  recipes: builtins(["env.inventory"]),
                                  profile: try profile(box),
                                  environment: sealed(box))
            let service = await kitchen.inspect(.audit)
            let findings = service.results.flatMap { $0.report.findings }
            let shadows = findings.filter { $0.id.hasPrefix("inventory.shimShadowed:") }
            s.equal(shadows.count, 1, "one PATH decision became several findings")
            guard let shadow = shadows.first else { return }
            s.equal(shadow.id,
                    "inventory.shimShadowed:~/.local/share/mise/shims->~/opt/homebrew/bin",
                    "the grouped finding ID is not stable")
            s.equal(shadow.args["tools"], "node, npm, npx, pnpm, pnpx",
                    "the command family was not listed in stable order")
            s.equal(shadow.args["manager"], "mise", "the wrong manager was blamed")
            s.equal(shadow.args["shim"], "~/.local/share/mise/shims",
                    "the shim directory is not the one searched first")
            s.equal(shadow.args["direct"], "~/opt/homebrew/bin",
                    "the install directory is not the one searched first")
            s.require(shadow.observed == nil && shadow.desired == nil,
                      "a directory choice was presented as found versus requested")
            s.require(!shadow.fixable, "FoodTruck offered to make the PATH decision")
            s.equal(shadow.remedy, "finding.inventory.shimShadowed.remedy",
                    "the grouped finding lost its next step")
            s.equal(shadow.section, .attention,
                    "the grouped shim decision was not assigned to attention")

            guard let duplicate = findings.first(where: { $0.id == "inventory.duplicated" })
            else { s.require(false, "the unrelated duplicate was lost"); return }
            s.equal(duplicate.args["count"], "1",
                    "shim-shadowed commands were also counted as harmless duplicates")
        },
        Case("A copy with no known version is not evidence of a conflict") { s in
            // "I could not tell" must not become "these differ". The shim has
            // no version by construction, so counting it as different would
            // report a conflict on every managed tool on the machine.
            let box = Sandbox(); defer { box.destroy() }
            let inventory = try scan(box, try fixture(box))
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
            func evidence(_ roots: [URL]) throws -> String? {
                (try scan(box, roots)).managers.first { $0.id == "mise" }?.evidence
            }
            s.equal(try evidence([localBin, brewBin]), "~/.local/bin/mise",
                    "the earliest searched copy should be the one quoted")
            // The same two files, searched the other way round. If the answer
            // does not move, the order is not being consulted at all.
            s.equal(try evidence([brewBin, localBin]), "~/opt/homebrew/bin/mise",
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
            guard let nvm = try scan(box).managers.first(where: { $0.id == "nvm" }) else {
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
            let contested = try scan(box).contested
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
            s.require(!(try scan(box, [bin])).managers.contains { $0.id == "pnpm" },
                      "pnpm counted as a node manager on presence alone")

            let evidence = box.root.appending(path: "Library/pnpm/nodejs")
            try executable(evidence)
            s.require(!(try scan(box, [bin])).managers.contains { $0.id == "pnpm" },
                      "a file was accepted as manager role evidence")
            try fm.removeItem(at: evidence)
            try fm.createDirectory(at: evidence, withIntermediateDirectories: true)
            s.require(try scan(box, [bin]).managers.contains { $0.id == "pnpm" },
                      "pnpm is managing node here and was not counted")
        },

        Case("One copy of each is not a duplicate, a conflict, or a shadow") { s in
            // The quiet direction, and the one nothing was checking. Every
            // "more than one" test here proves the report fires; none proved it
            // stays silent. Relaxing `count > 1` to `count >= 1` turns each of
            // these three into a warning about every tool on the machine --
            // 1,357 of them on a real Mac -- and the suite had nothing to say.
            let box = Sandbox(); defer { box.destroy() }
            let bin = box.root.appending(path: "opt/homebrew/bin")
            for name in ["gh", "jq", "node", "mise"] {
                try executable(bin.appending(path: name))
            }
            let inventory = try scan(box, [bin])
            s.equal(inventory.tools.count, 4, "fixture")
            s.require(inventory.duplicated.isEmpty,
                      "a single copy was reported as installed more than once")
            s.require(inventory.conflictingVersions.isEmpty,
                      "one copy was reported as disagreeing with itself")
            s.require(inventory.shadowedShims.isEmpty,
                      "a tool with no shim was reported as shadowed")
            // Without a manager the contested check proves nothing either way,
            // so mise is present and is the only one.
            s.equal(inventory.managers.map(\.id), ["mise"], "mise should be the one manager")
            s.require(inventory.contested.isEmpty,
                      "a runtime with one manager was reported as contested")
        },
        Case("On a machine with nothing wrong, every check says so") { s in
            // A check reports whether something held. Invert one and FoodTruck
            // says "verified" about the thing it just found wrong, which is
            // worse than not checking -- and every `passed:` in the recipe
            // could be inverted without a test objecting.
            let box = Sandbox(); defer { box.destroy() }
            let brew = box.root.appending(path: "opt/homebrew")
            try fm.createDirectory(at: brew.appending(path: "Library/Homebrew"),
                                   withIntermediateDirectories: true)
            try fm.createDirectory(at: brew.appending(path: "Cellar"),
                                   withIntermediateDirectories: true)
            // Inside a Homebrew prefix, so nothing is unaccounted for; one
            // manager, so the contested check has something to be about.
            for name in ["gh", "jq", "mise"] {
                try executable(brew.appending(path: "bin/\(name)"), printing: "1.0.0")
            }
            // A shim with nothing beside it to shadow. Without one the shim
            // check passes because it was asked nothing, which is the vacuous
            // pass this project exists to object to -- so a clean machine has
            // to be one where all six checks actually had something to prove.
            try executable(box.root.appending(path: ".local/share/mise/shims/python"))

            let kitchen = Kitchen(locations: box.locations,
                                  recipes: builtins(["core.locations", "env.inventory"]),
                                  profile: try profile(box),
                                  environment: sealed(box))
            _ = try await kitchen.converge()
            let service = await kitchen.inspect(.audit)
            guard let result = service.results.first(where: { $0.recipe == "env.inventory" })
            else { s.require(false, "the inventory recipe did not report"); return }

            s.require(!result.report.checks.isEmpty, "there were no checks to pass")
            for check in result.report.checks {
                s.require(check.passed, "check \(check.id) failed on a clean machine")
                s.require(!check.vacuous,
                          "check \(check.id) passed without proving anything")
            }
        },
        Case("A first observation is information, not work to fix") { s in
            let box = Sandbox(); defer { box.destroy() }
            let kitchen = Kitchen(locations: box.locations,
                                  recipes: builtins(["env.inventory"]),
                                  profile: try profile(box),
                                  environment: sealed(box))
            let service = await kitchen.inspect(.audit)
            guard let result = service.results.first(where: { $0.recipe == "env.inventory" }),
                  let first = result.report.findings.first(where: {
                      $0.id == "inventory.unrecorded"
                  }) else {
                s.require(false, "the first observation was not explained"); return
            }
            s.equal(result.outcome, .converged,
                    "having no earlier comparison was treated as machine drift")
            s.equal(first.severity, .notice,
                    "the first observation was presented as needing attention")
            s.require(!first.fixable, "recording history was offered as a machine fix")
            s.equal(first.section, .change,
                    "the first observation was not placed with Inventory changes")
            s.require(result.report.checks.allSatisfy { $0.id != "recorded" },
                      "snapshot equality was still presented as a health check")
        },
        Case("Software changes are reported as history, never desired state") { s in
            let box = Sandbox(); defer { box.destroy() }
            let applications = box.root.appending(path: "Applications")
            let alpha = applications.appending(path: "Alpha.app")
            let removed = applications.appending(path: "Removed.app")
            try fm.createDirectory(at: alpha.appending(path: "Contents"),
                                   withIntermediateDirectories: true)
            try fm.createDirectory(at: removed.appending(path: "Contents"),
                                   withIntermediateDirectories: true)
            try writePlist([
                "CFBundleIdentifier": "example.alpha",
                "CFBundleName": "Alpha",
                "CFBundleShortVersionString": "1.0",
            ], to: alpha.appending(path: "Contents/Info.plist"))
            try writePlist([
                "CFBundleIdentifier": "example.removed",
                "CFBundleName": "Removed",
                "CFBundleShortVersionString": "1.0",
            ], to: removed.appending(path: "Contents/Info.plist"))
            let policy = try profile(box) { settings in
                settings.inventory.discovery = InventoryDiscoverySettings(roots: [
                    SoftwareDiscoveryRoot(
                        source: SettingsPathSource(literal: "/Applications"),
                        strategy: .applicationBundles),
                ])
            }
            let kitchen = Kitchen(
                locations: box.locations, recipes: builtins(["core.locations", "env.inventory"]),
                profile: policy, environment: sealed(box))
            _ = try await kitchen.converge()

            try writePlist([
                "CFBundleIdentifier": "example.alpha",
                "CFBundleName": "Alpha",
                "CFBundleShortVersionString": "2.0",
            ], to: alpha.appending(path: "Contents/Info.plist"))
            try fm.removeItem(at: removed)
            let added = applications.appending(path: "Added.app")
            try fm.createDirectory(at: added.appending(path: "Contents"),
                                   withIntermediateDirectories: true)
            try writePlist([
                "CFBundleIdentifier": "example.added",
                "CFBundleName": "Added",
                "CFBundleShortVersionString": "1.0",
            ], to: added.appending(path: "Contents/Info.plist"))

            let service = await kitchen.inspect(.audit)
            guard let result = service.results.first(where: { $0.recipe == "env.inventory" }),
                  let changed = result.report.findings.first(where: {
                      $0.id.hasPrefix("inventory.software.change.modified:")
                  }),
                  let inserted = result.report.findings.first(where: {
                      $0.id.hasPrefix("inventory.software.change.added:")
                  }),
                  let deleted = result.report.findings.first(where: {
                      $0.id.hasPrefix("inventory.software.change.removed:")
                  }) else {
                s.require(false, "software history findings were missing: "
                          + "\(service.results.first?.report.findings.map(\.id) ?? [])")
                return
            }
            s.equal(result.report.facts["software"], "2",
                    "software-unit fact did not match the survey")
            s.equal(changed.args["software"], "Alpha",
                    "modified application lost its name")
            s.equal(changed.args["before"], "application, 1.0, unknown",
                    "modified application lost its prior state")
            s.equal(changed.args["after"], "application, 2.0, unknown",
                    "modified application lost its current state")
            s.equal(inserted.args["software"], "Added",
                    "added application lost its identity")
            s.equal(deleted.args["software"], "Removed",
                    "removed application lost its identity")
            for finding in [changed, inserted, deleted] {
                s.equal(finding.section, .change,
                        "software history was placed outside changes")
                s.require(!finding.fixable && finding.desired == nil,
                          "software history was presented as desired state")
            }
            s.equal(result.outcome, .converged,
                    "software history was treated as machine drift")
        },
        Case("Software discovery refusal is visible and cannot be recorded") { s in
            let box = Sandbox(); defer { box.destroy() }
            let policy = try profile(box) { settings in
                settings.inventory.discovery = InventoryDiscoverySettings(roots: [
                    SoftwareDiscoveryRoot(
                        source: SettingsPathSource(literal: "~/.ssh"),
                        strategy: .topLevelFootprints),
                ])
            }
            let kitchen = Kitchen(
                locations: box.locations, recipes: builtins(["core.locations", "env.inventory"]),
                profile: policy, environment: sealed(box))
            let audit = await kitchen.inspect(.audit)
            guard let result = audit.results.first(where: { $0.recipe == "env.inventory" }),
                  let refusal = result.report.findings.first(where: {
                      $0.id == "inventory.softwareDiscoveryRefused"
                  }) else {
                s.require(false, "software discovery refusal was hidden"); return
            }
            s.require(!refusal.fixable,
                      "FoodTruck claimed it could widen its compiled boundary")

            let converge = try await kitchen.converge()
            if case .failed = converge.results.first(where: { $0.recipe == "env.inventory" })?.outcome {} else {
                s.require(false, "incomplete software discovery was recorded as success")
            }
            let store = try inventoryStore(box, profile: policy)
            s.require(!fm.fileExists(atPath: store.recordURL.path),
                      "incomplete software discovery produced a snapshot")
        },
        Case("Generic footprints remain software facts, not executable findings") { s in
            let box = Sandbox(); defer { box.destroy() }
            let config = box.root.appending(path: ".config")
            try fm.createDirectory(at: config, withIntermediateDirectories: true)
            let policy = try profile(box) { settings in
                settings.inventory.discovery = InventoryDiscoverySettings(roots: [
                    SoftwareDiscoveryRoot(
                        source: SettingsPathSource(literal: "~/.config"),
                        strategy: .topLevelFootprints),
                ])
            }
            let kitchen = Kitchen(
                locations: box.locations, recipes: builtins(["core.locations", "env.inventory"]),
                profile: policy, environment: sealed(box))
            _ = try await kitchen.converge()
            try fm.createDirectory(at: config.appending(path: "cross-platform-tool"),
                                   withIntermediateDirectories: true)

            let audit = await kitchen.inspect(.audit)
            guard let report = audit.results.first(where: { $0.recipe == "env.inventory" })?.report else {
                s.require(false, "inventory report was missing"); return
            }
            s.require(report.findings.contains(where: {
                $0.id.hasPrefix("inventory.software.change.added:")
                    && $0.args["software"] == "cross-platform-tool"
            }), "new footprint was not reported as software history")
            s.require(!report.findings.contains(where: {
                $0.id.hasPrefix("inventory.unmanaged:")
                    || $0.id.hasPrefix("inventory.duplicate:")
                    || $0.id.hasPrefix("inventory.versionConflict:")
                    || $0.id.hasPrefix("inventory.shimConflict:")
            }), "a directory footprint entered executable analysis")
        },
        Case("Nothing the inventory finds is something FoodTruck offers to fix") { s in
            let box = Sandbox(); defer { box.destroy() }
            let brew = box.root.appending(path: "opt/homebrew")
            let brewBin = brew.appending(path: "bin")
            let vendorBin = box.root.appending(path: "usr/local/bin")
            try fm.createDirectory(at: brew.appending(path: "Library/Homebrew"),
                                   withIntermediateDirectories: true)
            try fm.createDirectory(at: brew.appending(path: "Cellar"),
                                   withIntermediateDirectories: true)
            try executable(brewBin.appending(path: "jq"), printing: "jq-1.7.1")
            try executable(vendorBin.appending(path: "jq"), printing: "jq-1.6")
            try executable(brewBin.appending(path: "gh"), printing: "gh version 2.76.0")
            try executable(vendorBin.appending(path: "gh"), printing: "gh version 2.76.0")
            try executable(brewBin.appending(path: "node"))
            try executable(box.root.appending(path: ".local/share/mise/shims/node"))
            try executable(brewBin.appending(path: "mise"))
            try fm.createDirectory(at: box.root.appending(path: ".pyenv"),
                                   withIntermediateDirectories: true)
            try executable(vendorBin.appending(path: "handplaced"))

            let kitchen = Kitchen(locations: box.locations,
                                  recipes: builtins(["env.inventory"]),
                                  profile: try profile(box),
                                  environment: sealed(box))
            let service = await kitchen.inspect(.audit)
            guard let result = service.results.first(where: { $0.recipe == "env.inventory" })
            else { s.require(false, "the inventory recipe did not report"); return }
            let report = result.report
            let kinds = Set(report.findings.map {
                $0.id.split(separator: ":").first.map(String.init) ?? $0.id
            })
            for expected in ["inventory.duplicated", "inventory.versionConflict",
                             "inventory.shimShadowed", "inventory.contested",
                             "inventory.unmanaged"] {
                s.require(kinds.contains(expected),
                          "the fixture produced no \(expected): \(kinds.sorted())")
            }
            s.require(report.findings.allSatisfy { !$0.fixable },
                      "Inventory offered to fix a decision only the user can make")
            s.require(report.findings.allSatisfy { $0.section != nil },
                      "an Inventory finding has no presentation section")
            s.require(report.findings.filter { $0.severity >= .drift }.allSatisfy {
                $0.section == .attention
            }, "a consequential conflict was not assigned to attention")
            s.require(report.findings.filter {
                $0.id == "inventory.duplicated" || $0.id.hasPrefix("inventory.unmanaged:")
            }.allSatisfy { $0.section == .observation },
            "informational inventory facts were not assigned to observations")
            s.require(report.findingsRequiringAction.allSatisfy { finding in
                finding.id.hasPrefix("inventory.versionConflict:")
                    || finding.id.hasPrefix("inventory.shimShadowed:")
                    || finding.id.hasPrefix("inventory.contested:")
            }, "bookkeeping was mixed with consequential conflicts")
            s.equal(result.outcome, .drift,
                    "real command ambiguity did not require attention")
        },

        Case("FoodTruck never inventories its own toolbox") { s in
            let box = Sandbox(); defer { box.destroy() }
            let brew = box.root.appending(path: "opt/homebrew")
            let brewBin = brew.appending(path: "bin")
            try fm.createDirectory(at: brew.appending(path: "Library/Homebrew"),
                                   withIntermediateDirectories: true)
            try fm.createDirectory(at: brew.appending(path: "Cellar"),
                                   withIntermediateDirectories: true)
            try executable(brewBin.appending(path: "mise"), printing: "2026.8.8")
            try executable(box.locations.toolbox.appending(path: "mise"), printing: "2026.8.8")
            try executable(box.locations.toolbox.appending(path: "task"), printing: "3.45.4")
            let alias = box.root.appending(path: "usr/local/bin/task")
            try fm.createDirectory(at: alias.deletingLastPathComponent(),
                                   withIntermediateDirectories: true)
            try fm.createSymbolicLink(
                at: alias,
                withDestinationURL: box.locations.toolbox.appending(path: "task"))
            let toolboxAlias = box.root.appending(path: "aliased-toolbox")
            try fm.createSymbolicLink(at: toolboxAlias,
                                      withDestinationURL: box.locations.toolbox)

            let inventory = try scan(box, [brewBin, box.locations.toolbox,
                                       alias.deletingLastPathComponent(), toolboxAlias])
            s.require(!inventory.roots.contains(box.locations.toolbox.path),
                      "the private toolbox remained a searched root")
            s.require(!inventory.roots.contains(toolboxAlias.path),
                      "a directory alias put the private toolbox back in scope")
            s.equal(inventory.tools.filter { $0.name == "mise" }.count, 1,
                    "FoodTruck's private mise was reported beside the user's")
            s.require(!inventory.tools.contains { $0.name == "task" },
                      "a private tool or alias into it escaped the boundary")
            s.require(!inventory.tools.contains { $0.origin == .foodtruck },
                      "a FoodTruck-owned executable entered the environment")
            s.equal(inventory.managers.first(where: { $0.id == "mise" })?.evidence,
                    Inventory.abbreviate(brewBin.appending(path: "mise").path,
                                         home: box.root.path),
                    "manager detection chose FoodTruck's private mise")
        },
        Case("Legacy FoodTruck entries disappear without becoming changes") { s in
            let box = Sandbox(); defer { box.destroy() }
            let host = Inventory.host(systemRoot: box.root)
            let root = "~/.local/share/foodtruck/toolbox/bin"
            let privateMise = Installed(name: "mise", path: root + "/mise",
                                        origin: .foodtruck, version: "2026.8.8")
            let previous = Inventory(host: host, roots: [root], tools: [privateMise])
            let current = Inventory(host: host, roots: [], tools: [])
            let delta = InventoryDelta(previous: previous, current: current,
                                       excludingRoots: [root])
            s.require(delta.isEmpty,
                      "removing legacy private tools manufactured a user-visible change")
        },
        Case("Inventory delta keeps path identity and separates coverage") { s in
            let box = Sandbox(); defer { box.destroy() }
            let host = Inventory.host(systemRoot: box.root)
            let root = "~/bin"
            let old = Installed(name: "node", path: root + "/node", origin: .unmanaged,
                                version: "20.0", versionSource: .probed, stamp: "1:1")
            let changed = Installed(name: "node", path: root + "/node", origin: .unmanaged,
                                    version: "22.0", versionSource: .probed, stamp: "2:2")
            let second = Installed(name: "node", path: root + "/node22", origin: .unmanaged,
                                   version: "22.0", versionSource: .probed, stamp: "2:2")
            let hidden = Installed(name: "python", path: "~/new/python", origin: .unmanaged)
            let previous = Inventory(host: host, roots: [root], tools: [old])
            let current = Inventory(host: host, roots: [root, "~/new"],
                                    tools: [changed, second, hidden])
            let delta = InventoryDelta(previous: previous, current: current)
            s.equal(delta.modified, [InventoryModification(before: old, after: changed)],
                    "a stable path did not preserve its before/after evidence")
            s.equal(delta.added.map(\.path), [second.path],
                    "a second copy was collapsed by name or new coverage became an install")
            s.equal(delta.addedRoots, ["~/new"], "new scan coverage was lost")
        },
        Case("Inventory delta tolerates duplicate paths and root executables") { s in
            let box = Sandbox(); defer { box.destroy() }
            let host = Inventory.host(systemRoot: box.root)
            let duplicate = Installed(name: "tool", path: "/tool", origin: .apple,
                                      version: "1.0", versionSource: .probed)
            let previous = Inventory(host: host, roots: ["/"],
                                     tools: [duplicate, duplicate])
            let current = Inventory(host: host, roots: ["/"], tools: [])
            let delta = InventoryDelta(previous: previous, current: current)
            s.equal(delta.removed.map(\.path), ["/tool"],
                    "a tool directly under / was omitted or duplicated")
        },
        Case("Stamp generations separate cache validity from replacement history") { s in
            let box = Sandbox(); defer { box.destroy() }
            let host = Inventory.host(systemRoot: box.root)
            let root = "~/bin"
            let path = root + "/jq"
            let legacy = Installed(name: "jq", path: path, origin: .unmanaged,
                                   version: "1.7", versionSource: .probed,
                                   stamp: "123:456")
            let unstamped = Installed(name: "jq", path: path, origin: .unmanaged,
                                      version: "1.7", versionSource: .probed)
            let v2 = Installed(name: "jq", path: path, origin: .unmanaged,
                               version: "1.7", versionSource: .probed,
                               stamp: "v2:/jq:1:2:3:4:5:6:7")
            let current = Installed(name: "jq", path: path, origin: .unmanaged,
                                    version: "1.7", versionSource: .probed,
                                    stamp: "v3:/jq:1:2:3:4:5:6:7")
            let replaced = Installed(name: "jq", path: path, origin: .unmanaged,
                                     version: "1.7", versionSource: .probed,
                                     stamp: "v3:/jq:8:9:10:11:12:13:14")

            func delta(from before: Installed, to after: Installed) -> InventoryDelta {
                InventoryDelta(
                    previous: Inventory(host: host, roots: [root], tools: [before]),
                    current: Inventory(host: host, roots: [root], tools: [after]))
            }
            s.require(delta(from: legacy, to: current).modified.isEmpty,
                      "a legacy-to-v3 stamp upgrade became an executable replacement")
            s.require(delta(from: v2, to: current).modified.isEmpty,
                      "a v2-to-v3 stamp upgrade became an executable replacement")
            s.require(delta(from: unstamped, to: current).modified.isEmpty,
                      "adding the current stamp became an executable replacement")
            s.equal(delta(from: current, to: replaced).modified,
                    [InventoryModification(before: current, after: replaced)],
                    "a same-generation executable replacement disappeared")

            let apple = Installed(name: "cat", path: "/usr/bin/cat", origin: .apple)
            let scoped = InventoryDelta(
                previous: Inventory(host: host, roots: [root, "/usr/bin"],
                                    tools: [current, apple]),
                current: Inventory(host: host, roots: [root], tools: [current]))
            s.require(scoped.removed.isEmpty,
                      "narrowing scan coverage manufactured per-command removals")
            s.equal(scoped.removedRoots, ["/usr/bin"],
                    "the one-time coverage change was not retained")
        },
        Case("Evidence quality alone is not an executable replacement") { s in
            let box = Sandbox(); defer { box.destroy() }
            let host = Inventory.host(systemRoot: box.root)
            let inferred = Installed(name: "jq", path: "~/bin/jq", origin: .unmanaged,
                                     version: "1.7", versionSource: .inferred, stamp: "9:9")
            let probed = Installed(name: "jq", path: "~/bin/jq", origin: .unmanaged,
                                   version: "1.7", versionSource: .probed, stamp: "9:9")
            let delta = InventoryDelta(
                previous: Inventory(host: host, roots: ["~/bin"], tools: [inferred]),
                current: Inventory(host: host, roots: ["~/bin"], tools: [probed]))
            s.require(delta.modified.isEmpty,
                      "a better version source was reported as a replaced executable")
        },
        Case("Manager and search-order changes are part of the delta") { s in
            let box = Sandbox(); defer { box.destroy() }
            let host = Inventory.host(systemRoot: box.root)
            let oldManager = Manager(id: "mise", evidence: "~/bin/mise",
                                     version: "1.0", manages: ["node"])
            let newManager = Manager(id: "mise", evidence: "~/bin/mise",
                                     version: "2.0", manages: ["node"])
            let delta = InventoryDelta(
                previous: Inventory(host: host, roots: ["~/bin", "/usr/bin"],
                                    tools: [], managers: [oldManager]),
                current: Inventory(host: host, roots: ["/usr/bin", "~/bin"],
                                   tools: [], managers: [newManager]))
            s.require(delta.rootsReordered, "search-order change disappeared")
            s.equal(delta.previousManagers, [oldManager], "old manager evidence disappeared")
            s.equal(delta.currentManagers, [newManager], "new manager evidence disappeared")
            s.require(!delta.isEmpty, "meaningful inventory changes reported an empty delta")

            let stampedBefore = Manager(
                id: "mise", evidence: "~/bin/mise", version: "2.0",
                stamp: "1:1", manages: ["node"])
            let stampedAfter = Manager(
                id: "mise", evidence: "~/bin/mise", version: "2.0",
                stamp: "2:2", manages: ["node"])
            let cacheOnly = InventoryDelta(
                previous: Inventory(host: host, roots: [], tools: [],
                                    managers: [stampedBefore]),
                current: Inventory(host: host, roots: [], tools: [],
                                   managers: [stampedAfter]))
            s.require(cacheOnly.previousManagers == nil && cacheOnly.currentManagers == nil,
                      "a cache-only manager stamp produced identical change evidence")
        },
        Case("A manager change becomes a historical observation") { s in
            let box = Sandbox(); defer { box.destroy() }
            let store = try inventoryStore(box)
            try store.write(scan(box))
            try fm.createDirectory(at: box.root.appending(path: ".nvm"),
                                   withIntermediateDirectories: true)
            let kitchen = Kitchen(locations: box.locations,
                                  recipes: builtins(["env.inventory"]),
                                  profile: try profile(box),
                                  environment: sealed(box))
            let service = await kitchen.inspect(.audit)
            guard let finding = service.results.first?.report.findings.first(where: {
                $0.id == "inventory.managers.changed"
            }) else {
                s.require(false, "the manager change was omitted"); return
            }
            s.equal(finding.severity, .notice, "manager history became an error")
            s.equal(finding.section, .change,
                    "manager history was not assigned to Inventory changes")
            s.require(!finding.fixable, "manager history was offered as an automatic fix")
        },
        Case("Bundled Inventory scope excludes macOS system paths") { s in
            let box = Sandbox(); defer { box.destroy() }
            let etc = box.root.appending(path: "etc")
            try fm.createDirectory(at: etc.appending(path: "paths.d"),
                                   withIntermediateDirectories: true)
            try Data("/bin\n/usr/bin\n".utf8).write(to: etc.appending(path: "paths"))
            try Data("/System/Cryptexes/App/usr/bin\n".utf8).write(
                to: etc.appending(path: "paths.d/apple"))

            try executable(box.root.appending(path: "bin/cat"))
            try executable(box.root.appending(path: "usr/bin/cp"))
            try executable(box.root.appending(
                path: "System/Cryptexes/App/usr/bin/bash"))
            try executable(box.root.appending(path: "usr/local/bin/user-tool"))
            try executable(box.root.appending(path: ".local/bin/local-tool"))

            let policy = try profile(box)
            let inventory = Inventory.scan(
                home: policy.home, locations: box.locations,
                settings: policy.inventory, systemRoot: policy.systemRoot)
            let names = Set(inventory.tools.map(\.name))
            s.require(!names.contains("cat") && !names.contains("cp")
                          && !names.contains("bash"),
                      "bundled policy inventoried macOS-owned commands: \(names.sorted())")
            s.require(names.contains("user-tool") && names.contains("local-tool"),
                      "bundled policy lost user-managed software: \(names.sorted())")
            s.require(!inventory.roots.contains(where: {
                $0 == "~/bin" || $0.hasSuffix("/usr/bin")
                    || $0.hasSuffix("/usr/sbin") || $0.hasSuffix("/sbin")
                    || $0.contains("/System/Cryptexes/")
            }), "bundled policy retained a macOS system root: \(inventory.roots)")
            s.require(inventory.roots.contains(where: { $0.hasSuffix("/usr/local/bin") })
                          && inventory.roots.contains("~/.local/bin"),
                      "relevant explicit roots were not searched: \(inventory.roots)")
        },
        Case("A root is recorded only when its directory was read") { s in
            let box = Sandbox(); defer { box.destroy() }
            let notDirectory = box.root.appending(path: "not-a-directory")
            try executable(notDirectory)
            let inventory = try scan(box, [notDirectory])
            s.require(inventory.roots.isEmpty,
                      "a failed directory read was recorded as an empty successful scan")
        },
        Case("A declared root cannot escape the sealed system through a symlink") { s in
            let box = Sandbox(); defer { box.destroy() }
            let outside = URL(filePath: NSTemporaryDirectory())
                .appending(path: "foodtruck-selftest-outside-\(UUID().uuidString)")
            defer { try? fm.removeItem(at: outside) }
            let outsideBin = outside.appending(path: "bin")
            try executable(outsideBin.appending(path: "escaped-tool"))

            let etc = box.root.appending(path: "etc")
            let usr = box.root.appending(path: "usr")
            try fm.createDirectory(at: etc, withIntermediateDirectories: true)
            try fm.createDirectory(at: usr, withIntermediateDirectories: true)
            try Data("/usr/bin\n".utf8).write(to: etc.appending(path: "paths"))
            try fm.createSymbolicLink(at: usr.appending(path: "bin"),
                                      withDestinationURL: outsideBin)

            let policy = try profile(box) { settings in
                settings.inventory.scan.declarations = [PathDeclaration(
                    type: .file,
                    source: SettingsPathSource(literal: "/etc/paths"))]
                settings.inventory.scan.sources = []
                settings.inventory.managers = []
                settings.inventory.origins = []
                settings.inventory.gitCandidates = []
            }
            let inventory = Inventory.scan(
                home: policy.home, locations: box.locations, settings: policy.inventory,
                systemRoot: policy.systemRoot)
            s.require(!inventory.roots.contains { $0.hasSuffix("/usr/bin") },
                      "the escaped declaration was recorded as scanned")
            s.require(!inventory.tools.contains { $0.name == "escaped-tool" },
                      "the escaped declaration was enumerated")
        },

        Case("Sibling home and system roots are both valid scan boundaries") { s in
            let box = Sandbox(); defer { box.destroy() }
            let home = box.root.appending(path: "home")
            let system = box.root.appending(path: "system")
            let homeBin = home.appending(path: "bin")
            let systemBin = system.appending(path: "usr/local/bin")
            try executable(homeBin.appending(path: "home-tool"))
            try executable(systemBin.appending(path: "system-tool"))
            let settings = try profile(box, home: home, systemRoot: system) { settings in
                settings.inventory.scan.declarations = []
                settings.inventory.scan.sources = []
                settings.inventory.managers = []
                settings.inventory.origins = []
            }
            let inventory = Inventory.scan(
                home: home, locations: box.locations, settings: settings.inventory,
                systemRoot: system, roots: [homeBin, systemBin])
            s.equal(Set(inventory.tools.map(\.name)), Set(["home-tool", "system-tool"]),
                    "one sibling trust root was rejected")
        },

        // MARK: the record

        Case("Two scans of an unchanged machine produce identical bytes") { s in
            // Without this the history is a heartbeat: a commit on every run,
            // none of which mean anything. It is also why the record carries no
            // timestamp of its own.
            let box = Sandbox(); defer { box.destroy() }
            let roots = try fixture(box)
            s.equal(try scan(box, roots), try scan(box, roots), "the record differs from itself")
            s.equal(try scan(box, roots).text, try scan(box, roots).text, "the rendering drifts")
        },
        Case("Inventory history disables hooks and stages only owned files") { s in
            let box = Sandbox(); defer { box.destroy() }
            guard let policy = try installConfiguredGit(box) else { return }
            let store = try inventoryStore(box, profile: policy)
            var environment = Exec.baseEnvironment(box.locations)
            environment["GIT_DIR"] = box.root.appending(path: "escaped.git").path
            environment["GIT_WORK_TREE"] = box.root.appending(path: "escaped-worktree").path
            environment["GIT_CONFIG_COUNT"] = "1"
            environment["GIT_CONFIG_KEY_0"] = "core.hooksPath"
            environment["GIT_CONFIG_VALUE_0"] = box.root.appending(path: "escaped-hooks").path
            let inventory = try scan(box, [])
            try store.write(inventory)
            guard case .recorded = await store.commit(message: "first",
                                                      environment: environment) else {
                s.require(false, "the first commit did not go through"); return
            }

            let marker = box.root.appending(path: "hook-ran")
            let hook = box.locations.inventory.appending(path: ".git/hooks/pre-commit")
            try Data("#!/bin/sh\nprintf ran > '\(marker.path)'\nexit 1\n".utf8)
                .write(to: hook)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hook.path)
            let unrelated = box.locations.inventory.appending(path: "unrelated")
            try Data("not FoodTruck history".utf8).write(to: unrelated)

            var moved = inventory
            moved.roots.append("/opt/somewhere/new")
            try store.write(moved)
            guard case .recorded = await store.commit(message: "second",
                                                       environment: environment) else {
                s.require(false, "disabled repository hooks still blocked the commit"); return
            }
            s.require(!fm.fileExists(atPath: marker.path),
                      "automatic history executed a repository hook")
            guard let git = store.executable() else {
                s.require(false, "configured Git disappeared"); return
            }
            let listed = await Exec.run(
                git, ["-C", box.locations.inventory.path, "ls-files"],
                environment: Exec.baseEnvironment(box.locations), timeout: 30)
            s.require(!listed.stdout.split(separator: "\n").contains("unrelated"),
                      "automatic history staged an unrelated file")
        },
        Case("A recorded inventory reads back as the same value") { s in
            let box = Sandbox(); defer { box.destroy() }
            let inventory = try scan(box, try fixture(box))
            let store = try inventoryStore(box)
            try store.write(inventory)
            guard let reloaded = store.load() else {
                s.require(false, "nothing read back"); return
            }
            s.equal(reloaded, inventory, "round trip lost something")
        },
        Case("A malformed snapshot is not mistaken for no snapshot") { s in
            let box = Sandbox(); defer { box.destroy() }
            let store = try inventoryStore(box)
            try fm.createDirectory(at: box.locations.inventory,
                                   withIntermediateDirectories: true)
            try Data("{not-json".utf8).write(to: store.recordURL)
            guard case .invalid(let detail) = store.read() else {
                s.require(false, "the malformed record was treated as missing"); return
            }
            s.require(!detail.isEmpty, "the decoding failure lost its explanation")
            s.equal(try String(contentsOf: store.recordURL, encoding: .utf8), "{not-json",
                    "reading a malformed record altered it")
        },
        Case("An unreadable snapshot is assigned to Inventory history") { s in
            let box = Sandbox(); defer { box.destroy() }
            let store = try inventoryStore(box)
            try fm.createDirectory(at: box.locations.inventory,
                                   withIntermediateDirectories: true)
            try Data("{not-json".utf8).write(to: store.recordURL)
            let kitchen = Kitchen(locations: box.locations,
                                  recipes: builtins(["env.inventory"]),
                                  profile: try profile(box),
                                  environment: sealed(box))
            let service = await kitchen.inspect(.audit)
            guard let finding = service.results.first?.report.findings.first(where: {
                $0.id == "inventory.snapshotUnreadable"
            }) else {
                s.require(false, "the unreadable snapshot was not reported"); return
            }
            s.equal(finding.section, .history,
                    "the snapshot problem was not assigned to Inventory history")
            s.require(!finding.fixable, "Inventory offered to rewrite damaged history")
        },
        Case("Converge preserves an invalid snapshot byte for byte") { s in
            let box = Sandbox(); defer { box.destroy() }
            let policy = try profile(box)
            let store = try inventoryStore(box, profile: policy)
            try fm.createDirectory(at: box.locations.inventory,
                                   withIntermediateDirectories: true)
            let corrupt = Data("{not-json".utf8)
            try corrupt.write(to: store.recordURL)
            let kitchen = Kitchen(
                locations: box.locations, recipes: builtins(["core.locations", "env.inventory"]),
                profile: policy, environment: sealed(box))
            let service = try await kitchen.converge()
            guard let result = service.results.first(where: { $0.recipe == "env.inventory" })
            else { s.require(false, "inventory converge did not run"); return }
            if case .failed = result.outcome {} else {
                s.require(false, "invalid history did not stop converge")
            }
            s.equal(try Data(contentsOf: store.recordURL), corrupt,
                    "converge overwrote the invalid snapshot")
        },
        Case("Converge reports the exact survey it records") { s in
            let box = Sandbox(); defer { box.destroy() }
            let bin = box.root.appending(path: "usr/local/bin")
            let jq = bin.appending(path: "jq")
            let late = bin.appending(path: "late")
            try fm.createDirectory(at: bin, withIntermediateDirectories: true)
            let script = """
            #!/bin/sh
            printf '#!/bin/sh\\necho late-1.0.0\\n' > '\(late.path)'
            chmod 755 '\(late.path)'
            echo jq-1.7.1
            """
            try Data(script.utf8).write(to: jq)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: jq.path)
            let policy = try profile(box)
            let kitchen = Kitchen(
                locations: box.locations, recipes: builtins(["core.locations", "env.inventory"]),
                profile: policy, environment: sealed(box))
            let service = try await kitchen.converge()
            guard let result = service.results.first(where: { $0.recipe == "env.inventory" }),
                  let recorded = try inventoryStore(box, profile: policy).load() else {
                s.require(false, "inventory converge produced no record"); return
            }
            s.equal(result.report.facts["programs"],
                    String(recorded.environmentTools.count),
                    "converge ran a second survey for its report")
            s.require(!recorded.tools.contains { $0.name == "late" },
                      "the late executable existed during the first scan")
            s.require(fm.fileExists(atPath: late.path),
                      "the probe did not create the single-survey witness")
        },
        Case("A snapshot written before a field existed still loads") { s in
            // A history whose older entries cannot be read is not a history,
            // and re-recording from scratch erases the comparison it is kept for.
            let json = #"{"host":{"product":"macOS","version":"26.6","build":"25G83","arch":"arm64","kernel":"25.6.0"},"roots":[],"tools":[]}"#
            let old = try JSONDecoder().decode(Inventory.self, from: Data(json.utf8))
            s.require(old.managers.isEmpty, "absent managers decode as none, not as a failure")
            s.require(old.software.isEmpty && old.softwareRoots.isEmpty,
                      "schema-less history invented software coverage")
            s.equal(old.host.version, "26.6", "the rest survived")
        },
        Case("A version-one snapshot migrates without inventing software changes") { s in
            let json = #"{"schema":"foodtruck.inventory/1","host":{"product":"macOS","version":"26.6","build":"25G83","arch":"arm64","kernel":"25.6.0"},"roots":[],"tools":[],"managers":[]}"#
            let old = try JSONDecoder().decode(Inventory.self, from: Data(json.utf8))
            s.equal(old.schema, Inventory.currentSchema,
                    "legacy snapshot did not migrate to the current in-memory schema")
            s.require(old.software.isEmpty && old.softwareRoots.isEmpty,
                      "legacy snapshot invented software facts")
            let encoded = try JSONEncoder().encode(old)
            let object = try JSONSerialization.jsonObject(with: encoded) as? [String: Any]
            s.equal(object?["schema"] as? String, "foodtruck.inventory/2",
                    "migrated snapshot encoded with its legacy schema")
            s.require(object?["software"] != nil && object?["softwareRoots"] != nil,
                      "migrated snapshot omitted the complete v2 contract")
        },
        Case("Declared snapshots reject future schemas and missing fields") { s in
            let samples = [
                #"{"schema":"foodtruck.inventory/3"}"#,
                #"{"schema":"foodtruck.inventory/2","host":{"product":"macOS","version":"26.6","build":"25G83","arch":"arm64","kernel":"25.6.0"},"roots":[],"tools":[],"managers":[]}"#,
                #"{"schema":"foodtruck.inventory/1","host":{"product":"macOS","version":"26.6","build":"25G83","arch":"arm64","kernel":"25.6.0"},"roots":[],"managers":[]}"#,
            ]
            for sample in samples {
                do {
                    _ = try JSONDecoder().decode(Inventory.self, from: Data(sample.utf8))
                    s.require(false, "unsupported or partial snapshot decoded")
                } catch {
                    s.require(true, "snapshot was rejected")
                }
            }
        },
        Case("Auditing writes nothing, not even its own directory") { s in
            let box = Sandbox(); defer { box.destroy() }
            let kitchen = Kitchen(
                locations: box.locations, recipes: builtins(["env.inventory"]),
                profile: try profile(box), environment: sealed(box))
            let before = box.fingerprint()
            _ = await kitchen.inspect(.audit)
            s.equal(box.fingerprint(), before, "audit wrote to the sandbox")
            s.require(!FileManager.default.fileExists(atPath: box.locations.inventory.path),
                      "audit created the inventory directory")
        },
        Case("Only audit carries the captured inventory") { s in
            let box = Sandbox(); defer { box.destroy() }
            let kitchen = Kitchen(locations: box.locations,
                                  recipes: builtins(["env.inventory"]),
                                  profile: try profile(box),
                                  environment: sealed(box))
            let audit = await kitchen.inspect(.audit)
            let verify = await kitchen.inspect(.verify)
            s.require(audit.results.first?.inventory != nil,
                      "the GUI audit did not carry its already-completed scan")
            s.require(verify.results.first?.inventory == nil,
                      "a verb with no snapshot consumer retained the full inventory")
        },
        Case("Once the machine is recorded there is nothing left to fix") { s in
            let box = Sandbox(); defer { box.destroy() }
            let kitchen = Kitchen(
                locations: box.locations,
                recipes: builtins(["core.locations", "env.inventory"]),
                profile: try profile(box), environment: sealed(box))
            _ = try await kitchen.converge()
            let service = await kitchen.inspect(.audit)
            // Notices -- unmanaged programs, contested runtimes -- are expected
            // on any real machine and are deliberately not drift.
            s.require(service.drifted.isEmpty,
                      "still drifted: \(service.drifted.flatMap { $0.report.findings.map(\.id) })")
        },
        Case("An inventory change names the exact copy without becoming drift") { s in
            let box = Sandbox(); defer { box.destroy() }
            try fm.createDirectory(at: box.root.appending(path: "usr/local/bin"),
                                   withIntermediateDirectories: true)
            let kitchen = Kitchen(locations: box.locations,
                                  recipes: builtins(["core.locations", "env.inventory"]),
                                  profile: try profile(box),
                                  environment: sealed(box))
            _ = try await kitchen.converge()
            try executable(box.root.appending(path: "usr/local/bin/new-tool"))

            let service = await kitchen.inspect(.audit)
            guard let result = service.results.first(where: { $0.recipe == "env.inventory" }),
                  let finding = result.report.findings.first(where: {
                      $0.id.hasPrefix("inventory.change.added:")
                  }) else {
                s.require(false, "the added copy was not reported"); return
            }
            s.equal(result.outcome, .converged,
                    "an ordinary installation was treated as an error")
            s.equal(finding.title, "finding.inventory.program.added",
                    "the addition did not use the evidence-bearing message")
            s.equal(finding.args["tool"], "new-tool", "the command name was lost")
            s.require(finding.args["path"]?.hasSuffix("/usr/local/bin/new-tool") == true,
                      "the path identity was lost: \(finding.args)")
            s.equal(finding.args["origin"], "unmanaged",
                    "the install source was not preserved")
            s.require(!finding.fixable && finding.desired == nil,
                      "history was presented as desired state")
            s.equal(finding.section, .change,
                    "an installed program change was not assigned to changes")
        },
        Case("A replaced executable invalidates its cached version") { s in
            // The cache is a safety feature, not an optimisation. Without it
            // every audit re-launches every declared tool, which is how one
            // mutation run turned into a few thousand process launches.
            let box = Sandbox(); defer { box.destroy() }
            let bin = box.root.appending(path: "bin")
            let jq = bin.appending(path: "jq")
            try executable(jq, printing: "jq-1.7.1")
            let env = sealed(box)
            let policy = try profile(box)

            let first = await (try scan(box, [bin])).probingVersions(
                home: policy.home, environment: env, settings: policy.inventory,
                systemRoot: policy.systemRoot)
            s.equal(first.tools.first?.version, "1.7.1", "asked once")

            // Preserve size and whole-second mtime. Inode/ctime/nanosecond
            // identity must still notice that the executable changed.
            let modified = try fm.attributesOfItem(atPath: jq.path)[.modificationDate]
            try Data("#!/bin/sh\necho jq-9.9.9\n".utf8).write(to: jq)
            try fm.setAttributes([.posixPermissions: 0o755,
                                  .modificationDate: modified as Any],
                                 ofItemAtPath: jq.path)
            let second = await (try scan(box, [bin])).probingVersions(
                home: policy.home, environment: env, settings: policy.inventory,
                systemRoot: policy.systemRoot, reusing: first)
            s.equal(second.tools.first?.version, "9.9.9",
                    "a replaced executable reused a stale cached version")
        },
        Case("A stamp format upgrade invalidates the version cache") { s in
            let box = Sandbox(); defer { box.destroy() }
            let bin = box.root.appending(path: "bin")
            let jq = bin.appending(path: "jq")
            let answer = box.root.appending(path: "jq-answer")
            try fm.createDirectory(at: bin, withIntermediateDirectories: true)
            try Data("#!/bin/sh\ncat '\(answer.path)'\n".utf8).write(to: jq)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: jq.path)
            try Data("jq-1.7.1\n".utf8).write(to: answer)
            let env = sealed(box)
            let policy = try profile(box)

            var legacy = await (try scan(box, [bin])).probingVersions(
                home: policy.home, environment: env, settings: policy.inventory,
                systemRoot: policy.systemRoot)
            s.equal(legacy.tools.first?.version, "1.7.1", "initial probe failed")
            legacy.tools[0].stamp = "42:123456"
            try Data("jq-9.9.9\n".utf8).write(to: answer)

            let refreshed = await (try scan(box, [bin])).probingVersions(
                home: policy.home, environment: env, settings: policy.inventory,
                systemRoot: policy.systemRoot, reusing: legacy)
            s.equal(refreshed.tools.first?.version, "9.9.9",
                    "a legacy stamp reused a cached version against a v2 executable")
        },
        Case("Standalone and recipe surveys share the stored probe cache") { s in
            let box = Sandbox(); defer { box.destroy() }
            let jq = box.root.appending(path: "usr/local/bin/jq")
            let answer = box.root.appending(path: "jq-version")
            try fm.createDirectory(at: jq.deletingLastPathComponent(),
                                   withIntermediateDirectories: true)
            try Data("#!/bin/sh\ncat '\(answer.path)'\n".utf8).write(to: jq)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: jq.path)
            try Data("jq-1.7.1\n".utf8).write(to: answer)
            let environment = sealed(box)
            let policy = try profile(box)
            let store = try inventoryStore(box, profile: policy)

            let standalone = await InventorySurvey.run(
                home: policy.home, locations: box.locations, environment: environment,
                settings: policy.inventory, store: store)
            try store.write(standalone.inventory)
            // The executable identity is unchanged; only the external answer
            // changes. A shared cache must not launch it again.
            try Data("jq-9.9.9\n".utf8).write(to: answer)

            let kitchen = Kitchen(
                locations: box.locations, recipes: builtins(["env.inventory"]),
                profile: policy, environment: environment)
            let audited = await kitchen.inspect(.audit)
            let inventory = audited.results.first?.inventory
            s.equal(inventory?.tools.first(where: { $0.name == "jq" })?.version,
                    "1.7.1", "the recipe did not reuse the standalone survey cache")
        },
        Case("Probe subprocesses cannot see configured path-source variables") { s in
            let box = Sandbox(); defer { box.destroy() }
            let bin = box.root.appending(path: "usr/local/bin")
            let jq = bin.appending(path: "jq")
            try fm.createDirectory(at: bin, withIntermediateDirectories: true)
            let script = """
            #!/bin/sh
            if [ -z "$INVENTORY_TEST_PATH" ] && [ -z "$FOODTRUCK_DATA_DIR" ] && \
               [ -n "$HOME" ] && [ "$HOME" = "$XDG_CONFIG_HOME" ] && \
               [ "$HOME" != "\(box.root.path)" ]; then
              echo jq-1.2.3
            else
              echo jq-9.9.9
            fi
            """
            try Data(script.utf8).write(to: jq)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: jq.path)
            var environment = sealed(box)
            environment["INVENTORY_TEST_PATH"] = "/usr/local/bin"
            let policy = try profile(box, environment: environment) { settings in
                settings.inventory.scan.declarations = []
                settings.inventory.scan.sources = [SettingsPathSource(
                    environment: "INVENTORY_TEST_PATH", fallback: "/usr/local/bin")]
                settings.inventory.managers = []
                settings.inventory.origins = []
                settings.inventory.probes.names = ["jq"]
            }
            let store = try inventoryStore(box, profile: policy)
            let result = await InventorySurvey.run(
                home: policy.home, locations: box.locations, environment: environment,
                settings: policy.inventory, store: store)
            s.equal(result.inventory.tools.first?.version, "1.2.3",
                    "probe inherited FoodTruck or configured path-source state")
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
            let policy = try profile(box)
            let probed = await (try scan(box, [bin])).probingVersions(
                home: policy.home, environment: sealed(box), settings: policy.inventory,
                systemRoot: policy.systemRoot)
            guard let mise = probed.managers.first(where: { $0.id == "mise" }),
                  let nvm = probed.managers.first(where: { $0.id == "nvm" }) else {
                s.require(false, "managers missing: \(probed.managers.map(\.id))"); return
            }
            s.require(!mise.shellFunction, "mise is a program, not a shell function")
            s.equal(mise.version, "2026.8.8", "a manager's own version was not asked for")
            s.require(nvm.shellFunction, "nvm is a shell function")
            s.require(nvm.version == nil, "there was no binary to have asked")
        },
        Case("A cached audit preserves a manager's version") { s in
            let box = Sandbox(); defer { box.destroy() }
            let bin = box.root.appending(path: "bin")
            try executable(bin.appending(path: "mise"), printing: "2026.8.8")
            let environment = sealed(box)
            let policy = try profile(box)
            let first = await (try scan(box, [bin])).probingVersions(
                home: policy.home, environment: environment, settings: policy.inventory,
                systemRoot: policy.systemRoot)
            let second = await (try scan(box, [bin])).probingVersions(
                home: policy.home, environment: environment, settings: policy.inventory,
                systemRoot: policy.systemRoot, reusing: first)
            s.equal(second.managers.first(where: { $0.id == "mise" })?.version,
                    "2026.8.8", "the cached pass erased the manager version")
        },
        Case("A directory-manager upgrade invalidates its cached version") { s in
            let box = Sandbox(); defer { box.destroy() }
            let directory = box.root.appending(path: "manager-home")
            let binary = directory.appending(path: "bin/manager")
            try executable(binary, printing: "manager-1.0.0")
            let policy = try profile(box) { settings in
                settings.inventory.managers = [ManagerDeclaration(
                    id: "manager", binaries: ["manager"],
                    directories: [SettingsPathSource(literal: "~/manager-home")],
                    manages: ["node"])]
            }
            let evidence = Inventory.abbreviate(
                policy.inventory.managers[0].directories[0].path, home: policy.home.path)
            let inventory = Inventory(
                host: Inventory.host(systemRoot: box.root), roots: [], tools: [],
                managers: [Manager(id: "manager", evidence: evidence, manages: ["node"])])
            let first = await inventory.probingVersions(
                home: policy.home, environment: sealed(box), settings: policy.inventory,
                systemRoot: policy.systemRoot)
            s.equal(first.managers.first?.version, "1.0.0", "manager was not initially probed")

            try executable(binary, printing: "manager-22.0.0")
            let second = await inventory.probingVersions(
                home: policy.home, environment: sealed(box), settings: policy.inventory,
                systemRoot: policy.systemRoot, reusing: first)
            s.equal(second.managers.first?.version, "22.0.0",
                    "an in-place manager upgrade reused a stale cached version")
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
                                  profile: try profile(box),
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
            s.require(report.findings.first?.severity ?? .ok >= .drift,
                      "informational history was placed ahead of the actionable conflict")

            guard let unique = check("unique"), let managers = check("managers") else {
                s.require(false, "expected checks missing"); return
            }
            s.require(check("traceable") == nil,
                      "unmanaged programs were presented as a failed health guarantee")
            s.require(!unique.passed, "jq is installed twice at different versions")
            s.require(managers.vacuous, "no manager here, so that check proves nothing")
        },
        Case("Inventory findings use the resolved reporting profile") { s in
            let box = Sandbox(); defer { box.destroy() }
            try executable(box.root.appending(path: "usr/local/bin/jq"),
                           printing: "jq-2.0.0")
            try executable(box.root.appending(path: "opt/homebrew/bin/jq"),
                           printing: "jq-1.7.1")
            let policy = try profile(box) { settings in
                guard let index = settings.inventory.reporting.firstIndex(where: {
                    $0.id == InventoryReportID.versionConflict.rawValue
                }) else { return }
                settings.inventory.reporting[index].severity = .risk
                settings.inventory.reporting[index].section = .history
                settings.inventory.reporting[index].title = "test.inventory.customConflict"
                settings.inventory.reporting[index].remedy = nil
            }
            let kitchen = Kitchen(
                locations: box.locations, recipes: builtins(["env.inventory"]),
                profile: policy, environment: sealed(box))
            let service = await kitchen.inspect(.audit)
            guard let finding = service.results.first?.report.findings.first(where: {
                $0.id.hasPrefix("inventory.versionConflict:")
            }) else {
                s.require(false, "configured version-conflict finding was absent"); return
            }
            s.equal(finding.severity, .risk,
                    "configured reporting severity was ignored")
            s.equal(finding.section, .history,
                    "configured reporting section was ignored")
            s.equal(finding.title, "test.inventory.customConflict",
                    "configured reporting title was ignored")
            s.require(finding.remedy == nil,
                      "configured removal of a reporting remedy was ignored")
        },
        Case("Recording the machine actually writes a commit") { s in
            let box = Sandbox(); defer { box.destroy() }
            // A machine with no usable git still records the snapshot; only the
            // history is lost. Nothing to assert there, so step aside.
            guard let policy = try installConfiguredGit(box) else { return }
            let kitchen = Kitchen(locations: box.locations,
                                  recipes: builtins(["core.locations", "env.inventory"]),
                                  profile: policy, environment: sealed(box))
            _ = try await kitchen.converge()
            let store = try inventoryStore(box, profile: policy)
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
        Case("Git discovery stays sealed and denies a configured /usr/bin stub") { s in
            let box = Sandbox(); defer { box.destroy() }
            let outside = URL(filePath: NSTemporaryDirectory())
                .appending(path: "foodtruck-outside-git-\(UUID().uuidString)")
            defer { try? fm.removeItem(at: outside) }
            let stub = box.root.appending(path: "usr/bin/git")
            let allowed = box.root.appending(path: "opt/tools/bin/git")
            try executable(outside)
            try executable(stub)
            try executable(allowed)
            s.equal(
                InventoryStore.executable(
                    systemRoot: box.root, candidates: [outside, stub, allowed]),
                try CanonicalPath.resolve(allowed),
                "Git discovery escaped its root or ignored the configured candidate")
            s.require(
                InventoryStore.executable(
                    systemRoot: box.root, candidates: [outside, stub]) == nil,
                "an outside Git or configured /usr/bin stub was accepted")
        },
    ])
}
