import Foundation
import Observation
import FoodTruckKit

/// What the window is showing, and the only place it can change.
///
/// The window never calls an engine. It reads this, and asks it to do one of
/// three things. That keeps every rule about safety -- read-only verbs, the
/// blast ceiling, dependency ordering -- in `FoodTruckKit`, where the CLI and
/// the self-test enforce it too. A button that could bypass the ceiling would be
/// a second implementation of the rules, and the second implementation is always
/// the one that is wrong.
@MainActor
@Observable
final class AppModel {
    enum Activity: Equatable {
        case idle
        case auditing
        case converging(recipe: String?)

        var isBusy: Bool { self != .idle }
    }

    private(set) var recipes: [Recipe] = []
    /// What the person actually came to look at. Housekeeping is settled
    /// silently before the first audit and never listed -- "a file has not been
    /// copied yet", with a Fix button, is our plumbing, not their machine.
    var visibleRecipes: [Recipe] { recipes.filter { $0.scope == .environment } }
    /// Set only when housekeeping fails, which IS news: it means FoodTruck
    /// cannot do its job. Shown as a banner, never as a row in the list.
    private(set) var housekeepingFault: RecipeFault?
    private(set) var results: [String: VerbResult] = [:]
    private(set) var loadFaults: [RecipeFault] = []
    private(set) var activity: Activity = .idle
    private(set) var lastRun: Date?
    /// Set when a run finishes, for the VoiceOver announcement. Cleared once
    /// spoken, so it never repeats on an unrelated redraw.
    var announcement: String?
    var selection: String?

    let locations: Locations

    init(locations: Locations = .resolved()) {
        self.locations = locations
        reload()
    }

    func reload() {
        let (recipes, faults) = Cookbook.load(locations)
        self.recipes = recipes
        self.loadFaults = faults
        if selection == nil || !visibleRecipes.contains(where: { $0.id == selection }) {
            selection = visibleRecipes.first?.id
        }
    }

    private func kitchen(_ operation: OperationSettings, recipes: [Recipe]) -> Kitchen {
        Kitchen(
            locations: locations, recipes: recipes, profile: operation.profile,
            environment: operation.environment)
    }

    private func operationSettings(for verb: Verb) -> OperationSettings? {
        switch OperationSettings.resolve(locations) {
        case .success(let operation):
            // Clear only a settings-resolution failure. A real housekeeping
            // failure remains until housekeeping itself succeeds.
            if housekeepingFault?.kind == .settingsInvalid
                || housekeepingFault?.kind == .settingsUnavailable
                || housekeepingFault?.kind == .runtimeEnvironmentInvalid {
                housekeepingFault = nil
            }
            return operation
        case .failure(let failure):
            housekeepingFault = OperationSettings.fault(failure, verb: verb)
            return nil
        }
    }

    // MARK: - Verbs

    /// Get FoodTruck's own house in order, then look at the machine.
    ///
    /// Housekeeping converges without being asked, because there is nothing to
    /// ask about: it writes only inside FoodTruck's own folder, and a person
    /// opening the app has already consented to the app existing. It stays
    /// silent unless it fails.
    func start() async {
        guard let operation = operationSettings(for: .audit) else {
            announce()
            return
        }
        await settleHousekeeping(operation)
        reload()
        await audit(operation)
    }

    private func settleHousekeeping(_ operation: OperationSettings) async {
        let chores = recipes.filter { $0.scope == .housekeeping }
        guard !chores.isEmpty else { return }
        activity = .auditing
        defer { activity = .idle }
        do {
            let service = try await kitchen(operation, recipes: chores)
                .converge(only: Set(chores.map(\.id)))
            for result in service.results { results[result.recipe] = result }
            if case .failed(let fault) = service.failed.first?.outcome {
                housekeepingFault = fault
            } else {
                housekeepingFault = nil
            }
        } catch {
            housekeepingFault = RecipeFault(
                kind: .recipeMalformed, recipe: "core", verb: .converge,
                args: ["recipe": "core"], detail: "\(error)")
        }
    }

