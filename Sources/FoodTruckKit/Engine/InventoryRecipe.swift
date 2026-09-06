import Foundation

/// What is actually on this machine, and what has changed since last time.
///
/// This is the first recipe that is about the user rather than about FoodTruck,
/// and it exists because of a specific failure: FoodTruck could only report on
/// things it had a recipe for, so on a machine with seven toolchains and one
/// recipe its silence was indistinguishable from approval. A tool that cannot
/// say "I have never looked at this" cannot be trusted when it says "this is
/// fine".
///
/// It is a builtin, which the surrounding rule reserves for tech-tree roots,
/// and it qualifies for the same reason those do: it must work on a machine
/// where nothing is installed. Knowing what is here cannot depend on something
/// being here. It is also the recipe that makes the others writable -- you
/// cannot declare intent about tools you have forgotten you have.
///
/// Its desired state is deliberately modest, because there is no profile yet
/// and inventing one here would be inventing the user's intent. The only thing
/// it asks for is that the history be current: the machine as recorded should
/// be the machine as it is. Everything else it has to say, it says as a notice.
struct InventoryRecipe: BuiltinRecipe {
    var descriptor: Recipe {
        Recipe(
            id: "env.inventory",
            name: "recipe.env.inventory.name",
            summary: "recipe.env.inventory.summary",
            engine: "builtin",
            requires: ["core.locations"],
            provides: ["inventory"],
            verbs: [.detect, .audit, .plan, .converge, .verify],
            // Writes the snapshot into FoodTruck's own data directory and
            // nothing else. Reading the machine is not a blast radius.
            blast: .contained,
            scope: .environment,
            timeout: 60,
            symbol: "list.bullet.rectangle"
        )
    }

    /// Two passes, and the split is the point. The first reads the machine
    /// without running any of it. The second runs the short declared list of
    /// tools this project exists to keep pinned, and believes what they say
    /// over what their directory names imply.
    private func survey(_ context: RunContext, reusing previous: Inventory?) async -> Inventory {
        let home = URL(filePath: context.environment["HOME"] ?? NSHomeDirectory())
        // A seam for the tests, and only for them. Without it every test that
        // audits this recipe reads -- and probes -- the machine running the
        // tests, which turned a mutation run into a few thousand subprocess
        // launches against a real Mac.
        // No boolean in this expression, on purpose. It used to test
        // `isEmpty`, and this file is a mutation-testing target: flipping that
        // one comparison would send a sealed test back at the real machine.
        // A seal a mutant can pick is not a seal.
        let systemRoot = context.environment["FOODTRUCK_SCAN_ROOT"]
            .map { URL(filePath: $0) } ?? URL(filePath: "/")
        return await Inventory
            .scan(home: home, locations: context.locations, systemRoot: systemRoot)
            .probingVersions(home: home, environment: context.environment,
                             systemRoot: systemRoot, reusing: previous)
    }

