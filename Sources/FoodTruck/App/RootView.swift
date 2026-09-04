import SwiftUI
import FoodTruckKit

struct RootView: View {
    @State private var model = AppModel()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            if let id = model.selection, let recipe = model.recipes.first(where: { $0.id == id }) {
                RecipeDetail(model: model, recipe: recipe)
            } else {
                ContentUnavailableView(t("empty.title"), systemImage: "shippingbox",
                                       description: Text(t("empty.body")))
            }
        }
        .navigationTitle(t("window.title"))
        .toolbar { toolbar }
        .task {
            // Audit on open. It changes nothing, so there is no reason to make
            // someone ask for the answer they came here for.
            if !model.hasAnyResult { await model.audit() }
        }
        .onChange(of: model.announcement) { _, new in
            guard let new else { return }
            AccessibilityNotification.Announcement(new).post()
            model.announcement = nil
        }
    }

    private var sidebar: some View {
        List(selection: $model.selection) {
            ForEach(model.recipes) { recipe in
                RecipeRow(recipe: recipe,
                          outcome: model.outcome(for: recipe.id),
                          findings: model.findings(for: recipe.id).count)
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
                Image(systemName: model.needingAttention == 0
                      ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(model.needingAttention == 0 ? .green : .orange)
                    .imageScale(.small)
                    .accessibilityHidden(true)
                Text(model.needingAttention == 0
                     ? t("summary.clean")
                     : tn("summary.attention", model.needingAttention))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
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
    let findings: Int

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
        .accessibilityLabel(t("a11y.recipe.row", [
            "name": t(recipe.name),
            "state": Verdict(outcome).label,
            "findings": String(findings),
        ]))
    }
}
