import Foundation

/// Runs recipes written as Taskfiles, via the `go-task` binary FoodTruck
/// unlocked into its own toolbox.
///
/// The contract a recipe author has to satisfy is deliberately one line long:
///
/// > **Every task FoodTruck manages declares `status:`, and is named `ensure:*`
/// > if FoodTruck may fix it or `manual:*` if only a person may.**
///
/// The second prefix is not a convenience, it is a safety boundary. Installing
/// Homebrew wants a TTY and an admin password; an app that quietly triggered
/// that would be the worst thing in this category. A `manual:*` task is audited
/// exactly like an `ensure:*` one -- same predicate, same drift reporting -- but
/// converge never invokes it. It surfaces as a finding that says what is wrong
/// and, from the task's `summary:`, precisely what the person should run.
///
/// `status:` is go-task's own idempotency predicate -- all commands
/// exit 0 means "already done, skip". The recipe author writes no JSON, learns
/// no FoodTruck vocabulary, and cannot get the wire format wrong, because there
/// isn't one.
///
/// How we read that predicate is measured, not assumed. `task --list-all --json`
/// carries an `up_to_date` field and a `--no-status` flag that implies it is
/// computed -- but on 3.53.1 it is `false` for every task, including one whose
/// `status:` is literally `true`. Believing it would have reported permanent
/// drift on a perfectly converged machine. `--status <task>` is the honest
/// signal: exit 0 up-to-date, 1 not, and it provably runs no `cmds:`.
///
/// A recipe that wants richer findings than "this task is out of date" may also
/// define an `audit` task printing a `RecipeReport`; its findings are merged
/// over the structural ones. That is the whole extension mechanism: start
/// simple, opt into detail.
///
/// We shell out rather than embedding go-task as a Go library, which it does
/// support. Two reasons, both about this product: the release is a notarized
/// Swift app built with nothing but Command Line Tools, and adding a Go
/// toolchain to that build would trade a clean supply chain for a convenience;
/// and a recipe that wedges itself should take down a subprocess, not the app.
public struct TaskfileEngine: RecipeEngine {
    public let id = "taskfile"
    /// The recipe that unlocks the runner, named so a missing engine becomes a
    /// button rather than an error.
    public static let unlockRecipe = "core.toolbox"

    public init() {}

    private func binary(_ context: RunContext) -> URL? {
        let owned = context.locations.toolbox.appending(path: "task")
        if FileManager.default.isExecutableFile(atPath: owned.path) { return owned }
        // A system-installed task is accepted, but only if the user's PATH was
        // deliberately handed to us -- never discovered behind their back.
        return Exec.which("task", environment: context.environment)
    }

    public func availability(_ context: RunContext) async -> EngineAvailability {
        binary(context) == nil ? .needsRecipe(Self.unlockRecipe) : .ready
    }

    /// Flags passed on every invocation, for reasons that are each a bug we are
    /// not going to have:
    /// - `-t`/`-d` pin the entrypoint and the working directory, so a recipe
    ///   never runs against whatever happened to be the process's CWD.
    /// - `TASK_TEMP_DIR` moves go-task's `.task/` fingerprint cache out of the
    ///   recipe directory and into FoodTruck's cache, keeping the pantry clean
    ///   and the host tidy.
    /// - `-y` because there is no TTY behind a GUI; a recipe that needs consent
    ///   asks for it through FoodTruck, not through a hidden shell prompt.
    private func invocation(
        _ recipe: Recipe, _ context: RunContext, _ extra: [String]
    ) -> (URL, [String], [String: String], URL)? {
        guard let bin = binary(context) else { return nil }
        let dir = context.locations.recipes.appending(path: recipe.id)
        var args = ["-t", dir.appending(path: "Taskfile.yml").path, "-d", dir.path, "-y"]
        args += extra
        // Profile values reach recipes as CLI vars, the highest-precedence
        // source, so a stray environment variable can never quietly win.
        args += context.vars.map { "\($0.key)=\($0.value)" }.sorted()

        var env = context.environment
        env["TASK_TEMP_DIR"] = context.locations.cache.appending(path: "task").path
        return (bin, args, env, dir)
    }