    func audit(_ context: RunContext) async -> RecipeReport {
        let store = InventoryStore(root: context.locations.inventory)
        // Loaded before the survey, not after: the recorded versions are what
        // let the survey skip re-running programs it has already asked.
        let previous = store.load()
        let current = await survey(context, reusing: previous)
        var report = RecipeReport()

        report.facts["os"] = current.host.describe
        report.facts["arch"] = current.host.arch
        report.facts["kernel"] = current.host.kernel
        report.facts["commandLineTools"] = current.host.commandLineTools ?? "not installed"
        report.facts["programs"] = String(current.tools.count)
        report.facts["searched"] = String(current.roots.count)
        for (origin, count) in current.countsByOrigin.sorted(by: { $0.key.rawValue < $1.key.rawValue }) {
            report.facts["from.\(origin.rawValue)"] = String(count)
        }

        // MARK: is the history current

        if let previous {
            if previous.host != current.host {
                report.findings.append(Finding(
                    id: "inventory.host.changed", severity: .drift,
                    title: "finding.inventory.host.changed",
                    args: ["before": previous.host.describe, "after": current.host.describe],
                    observed: current.host.describe, desired: previous.host.describe))
            }
            let before = Set(previous.tools.map(\.id))
            let now = Set(current.tools.map(\.id))
            let added = now.subtracting(before).count
            let removed = before.subtracting(now).count
            let changed = previous.tools != current.tools

            if changed {
                report.findings.append(Finding(
                    id: "inventory.changed", severity: .drift,
                    title: "finding.inventory.changed",
                    args: ["added": String(added), "removed": String(removed)],
                    observed: String(current.tools.count),
                    desired: String(previous.tools.count)))
            }
            report.checks.append(Check(
                id: "recorded", label: "check.inventory.recorded",
                passed: !changed && previous.host == current.host))
        } else {
            report.findings.append(Finding(
                id: "inventory.unrecorded", severity: .drift,
                title: "finding.inventory.unrecorded",
                observed: "unrecorded", desired: "recorded"))
            report.checks.append(Check(
                id: "recorded", label: "check.inventory.recorded", passed: false))
        }

        // The order these are appended is the order a reader meets them: the
        // terminal shows the first six and summarises the rest. So the ones
        // where PATH order silently decides what runs go first, and the long
        // per-program list of things nobody manages goes last -- it is the
        // least urgent thing here and it is also the longest.

        // MARK: names installed more than once

        // Summarised rather than listed. Which copy wins depends on a PATH this
        // recipe does not claim to know, and on a normal Mac most duplicates
        // (`curl`, `ruby`, `vim`) are both expected and harmless. Saying it once
        // with a count, and putting the detail behind `foodtruck inventory`, is
        // the difference between a useful note and forty lines of noise.
        // Split by whether the copies actually differ. Two `gh` at 2.96.0 is
        // tidiness; reporting it trains people to ignore the report. Two at
        // different versions means `PATH` order decides which one you get, and
        // that is worth naming individually.
        let conflicting = current.conflictingVersions
        for (name, copies) in conflicting.sorted(by: { $0.key < $1.key }) {
            let versions = copies
                .map { "\($0.version ?? "unknown") (\($0.path))" }
                .joined(separator: ", ")
            report.findings.append(Finding(
                id: "inventory.versionConflict:\(name)", severity: .notice,
                title: "finding.inventory.versionConflict",
                args: ["tool": name, "versions": versions],
                observed: versions,
                fixable: false, remedy: "finding.inventory.versionConflict.remedy"))
        }
        let sameVersion = current.duplicated.count - conflicting.count
        if sameVersion > 0 {
            report.findings.append(Finding(
                id: "inventory.duplicated", severity: .notice,
                title: "finding.inventory.duplicated",
                args: ["count": String(sameVersion)],
                fixable: false, remedy: "finding.inventory.duplicated.remedy"))
        }
        report.checks.append(Check(
            id: "unique", label: "check.inventory.unique", passed: conflicting.isEmpty,
            vacuous: current.tools.isEmpty))

        // A shim beside a real install. Neither knows about the other, the
        // shim has no version to compare, and PATH order decides -- so this
        // gets said plainly rather than folded into a count.
        let shadowed = current.shadowedShims
        for (name, copies) in shadowed.sorted(by: { $0.key < $1.key }) {
            guard let shim = copies.first(where: \.shim),
                  let direct = copies.first(where: { !$0.shim }) else { continue }
            report.findings.append(Finding(
                id: "inventory.shimShadowed:\(name)", severity: .notice,
                title: "finding.inventory.shimShadowed",
                args: ["tool": name, "manager": shim.origin.rawValue,
                       "shim": shim.path, "direct": direct.path,
                       "version": direct.version ?? "unknown"],
                observed: direct.path, desired: shim.path,
                fixable: false, remedy: "finding.inventory.shimShadowed.remedy"))
        }
        report.checks.append(Check(
            id: "shims", label: "check.inventory.shims", passed: shadowed.isEmpty,
            vacuous: !current.tools.contains(where: \.shim)))

        // MARK: which tools decide what the other tools are

        for manager in current.managers {
            report.facts["manager.\(manager.id)"] =
                manager.version ?? (manager.shellFunction ? "shell function" : "unknown")
        }
        // The overlap, named per runtime. Whichever manager wins the race to
        // PATH decides, the decision lives in a shell startup file, and the
        // loser goes on reporting the version it believes you are using.
        for (runtime, managers) in current.contested.sorted(by: { $0.key < $1.key }) {
            report.findings.append(Finding(
                id: "inventory.contested:\(runtime)", severity: .notice,
                title: "finding.inventory.contested",
                args: ["runtime": runtime, "managers": managers.joined(separator: ", ")],
                observed: managers.joined(separator: ", "),
                fixable: false, remedy: "finding.inventory.contested.remedy"))
        }
        report.checks.append(Check(
            id: "managers", label: "check.inventory.managers",
            passed: current.contested.isEmpty,
            // Nothing was proven if there is no manager to have an opinion.
            vacuous: current.managers.isEmpty))

        // MARK: what nothing accounts for

        // One finding per program on purpose. Each of these is a decision
        // somebody made once and has no other record of, and collapsing them
        // into a count would lose the only useful part -- which ones.
        for tool in current.unmanaged {
            report.findings.append(Finding(
                id: "inventory.unmanaged:\(tool.path)", severity: .notice,
                title: "finding.inventory.unmanaged",
                args: ["tool": tool.name, "path": tool.path],
                observed: tool.path, desired: nil,
                // FoodTruck will not guess what you meant by installing it.
                // Adopting it into a package manager, or deleting it, is a
                // decision -- and there is no profile to record it in yet.
                fixable: false, remedy: "finding.inventory.unmanaged.remedy"))
        }
        report.checks.append(Check(
            id: "traceable", label: "check.inventory.traceable",
            passed: current.unmanaged.isEmpty,
            // No programs found at all means nothing was proven, not that
            // everything is accounted for.
            vacuous: current.tools.isEmpty))

        // MARK: can we keep a history at all

        let git = InventoryStore.executable() != nil
        if !git {
            report.findings.append(Finding(
                id: "inventory.nogit", severity: .notice,
                title: "finding.inventory.nogit",
                fixable: false, remedy: "finding.inventory.nogit.remedy"))
        }
        report.checks.append(Check(
            id: "history", label: "check.inventory.history", passed: git,
            automatable: false))

        return report
    }

    func converge(_ context: RunContext) async -> Result<RecipeReport, RecipeFault> {
        let store = InventoryStore(root: context.locations.inventory)
        let current = await survey(context, reusing: store.load())

        do {
            try store.write(current)
        } catch {
            return .failure(RecipeFault(
                kind: .unexpectedExit, recipe: descriptor.id, verb: .converge,
                args: ["recipe": descriptor.id, "verb": "converge"],
                detail: "\(store.recordURL.path): \(error.localizedDescription)"))
        }

        let unmanaged = current.unmanaged.count
        let outcome = await store.commit(
            message: "\(current.host.describe) — \(current.tools.count) programs, "
                + "\(unmanaged) unmanaged",
            environment: context.environment)

        var report = await audit(context)
        if case .failed(let detail) = outcome {
            // The record is written either way; only the history was lost. That
            // is a notice, not a failure -- refusing to converge because git
            // misbehaved would throw away the part that worked.
            report.findings.append(Finding(
                id: "inventory.historyFailed", severity: .notice,
                title: "finding.inventory.historyFailed",
                observed: detail.trimmingCharacters(in: .whitespacesAndNewlines),
                fixable: false, remedy: "finding.inventory.nogit.remedy"))
        }
        return .success(report)
    }
}