    func audit() async {
        guard !activity.isBusy else { return }
        guard let operation = operationSettings(for: .audit) else {
            announce()
            return
        }
        await audit(operation)
    }

    private func audit(_ operation: OperationSettings) async {
        guard !activity.isBusy else { return }
        activity = .auditing
        defer { activity = .idle }

        let service = await kitchen(operation, recipes: recipes).inspect(.audit)
        apply(service)
        await recordInventory(from: service, operation: operation)
        announce()
    }

    /// - Parameter only: a single requested recipe; nil converges only recipes
    ///   whose current report contains work FoodTruck can actually perform.
    func converge(only: String? = nil) async {
        guard !activity.isBusy else { return }
        guard let operation = operationSettings(for: .converge) else {
            announce()
            return
        }
        let selected = only.map { Set([$0]) }
            ?? Set(visibleRecipes.filter { canConverge(recipeID: $0.id) }.map(\.id))
        guard !selected.isEmpty else { return }
        activity = .converging(recipe: only)
        defer { activity = .idle }

        do {
            let service = try await kitchen(operation, recipes: recipes)
                .converge(only: selected)
            apply(service)
            // Recipes can install other recipes, so the catalogue may have grown.
            reload()
            announce()
        } catch {
            // A graph that will not resolve is a FoodTruck bug, not a user
            // problem, and it must still arrive as a sentence rather than a
            // silent no-op.
            loadFaults.append(RecipeFault(
                kind: .recipeMalformed, recipe: only ?? "pantry", verb: .converge,
                args: ["recipe": only ?? "pantry"], detail: "\(error)"))
        }
    }

    private func apply(_ service: Service) {
        for result in service.results { results[result.recipe] = result }
        lastRun = Date()
    }

    private enum InventoryRecordOutcome: Sendable {
        case unchanged
        case recorded
        case unavailable
        case skipped
        case writeFailed(String)
        case historyFailed(String)
    }

    /// Keep the comparison point after presenting this audit. The snapshot came
    /// from the audit itself, so recording never launches programs or scans the
    /// machine a second time. CLI audits remain read-only because this is an app
    /// lifecycle decision, not engine behavior.
    private func recordInventory(
        from service: Service, operation: OperationSettings
    ) async {
        guard let captured = service.results.first(where: { $0.recipe == "env.inventory" }),
              let inventory = captured.inventory else { return }

        // The attachment is transport, not UI state. Release the large scan as
        // soon as it has crossed into the recording worker.
        if var result = results["env.inventory"] {
            result.inventory = nil
            results["env.inventory"] = result
        }

        let store = InventoryStore(
            root: locations.inventory, home: operation.profile.home,
            systemRoot: operation.profile.systemRoot,
            gitCandidates: operation.profile.inventory.gitCandidates)
        let environment = operation.environment
        let outcome = await Task.detached(priority: .utility) {
            guard !inventory.probeRefused else { return InventoryRecordOutcome.skipped }
            let needsWrite: Bool
            switch store.read() {
            case .invalid:
                // Preserve the unreadable record for diagnosis rather than
                // silently replacing the only comparison point.
                return InventoryRecordOutcome.skipped
            case .loaded(let previous):
                needsWrite = previous != inventory
            case .missing:
                needsWrite = true
            }

            if needsWrite {
                do {
                    try store.write(inventory)
                } catch {
                    return .writeFailed(error.localizedDescription)
                }
            }

            // Retry history even when the snapshot itself is unchanged. Git may
            // have been unavailable, or a previous commit may have failed after
            // the record was written; equality of JSON does not prove history is
            // complete.
            let commit = await store.commit(
                message: "\(inventory.host.describe) — "
                    + "\(inventory.environmentTools.count) programs, "
                    + "\(inventory.unmanaged.count) unmanaged",
                environment: environment)
            switch commit {
            case .recorded:
                return .recorded
            case .unchanged:
                return .unchanged
            case .unavailable:
                return .unavailable
            case .failed(let detail):
                return .historyFailed(
                    detail.trimmingCharacters(in: .whitespacesAndNewlines))
            }
        }.value

        switch outcome {
        case .writeFailed(let detail):
            appendInventoryHistoryNotice(
                id: "inventory.recordFailed",
                title: "finding.inventory.recordFailed",
                detail: detail,
                remedy: "finding.inventory.recordFailed.remedy")
        case .historyFailed(let detail):
            appendInventoryHistoryNotice(
                id: "inventory.historyFailed",
                title: "finding.inventory.historyFailed",
                detail: detail,
                remedy: "finding.inventory.historyFailed.remedy")
        case .unchanged, .recorded, .unavailable, .skipped:
            break
        }
    }