    public func run(_ verb: Verb, recipe: Recipe, context: RunContext) async -> VerbResult {
        let started = Date()
        func fault(_ kind: RecipeFault.Kind, _ detail: String? = nil) -> VerbResult {
            VerbResult(recipe: recipe.id, verb: verb, outcome: .failed(RecipeFault(
                kind: kind, recipe: recipe.id, verb: verb,
                args: ["recipe": recipe.id, "verb": verb.rawValue,
                       "engine": "go-task", "unlock": Self.unlockRecipe],
                detail: detail)), duration: Date().timeIntervalSince(started))
        }
        guard recipe.verbs.contains(verb) else { return fault(.verbUnsupported) }
        guard binary(context) != nil else { return fault(.engineUnavailable) }

        switch verb {
        case .detect, .audit, .verify:
            return await inspect(recipe, context, verb: verb, started: started)
        case .plan:
            let probes = await probeAll(recipe, context)
            let bad = drifted(probes)
            guard let (bin, args, env, dir) = invocation(
                recipe, context,
                ["-n"] + bad.filter { $0.check.automatable }.map(\.name))
            else { return fault(.engineUnavailable) }
            let r = await Exec.run(bin, args, environment: env,
                                   workingDirectory: dir, timeout: recipe.timeout)
            return VerbResult(
                recipe: recipe.id, verb: verb,
                outcome: bad.isEmpty ? .converged : .drift,
                report: RecipeReport(findings: bad.compactMap(\.finding),
                                     checks: probes.map(\.check)),
                duration: Date().timeIntervalSince(started), log: r.stdout)
        case .converge:
            let probes = await probeAll(recipe, context)
            let bad = drifted(probes)
            let automatable = bad.filter { $0.check.automatable }
            if bad.isEmpty {
                return VerbResult(recipe: recipe.id, verb: verb, outcome: .converged,
                                  duration: Date().timeIntervalSince(started))
            }
            guard !automatable.isEmpty else {
                // Everything left needs a person. That is not a failure and must
                // never be reported as one -- it is a clear instruction.
                return VerbResult(
                    recipe: recipe.id, verb: verb, outcome: .blocked,
                    report: RecipeReport(findings: bad.compactMap(\.finding),
                                         checks: probes.map(\.check)),
                    duration: Date().timeIntervalSince(started))
            }
            let flags = context.dryRun ? ["-n"] : ["-C", "4", "-o", "group"]
            guard let (bin, args, env, dir) =
                invocation(recipe, context, flags + automatable.map(\.name))
            else { return fault(.engineUnavailable) }
            let r = await Exec.run(bin, args, environment: env,
                                   workingDirectory: dir, timeout: recipe.timeout)
            guard r.status == 0 && !r.timedOut else {
                return fault(r.timedOut ? .timedOut : .unexpectedExit,
                             [r.stderr, r.stdout].filter { !$0.isEmpty }.joined(separator: "\n"))
            }
            // Never take converge's word for it. Re-audit is the verdict.
            var verdict = await inspect(recipe, context, verb: .verify, started: started)
            verdict.verb = .converge
            verdict.log = r.stdout
            return verdict
        case .rollback:
            guard let (bin, args, env, dir) = invocation(recipe, context, ["rollback"])
            else { return fault(.engineUnavailable) }
            let r = await Exec.run(bin, args, environment: env,
                                   workingDirectory: dir, timeout: recipe.timeout)
            return VerbResult(recipe: recipe.id, verb: verb,
                              outcome: ReportDecoder.outcome(r, recipe: recipe.id, verb: verb),
                              duration: Date().timeIntervalSince(started), log: r.stdout)
        }
    }

    // MARK: - The one read-only call everything else is built on

    private struct Listing: Decodable {
        struct Entry: Decodable {
            var name: String
            var desc: String?      // what this task guarantees -- shown as the finding
            var summary: String?   // for manual tasks, what the person should run
        }
        var tasks: [Entry]
    }

    /// The managed surface of a recipe: every task named `ensure:*` or
    /// `manual:*`. `--no-status` because that field is unreliable (it is false
    /// even for `status: [true]`) and we do not want to pay for it either.
    private func managedTasks(_ recipe: Recipe, _ context: RunContext) async -> [Listing.Entry] {
        guard let (bin, args, env, dir) =
            invocation(recipe, context, ["--list-all", "--json", "--no-status"])
        else { return [] }
        let r = await Exec.run(bin, args, environment: env,
                               workingDirectory: dir, timeout: recipe.timeout)
        guard let data = r.stdout.data(using: .utf8),
              let listing = try? JSONDecoder().decode(Listing.self, from: data)
        else { return [] }
        return listing.tasks.filter {
            $0.name.hasPrefix("ensure:") || $0.name.hasPrefix("manual:")
        }
    }

