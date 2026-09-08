import Foundation

/// Installs the editable settings overlay once. Audit only reads. Converge
/// writes a minimal overlay when absent, so untouched installations continue to
/// inherit policy additions from each signed bundled default. Existing custom or
/// invalid files are never replaced.
struct SettingsRecipe: BuiltinRecipe {
    private static let emptyOverlay = Data(
        """
        {
          "schema": "\(FoodTruckSettings.currentSchema)",
          "vars": {}
        }
        """.utf8)

    var descriptor: Recipe {
        Recipe(
            id: "core.settings",
            name: "recipe.core.settings.name",
            summary: "recipe.core.settings.summary",
            engine: "builtin",
            requires: ["core.locations"],
            provides: ["settings"],
            verbs: [.detect, .audit, .plan, .converge, .verify],
            blast: .contained,
            scope: .housekeeping,
            timeout: 10,
            symbol: "gearshape.2"
        )
    }

    func audit(_ context: RunContext) async -> RecipeReport {
        report(for: SettingsLoader.load(context.locations), context)
    }

    private func report(for load: SettingsLoad, _ context: RunContext) -> RecipeReport {
        var report = RecipeReport(facts: ["settings": context.locations.settings.path])
        switch load {
        case .missing:
            report.findings.append(Finding(
                id: "settings.missing", severity: .drift,
                title: "finding.settings.missing",
                args: ["path": context.locations.settings.path],
                observed: "absent", desired: FoodTruckSettings.currentSchema))
            report.checks.append(Check(
                id: "settings", label: "check.settings.valid", passed: false))
        case .loaded(let settings):
            report.facts["schema"] = settings.schema
            report.checks.append(Check(
                id: "settings", label: "check.settings.valid", passed: true))
        case .invalid(let failure):
            report.findings.append(Finding(
                id: "settings.invalid", severity: .risk,
                title: "finding.settings.invalid",
                args: ["path": failure.path], observed: failure.reason,
                desired: FoodTruckSettings.currentSchema, fixable: false,
                remedy: "finding.settings.invalid.remedy"))
            report.checks.append(Check(
                id: "settings", label: "check.settings.valid", passed: false,
                automatable: false))
        }
        return report
    }

    private func fault(for failure: SettingsFailure) -> RecipeFault {
        RecipeFault(
            kind: failure.source == .user ? .settingsInvalid : .settingsUnavailable,
            recipe: descriptor.id, verb: .converge,
            args: ["recipe": descriptor.id, "path": failure.path],
            detail: failure.description)
    }

    /// A successful housekeeping result must describe the same final load that
    /// proved the postcondition. This keeps a file changed between the initial
    /// audit and converge from disappearing behind a successful hidden chore.
    private func finish(_ context: RunContext, missingDetail: String? = nil)
        -> Result<RecipeReport, RecipeFault> {
        let final = SettingsLoader.load(context.locations)
        switch final {
        case .loaded:
            return .success(report(for: final, context))
        case .invalid(let failure):
            return .failure(fault(for: failure))
        case .missing:
            return .failure(RecipeFault(
                kind: .settingsUnavailable, recipe: descriptor.id, verb: .converge,
                args: ["recipe": descriptor.id, "path": context.locations.settings.path],
                detail: missingDetail ?? "settings remained absent after converge"))
        }
    }

    func converge(_ context: RunContext) async -> Result<RecipeReport, RecipeFault> {
        switch SettingsLoader.load(context.locations) {
        case .loaded:
            do {
                try migrateGeneratedFullCopyIfNeeded(context.locations)
                return finish(context)
            } catch {
                return .failure(RecipeFault(
                    kind: .settingsUnavailable, recipe: descriptor.id, verb: .converge,
                    args: ["recipe": descriptor.id,
                           "path": context.locations.settings.path],
                    detail: error.localizedDescription))
            }
        case .invalid(let failure):
            return .failure(fault(for: failure))
        case .missing:
            do {
                try FileManager.default.createDirectory(
                    at: context.locations.config, withIntermediateDirectories: true,
                    attributes: [.posixPermissions: 0o700])
                // `withoutOverwriting` makes a concurrent writer win. The fresh
                // load in `finish` then judges that file rather than replacing it.
                try Self.emptyOverlay.write(
                    to: context.locations.settings, options: .withoutOverwriting)
                return finish(context)
            } catch {
                return finish(context, missingDetail: error.localizedDescription)
            }
        }
    }

    /// Early development builds copied the complete bundled catalogue. Collapse
    /// only that byte-identical generated file; any edit, including formatting,
    /// marks it as user-owned and leaves it untouched.
    private func migrateGeneratedFullCopyIfNeeded(_ locations: Locations) throws {
        guard let bundled = locations.bundledSettings,
              let userData = try? Data(contentsOf: locations.settings),
              let bundledData = try? Data(contentsOf: bundled),
              userData == bundledData else { return }
        try Self.emptyOverlay.write(to: locations.settings, options: .atomic)
    }
}
