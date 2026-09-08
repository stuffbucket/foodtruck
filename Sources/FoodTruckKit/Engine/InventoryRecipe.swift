import Foundation

/// Turns the validated declarative reporting table into stable findings. The
/// code retains only identity and evidence shape; presentation policy belongs
/// to the operation's immutable settings profile.
private struct InventoryFindingPolicy {
    private let declarations: [InventoryReportID: ReportingDeclaration]

    init(_ declarations: [ReportingDeclaration]) {
        self.declarations = Dictionary(
            uniqueKeysWithValues: declarations.compactMap { declaration in
                InventoryReportID(rawValue: declaration.id).map { ($0, declaration) }
            })
    }

    func make(
        _ id: InventoryReportID,
        discriminator: String? = nil,
        args: [String: String] = [:],
        observed: String? = nil
    ) -> Finding {
        guard let declaration = declarations[id] else {
            preconditionFailure("validated reporting policy omitted \(id.rawValue)")
        }
        return Finding(
            id: discriminator.map { "\(id.findingID):\($0)" } ?? id.findingID,
            severity: declaration.severity,
            title: declaration.title,
            args: args,
            observed: observed ?? id.observedArgument.flatMap { args[$0] },
            fixable: declaration.fixable,
            remedy: declaration.remedy,
            section: declaration.section)
    }
}

private extension InventoryReportID {
    var findingID: String {
        switch self {
        case .probeRefused: "inventory.probeRefused"
        case .softwareDiscoveryRefused: "inventory.softwareDiscoveryRefused"
        case .snapshotUnreadable: "inventory.snapshotUnreadable"
        case .firstObservation: "inventory.unrecorded"
        case .hostChanged: "inventory.host.changed"
        case .coverageAdded: "inventory.coverage.added"
        case .coverageRemoved: "inventory.coverage.removed"
        case .coverageReordered: "inventory.coverage.reordered"
        case .softwareCoverageAdded: "inventory.software.coverage.added"
        case .softwareCoverageRemoved: "inventory.software.coverage.removed"
        case .managersChanged: "inventory.managers.changed"
        case .programAdded: "inventory.change.added"
        case .programRemoved: "inventory.change.removed"
        case .programVersionChanged, .programOriginChanged, .programTargetChanged,
             .programKindChanged, .programReplaced: "inventory.change.modified"
        case .softwareAdded: "inventory.software.change.added"
        case .softwareRemoved: "inventory.software.change.removed"
        case .softwareChanged: "inventory.software.change.modified"
        case .versionConflict: "inventory.versionConflict"
        case .duplicated: "inventory.duplicated"
        case .shimShadowed: "inventory.shimShadowed"
        case .contested: "inventory.contested"
        case .unmanaged: "inventory.unmanaged"
        case .noGit: "inventory.nogit"
        case .historyFailed: "inventory.historyFailed"
        }
    }