    struct Probed {
        var name: String
        var check: Check
        var finding: Finding?
    }

    /// Evaluate every managed predicate and report all of them.
    ///
    /// The batch `--status` shortcut is gone on purpose. It could answer "is
    /// anything wrong" in one process, which was fast, but it could not say
    /// what it had checked -- and a green answer that cannot show its working
    /// is indistinguishable from one that checked nothing. The probes are
    /// independent, so they run at once; the cost is a handful of short-lived
    /// processes and the gain is an auditable answer.
    private func probeAll(_ recipe: Recipe, _ context: RunContext) async -> [Probed] {
        let tasks = await managedTasks(recipe, context)
        guard !tasks.isEmpty else { return [] }

        return await withTaskGroup(of: Probed?.self) { group in
            for entry in tasks {
                group.addTask {
                    guard let (bin, args, env, dir) =
                        invocation(recipe, context, ["--status", entry.name]) else { return nil }
                    let status = await Exec.run(bin, args, environment: env,
                                                workingDirectory: dir,
                                                timeout: recipe.timeout).status
                    let manual = entry.name.hasPrefix("manual:")
                    let label = entry.desc.flatMap { $0.isEmpty ? nil : $0 } ?? entry.name
                    let passed = status == 0
                    let check = Check(id: entry.name, label: label, passed: passed,
                                      automatable: !manual)
                    guard !passed else { return Probed(name: entry.name, check: check) }
                    let remedy = entry.summary.flatMap { $0.isEmpty ? nil : $0 }
                    return Probed(name: entry.name, check: check, finding: Finding(
                        id: "\(recipe.id):\(entry.name)",
                        severity: .drift,
                        title: "finding.task.drift",
                        args: ["task": label],
                        observed: "drift", desired: "converged",
                        fixable: !manual,
                        remedy: manual ? (remedy ?? "finding.task.manual.remedy") : nil))
                }
            }
            var acc: [Probed] = []
            for await p in group { if let p { acc.append(p) } }
            return acc.sorted { $0.name < $1.name }
        }
    }

    private func drifted(_ probes: [Probed]) -> [Probed] { probes.filter { $0.finding != nil } }

    private func inspect(
        _ recipe: Recipe, _ context: RunContext, verb: Verb, started: Date
    ) async -> VerbResult {
        let probes = await probeAll(recipe, context)
        var report = RecipeReport(findings: probes.compactMap(\.finding),
                                  checks: probes.map(\.check))

        // Optional richer audit, merged over the structural findings. A recipe
        // that does not define `audit` simply contributes nothing here.
        if recipe.verbs.contains(.audit),
           let (bin, args, env, dir) = invocation(recipe, context, ["audit"]) {
            let r = await Exec.run(bin, args, environment: env,
                                   workingDirectory: dir, timeout: recipe.timeout)
            // Exit 200 is go-task for "no such task", which is not an error here.
            if r.status != 200, case .success(let extra) =
                ReportDecoder.decode(stdout: r.stdout, recipe: recipe.id, verb: verb) {
                report.facts.merge(extra.facts) { _, new in new }
                let known = Set(report.findings.map(\.id))
                report.findings += extra.findings.filter { !known.contains($0.id) }
                // A recipe may annotate a check it knows passed vacuously --
                // "your Brewfile is satisfied" proves nothing when there is no
                // Brewfile. Only the recipe can know that, so only the recipe
                // can say it.
                for annotation in extra.checks {
                    if let i = report.checks.firstIndex(where: { $0.id == annotation.id }) {
                        report.checks[i].vacuous = annotation.vacuous
                        if !annotation.label.isEmpty { report.checks[i].label = annotation.label }
                    }
                }
            }
        }
        report.findings.sort { $0.severity > $1.severity }
        return VerbResult(
            recipe: recipe.id, verb: verb,
            outcome: report.requiresAction ? .drift : .converged,
            report: report, duration: Date().timeIntervalSince(started))
    }
}
