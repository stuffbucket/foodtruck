import Foundation

/// One complete inventory observation and the snapshot state it was compared
/// against. Both the recipe and the standalone CLI come through this path so a
/// recorded probe answer is reusable regardless of which interface asks next.
public struct InventorySurveyResult: Sendable {
    public let prior: InventoryStore.Load
    public let inventory: Inventory

    public init(prior: InventoryStore.Load, inventory: Inventory) {
        self.prior = prior
        self.inventory = inventory
    }
}

public enum InventorySurvey {
    /// Read the comparison point before scanning or probing. A valid prior
    /// snapshot supplies the probe cache; missing and invalid records remain
    /// distinguishable to the caller, which decides whether writing is allowed.
    public static func run(
        home: URL,
        locations: Locations,
        environment: [String: String],
        settings: ResolvedInventorySettings,
        store: InventoryStore
    ) async -> InventorySurveyResult {
        let prior = store.read()
        let previous: Inventory?
        if case .loaded(let inventory) = prior { previous = inventory }
        else { previous = nil }

        let inventory = await Inventory
            .scan(
                home: home, locations: locations, settings: settings,
                systemRoot: store.systemRoot)
            .probingVersions(
                home: home, environment: environment, settings: settings,
                systemRoot: store.systemRoot, reusing: previous)
        return InventorySurveyResult(prior: prior, inventory: inventory)
    }
}