    var observedArgument: String? {
        switch self {
        case .versionConflict: "versions"
        case .contested: "managers"
        case .unmanaged: "path"
        default: nil
        }
    }
}

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
/// There is no desired machine state here because there is no profile yet, and
/// inventing one would be inventing the user's intent. History is evidence, not
/// a goal; only command-resolution ambiguity asks the user for a decision.
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

    private func findingPolicy(_ context: RunContext) -> InventoryFindingPolicy {
        guard let profile = context.profile else {
            preconditionFailure("env.inventory requires a resolved settings profile")
        }
        return InventoryFindingPolicy(profile.inventory.reporting)
    }

    private func store(_ context: RunContext) -> InventoryStore {
        guard let profile = context.profile else {
            preconditionFailure("env.inventory requires a resolved settings profile")
        }
        return InventoryStore(
            root: context.locations.inventory, home: profile.home,
            systemRoot: profile.systemRoot,
            gitCandidates: profile.inventory.gitCandidates)
    }

    private func completedSurvey(_ context: RunContext) async -> InventorySurveyResult {
        guard let profile = context.profile else {
            preconditionFailure("env.inventory requires a resolved settings profile")
        }
        return await InventorySurvey.run(
            home: profile.home, locations: context.locations, environment: context.environment,
            settings: profile.inventory, store: store(context))
    }

    private func inspect(
        _ context: RunContext, completed: InventorySurveyResult? = nil
    ) async -> BuiltinAudit {
        let store = store(context)
        let survey = if let completed { completed } else { await completedSurvey(context) }
        let current = survey.inventory
        let previous: Inventory?
        let loadFailure: String?
        switch survey.prior {
        case .missing:
            previous = nil
            loadFailure = nil
        case .loaded(let inventory):
            previous = inventory
            loadFailure = nil
        case .invalid(let detail):
            previous = nil
            loadFailure = detail
        }
        var report = RecipeReport()
        let findings = findingPolicy(context)

        report.facts["os"] = current.host.describe
        report.facts["arch"] = current.host.arch
        report.facts["kernel"] = current.host.kernel
        report.facts["commandLineTools"] = current.host.commandLineTools ?? "not installed"
        report.facts["programs"] = String(current.environmentTools.count)
        report.facts["searched"] = String(current.roots.count)
        report.facts["software"] = String(current.software.count)
        report.facts["softwareSearched"] = String(current.softwareRoots.count)
        for (origin, count) in current.countsByOrigin.sorted(by: { $0.key.rawValue < $1.key.rawValue }) {
            report.facts["from.\(origin.rawValue)"] = String(count)
        }
        if current.probeRefused {
            report.findings.append(findings.make(.probeRefused))
        }
        if current.softwareDiscoveryRefused {
            report.findings.append(findings.make(.softwareDiscoveryRefused))
        }
        if let loadFailure {
            report.findings.append(findings.make(.snapshotUnreadable, observed: loadFailure))
        }

        // MARK: what changed since the previous observation

        if let previous {
            let home = URL(filePath: context.environment["HOME"] ?? NSHomeDirectory())
            let toolbox = context.locations.toolbox.standardizedFileURL.path
            let excludedRoots: Set<String> = [
                toolbox,
                Inventory.abbreviate(toolbox, home: home.standardizedFileURL.path),
            ]
            let delta = InventoryDelta(
                previous: previous, current: current, excludingRoots: excludedRoots)

            if let before = delta.previousHost, let after = delta.currentHost {
                report.findings.append(findings.make(.hostChanged,
                    args: ["before": hostEvidence(before), "after": hostEvidence(after)]))
            }
            if !delta.addedRoots.isEmpty {
                report.findings.append(findings.make(.coverageAdded,
                    args: ["paths": delta.addedRoots.joined(separator: ", ")]))
            }
            if !delta.removedRoots.isEmpty {
                report.findings.append(findings.make(.coverageRemoved,
                    args: ["paths": delta.removedRoots.joined(separator: ", ")]))
            }
            if delta.rootsReordered {
                report.findings.append(findings.make(.coverageReordered))
            }
            if !delta.addedSoftwareRoots.isEmpty {
                report.findings.append(findings.make(.softwareCoverageAdded,
                    args: ["paths": softwareCoverageEvidence(delta.addedSoftwareRoots)]))
            }
            if !delta.removedSoftwareRoots.isEmpty {
                report.findings.append(findings.make(.softwareCoverageRemoved,
                    args: ["paths": softwareCoverageEvidence(delta.removedSoftwareRoots)]))
            }
            for artifact in delta.addedSoftware {
                report.findings.append(findings.make(
                    .softwareAdded, discriminator: artifact.id,
                    args: softwareEvidence(artifact)))
            }
            for artifact in delta.removedSoftware {
                report.findings.append(findings.make(
                    .softwareRemoved, discriminator: artifact.id,
                    args: softwareEvidence(artifact)))
            }
            for change in delta.modifiedSoftware {
                var args = softwareEvidence(change.after)
                args["before"] = softwareDescription(change.before)
                args["after"] = softwareDescription(change.after)
                report.findings.append(findings.make(
                    .softwareChanged, discriminator: change.after.id, args: args))
            }
            if let before = delta.previousManagers, let after = delta.currentManagers {
                report.findings.append(findings.make(.managersChanged,
                    args: ["before": managerEvidence(before),
                           "after": managerEvidence(after)]))
            }
            for tool in delta.added {
                report.findings.append(findings.make(.programAdded,
                    discriminator: tool.path, args: evidence(for: tool)))
            }
            for tool in delta.removed {
                report.findings.append(findings.make(.programRemoved,
                    discriminator: tool.path, args: evidence(for: tool)))
            }
            for change in delta.modified {
                let before = change.before
                let after = change.after
                let modification: InventoryReportID
                var args = evidence(for: after)
                if before.version != after.version {
                    modification = .programVersionChanged
                    args["before"] = before.version ?? t("value.unknown")
                    args["after"] = after.version ?? t("value.unknown")
                } else if before.origin != after.origin {
                    modification = .programOriginChanged
                    args["before"] = originLabel(before.origin)
                    args["after"] = originLabel(after.origin)
                } else if before.real != after.real {
                    modification = .programTargetChanged
                    args["before"] = before.real ?? before.path
                    args["after"] = after.real ?? after.path
                } else if before.shim != after.shim {
                    modification = .programKindChanged
                    args["before"] = t(before.shim ? "inventory.kind.shim" : "inventory.kind.direct")
                    args["after"] = t(after.shim ? "inventory.kind.shim" : "inventory.kind.direct")
                } else {
                    modification = .programReplaced
                }
                report.findings.append(findings.make(
                    modification, discriminator: after.path, args: args))
            }
        } else if loadFailure == nil {
            report.findings.append(findings.make(.firstObservation))
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
        let shadowed = current.shadowedShims
        for (name, copies) in conflicting.sorted(by: { $0.key < $1.key }) {
            let versions = copies
                .map { "\($0.version ?? "unknown") (\($0.path))" }
                .joined(separator: ", ")
            report.findings.append(findings.make(.versionConflict,
                discriminator: name, args: ["tool": name, "versions": versions]))
        }
        var harmlessDuplicateNames = Set(current.duplicated.keys)
        harmlessDuplicateNames.subtract(conflicting.keys)
        harmlessDuplicateNames.subtract(shadowed.keys)
        if !harmlessDuplicateNames.isEmpty {
            report.findings.append(findings.make(.duplicated,
                args: ["count": String(harmlessDuplicateNames.count)]))
        }
        report.checks.append(Check(
            id: "unique", label: "check.inventory.unique", passed: conflicting.isEmpty,
            vacuous: current.environmentTools.isEmpty))

        // Commands in the same two directories ask for one PATH decision,
        // regardless of how many executables the package installed there.
        for group in current.shimShadowGroups {
            report.findings.append(findings.make(.shimShadowed,
                discriminator: "\(group.shimDirectory)->\(group.directDirectory)",
                args: ["tools": group.commands.joined(separator: ", "),
                       "manager": originLabel(group.manager),
                       "shim": group.shimDirectory,
                       "direct": group.directDirectory]))
        }
        report.checks.append(Check(
            id: "shims", label: "check.inventory.shims", passed: shadowed.isEmpty,
            vacuous: !current.environmentTools.contains(where: \.shim)))

        // MARK: which tools decide what the other tools are

        for manager in current.managers {
            report.facts["manager.\(manager.id)"] =
                manager.version ?? (manager.shellFunction ? "shell function" : "unknown")
        }
        // The overlap, named per runtime. Whichever manager wins the race to
        // PATH decides, the decision lives in a shell startup file, and the
        // loser goes on reporting the version it believes you are using.
        let contested = current.contested
        for (runtime, managers) in contested.sorted(by: { $0.key < $1.key }) {
            report.findings.append(findings.make(.contested,
                discriminator: runtime,
                args: ["runtime": runtime, "managers": managers.joined(separator: ", ")]))
        }
        report.checks.append(Check(
            id: "managers", label: "check.inventory.managers",
            passed: contested.isEmpty,
            // Nothing was proven if there is no manager to have an opinion.
            vacuous: current.managers.isEmpty))

        // MARK: what nothing accounts for

        // One finding per program on purpose. Each of these is a decision
        // somebody made once and has no other record of, and collapsing them
        // into a count would lose the only useful part -- which ones.
        let unaccounted = current.unmanaged
        for tool in unaccounted {
            report.findings.append(findings.make(.unmanaged,
                // FoodTruck will not guess what you meant by installing it.
                // Adopting it into a package manager, or deleting it, is a
                // decision -- and there is no profile to record it in yet.
                discriminator: tool.path,
                args: ["tool": tool.name, "path": tool.path]))
        }
        // MARK: can we keep a history at all

        let git = store.executable() != nil
        if !git {
            report.findings.append(findings.make(.noGit))
        }
        // The terminal truncates long reports. Keep every actionable consequence
        // ahead of informational history so the reason for a non-zero result can
        // never be hidden by a busy week of harmless changes.
        report.findings = report.findings.enumerated().sorted { lhs, rhs in
            lhs.element.severity == rhs.element.severity
                ? lhs.offset < rhs.offset
                : lhs.element.severity > rhs.element.severity
        }.map(\.element)
        return BuiltinAudit(report: report, inventory: current)
    }

    func audit(_ context: RunContext) async -> RecipeReport {
        await inspect(context).report
    }

    func auditCapture(_ context: RunContext) async -> BuiltinAudit {
        await inspect(context)
    }

    private func hostEvidence(_ host: Host) -> String {
        let tools = host.commandLineTools ?? t("value.notInstalled")
        return "\(host.describe), \(host.arch), kernel \(host.kernel), CLT \(tools)"
    }

    private func managerEvidence(_ managers: [Manager]) -> String {
        guard !managers.isEmpty else { return t("value.none") }
        return managers.map { manager in
            let version = manager.version ?? t("value.unknown")
            let kind = manager.shellFunction ? "shell-function" : "executable"
            let runtimes = manager.manages.joined(separator: ",")
            return "\(manager.id) \(version) [\(kind) \(manager.evidence)] {\(runtimes)}"
        }.joined(separator: ", ")
    }

    private func originLabel(_ origin: Origin) -> String {
        let key = "inventory.origin.\(origin.rawValue)"
        let localized = t(key)
        return localized == key ? origin.rawValue : localized
    }

    private func softwareCoverageEvidence(
        _ roots: [SoftwareDiscoveryCoverage]
    ) -> String {
        roots.map { "\($0.strategy.rawValue): \($0.path)" }.joined(separator: ", ")
    }

    private func softwareEvidence(_ artifact: SoftwareArtifact) -> [String: String] {
        [
            "software": artifact.name,
            "path": artifact.path,
            "kind": artifact.kind.rawValue,
            "versions": artifact.versions.isEmpty
                ? t("value.unknown") : artifact.versions.joined(separator: ", "),
            "provider": artifact.provider.map(originLabel) ?? t("value.unknown"),
            "identifier": artifact.identifier ?? t("value.unknown"),
        ]
    }

    private func softwareDescription(_ artifact: SoftwareArtifact) -> String {
        let versions = artifact.versions.isEmpty
            ? t("value.unknown") : artifact.versions.joined(separator: ", ")
        let provider = artifact.provider.map(originLabel) ?? t("value.unknown")
        return "\(artifact.kind.rawValue), \(versions), \(provider)"
    }

    private func evidence(for tool: Installed) -> [String: String] {
        [
            "tool": tool.name,
            "path": tool.path,
            "origin": originLabel(tool.origin),
            "version": tool.version ?? t("value.unknown"),
        ]
    }

    func converge(_ context: RunContext) async -> Result<RecipeReport, RecipeFault> {
        let store = store(context)
        let survey = await completedSurvey(context)
        if case .invalid(let detail) = survey.prior {
            return .failure(RecipeFault(
                kind: .unexpectedExit, recipe: descriptor.id, verb: .converge,
                args: ["recipe": descriptor.id, "verb": "converge"],
                detail: "\(store.recordURL.path): \(detail)"))
        }
        let current = survey.inventory
        guard !current.probeRefused, !current.softwareDiscoveryRefused else {
            return .failure(RecipeFault(
                kind: .unexpectedExit, recipe: descriptor.id, verb: .converge,
                args: ["recipe": descriptor.id, "verb": "converge"],
                detail: t(current.softwareDiscoveryRefused
                    ? "finding.inventory.softwareDiscoveryRefused"
                    : "finding.inventory.probeRefused")))
        }

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
            message: "\(current.host.describe) — \(current.environmentTools.count) programs, "
                + "\(current.software.count) software units, \(unmanaged) unmanaged",
            environment: context.environment)

        // Build the final report from the completed observation. Re-scanning
        // here would make one converge execute two surveys and could report a
        // different machine than the snapshot it just wrote.
        var report = await inspect(context, completed: survey).report
        if case .failed(let detail) = outcome {
            // The record is written either way; only the history was lost. That
            // is a notice, not a failure -- refusing to converge because git
            // misbehaved would throw away the part that worked.
            report.findings.append(findingPolicy(context).make(
                .historyFailed,
                observed: detail.trimmingCharacters(in: .whitespacesAndNewlines)))
        }
        return .success(report)
    }
}
