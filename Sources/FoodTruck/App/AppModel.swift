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
        let (recipes, faults) = Pantry.load(locations)
        self.recipes = recipes
        self.loadFaults = faults
        if selection == nil || !recipes.contains(where: { $0.id == selection }) {
            selection = recipes.first?.id
        }
    }

    private var kitchen: Kitchen { Kitchen(locations: locations, recipes: recipes) }

    // MARK: - Verbs

    func audit() async {
        guard !activity.isBusy else { return }
        activity = .auditing
        defer { activity = .idle }

        let service = await kitchen.inspect(.audit)
        apply(service)
        announce(service)
    }

    /// - Parameter only: nil converges everything the profile asks for.
    func converge(only: String? = nil) async {
        guard !activity.isBusy else { return }
        activity = .converging(recipe: only)
        defer { activity = .idle }

        do {
            let service = try await kitchen.converge(only: only.map { [$0] })
            apply(service)
            // Recipes can install other recipes, so the catalogue may have grown.
            reload()
            announce(service)
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

    private func announce(_ service: Service) {
        // Spoken by VoiceOver, so it says the outcome rather than describing the
        // screen: someone who cannot see the table still learns what happened.
        announcement = service.isClean
            ? t("a11y.announce.clean")
            : t("a11y.announce.drift", [
                "drift": String(service.drifted.count),
                "blocked": String(service.blocked.count),
                "failed": String(service.failed.count),
              ])
    }

    // MARK: - Derived, for the sidebar and summary

    func outcome(for id: String) -> VerbOutcome? { results[id]?.outcome }
    func findings(for id: String) -> [Finding] { results[id]?.report.findings ?? [] }

    var needingAttention: Int {
        results.values.filter { $0.outcome == .drift }.count
    }
    var hasAnyResult: Bool { !results.isEmpty }

    /// Whether converging everything would actually do anything, so the primary
    /// button can be disabled rather than doing nothing and looking broken.
    var hasFixableWork: Bool {
        results.values.contains { result in
            result.outcome == .drift && result.report.findings.contains(where: \.fixable)
        }
    }
}
