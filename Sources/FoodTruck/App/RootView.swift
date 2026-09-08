import SwiftUI
import FoodTruckKit

struct RootView: View {
    @State private var model = AppModel()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            if let id = model.selection,
               let recipe = model.visibleRecipes.first(where: { $0.id == id }) {
                if recipe.id == "env.inventory" {
                    InventoryDetail(model: model, recipe: recipe)
                        .id(recipe.id)
                } else {
                    RecipeDetail(model: model, recipe: recipe)
                        .id(recipe.id)
                }
            } else {
                ContentUnavailableView(t("empty.title"), systemImage: "shippingbox",
                                       description: Text(t("empty.body")))
            }
        }
        .safeAreaInset(edge: .top) {
            if model.housekeepingFault != nil || !model.loadFaults.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    if let fault = model.housekeepingFault {
                        FaultMessage(fault: fault)
                    }
                    ForEach(Array(model.loadFaults.enumerated()), id: \.offset) { _, fault in
                        FaultMessage(fault: fault)
                    }
                }
                .padding(12)
                .background(.bar)
            }
        }
        .navigationTitle(t("window.title"))
        .toolbar { toolbar }
        .task {
            // Settle FoodTruck's own house, then audit -- both without being
            // asked. The audit leaves the user's environment untouched and only
            // updates FoodTruck's private history, so the answer is ready on open.
            if !model.hasAnyResult { await model.start() }
        }
        .onChange(of: model.announcement) { _, new in
            guard let new else { return }
            AccessibilityNotification.Announcement(new).post()
            model.announcement = nil
        }
    }

    /// e.g. "Nothing to fix · 3 checks passed"
    private var summaryWhenClean: String {
        var parts = [t("summary.nothingToFix"), tn("summary.proven", model.provenCount)]
        if model.vacuousCount > 0 {
            parts.append(tn("summary.vacuous", model.vacuousCount))
        }
        return parts.joined(separator: t("list.separator"))
    }

    private var issueSummary: String {
        [
            (model.driftCount, "summary.drift"),
            (model.blockedCount, "summary.blocked"),
            (model.failedCount, "summary.failed"),
        ].compactMap { count, key in count > 0 ? tn(key, count) : nil }
            .joined(separator: t("list.separator"))
    }

    private var summaryVerdict: (symbol: String, tint: Color) {
        if model.failedCount > 0 { return ("xmark.octagon.fill", .red) }
        if model.driftCount > 0 { return ("exclamationmark.triangle.fill", .orange) }
        if model.blockedCount > 0 { return ("clock.fill", .secondary) }
        return ("checkmark.circle.fill", .green)
    }

    private var sidebar: some View {
        List(selection: $model.selection) {
            ForEach(model.visibleRecipes) { recipe in
                RecipeRow(recipe: recipe,
                          outcome: model.outcome(for: recipe.id),
                          actions: model.results[recipe.id]?.report.findingsRequiringAction.count ?? 0)
                    .tag(recipe.id)
            }
        }
        .listStyle(.sidebar)
        .navigationSplitViewColumnWidth(min: 220, ideal: 260)
        // A Section footer is not rendered by the sidebar list style, so the
        // running total lives on the safe-area edge instead -- always visible,
        // and it does not scroll away with the list.
        .safeAreaInset(edge: .bottom) {
            HStack(spacing: 6) {
                Image(systemName: summaryVerdict.symbol)
                    .foregroundStyle(summaryVerdict.tint)
                    .imageScale(.small)
                    .accessibilityHidden(true)
                // States its own scope rather than asserting "everything".
                // FoodTruck can only speak for the recipes it has, and saying
                // how many predicates actually proved something is the
                // difference between a status and a claim.
                Text(model.problemCount == 0 ? summaryWhenClean : issueSummary)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .help(model.problemCount == 0 ? t("summary.clean.help") : "")
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background(.bar)
            .accessibilityElement(children: .combine)
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Button {
                Task { await model.converge() }
            } label: {
                Label(t("action.converge"), systemImage: "wand.and.sparkles")
            }
            .help(t("action.converge.help"))
            .disabled(model.activity.isBusy || !model.hasFixableWork)
        }
        ToolbarItem(placement: .automatic) {
            Button {
                Task { await model.audit() }
            } label: {
                Label(t("action.audit"), systemImage: "arrow.clockwise")
            }
            .help(t("action.audit.help"))
            .disabled(model.activity.isBusy)
        }
        ToolbarItem(placement: .automatic) {
            // Progress is a real control's state, not a spinner bolted on: the
            // buttons above disable, and this says why.
            if model.activity.isBusy {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel(t("a11y.busy"))
            }
        }
    }
}

struct RecipeRow: View {
    let recipe: Recipe
    let outcome: VerbOutcome?
    let actions: Int

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: recipe.symbol)
                .foregroundStyle(.secondary)
                .frame(width: 18)
            Text(t(recipe.name))
                .lineLimit(1)
            Spacer(minLength: 6)
            StatusChip(outcome: outcome, showsLabel: false)
        }
        .padding(.vertical, 1)
        // The row is one thing to VoiceOver, phrased as a sentence, rather than
        // four fragments read in layout order.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(tn("a11y.recipe.actions", actions, [
            "name": t(recipe.name),
            "state": Verdict(outcome).label,
        ]))
    }
}