    private func appendInventoryHistoryNotice(
        id: String, title: String, detail: String, remedy: String
    ) {
        guard var result = results["env.inventory"] else { return }
        result.report.findings.removeAll { $0.id == id }
        result.report.findings.append(Finding(
            id: id, severity: .notice, title: title,
            observed: detail, fixable: false, remedy: remedy, section: .history))
        results["env.inventory"] = result
    }

    private func announce() {
        // Spoken by VoiceOver, so it says the outcome rather than describing the
        // screen: someone who cannot see the table still learns what happened.
        //
        // The clean wording states its scope for the same reason the visible
        // summary does. "Everything is where it should be" was removed from the
        // screen and left here, which left the overclaim in place for exactly
        // the people who cannot check it against the rest of the window.
        announcement = problemCount == 0
            ? t("a11y.announce.clean")
            : t("a11y.announce.drift", [
                "drift": String(driftCount),
                "blocked": String(blockedCount),
                "failed": String(failedCount),
              ])
    }

    // MARK: - Derived, for the sidebar and summary

    func outcome(for id: String) -> VerbOutcome? { results[id]?.outcome }
    func findings(for id: String) -> [Finding] { results[id]?.report.findings ?? [] }

    var driftCount: Int {
        visibleRecipes.filter { results[$0.id]?.outcome == .drift }.count
    }
    var blockedCount: Int {
        visibleRecipes.filter { results[$0.id]?.outcome == .blocked }.count
    }
    var failedCount: Int {
        let recipeFailures = visibleRecipes.filter {
            if case .failed = results[$0.id]?.outcome { return true }
            return false
        }.count
        return recipeFailures + loadFaults.count + (housekeepingFault == nil ? 0 : 1)
    }
    var problemCount: Int { driftCount + blockedCount + failedCount }
    var hasAnyResult: Bool { !results.isEmpty }

    /// Predicates that passed because something was verified. Deliberately not
    /// "checks that passed" -- a check that passed because nothing was asked of
    /// it is not evidence, and the summary must not spend it as though it were.
    var provenCount: Int {
        visibleRecipes.reduce(0) { $0 + (results[$1.id]?.report.provenCount ?? 0) }
    }
    var vacuousCount: Int {
        visibleRecipes.reduce(0) {
            $0 + (results[$1.id]?.report.checks.filter(\.vacuous).count ?? 0)
        }
    }

    /// One rule for both Fix controls: only required work which this recipe can
    /// actually resolve counts. A merely informational notice never enables it.
    func canConverge(recipeID: String) -> Bool {
        guard let result = results[recipeID], result.outcome == .drift else { return false }
        return !result.report.fixableActionFindings.isEmpty
    }

    /// Whether converging everything would actually do anything, so the primary
    /// button can be disabled rather than doing nothing and looking broken.
    var hasFixableWork: Bool {
        visibleRecipes.contains { canConverge(recipeID: $0.id) }
    }
}
