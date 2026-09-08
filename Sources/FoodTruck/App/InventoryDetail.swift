import SwiftUI
import FoodTruckKit

/// Inventory answers a different question from a desired-state recipe: it
/// explains what can affect the command that runs, then records the observation
/// for the next comparison. It therefore has evidence and manual decisions, but
/// never a Fix action.
struct InventoryDetail: View {
    let model: AppModel
    let recipe: Recipe
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var worthKnowingExpanded = false
    @State private var diagnosticsExpanded = false

    private let visibleFindingLimit = 6

    private var result: VerbResult? { model.results[recipe.id] }
    private var report: RecipeReport { result?.report ?? RecipeReport() }
    private var consequences: [Finding] { findings(in: .attention) }
    private var blockedFindings: [Finding] {
        result?.outcome == .blocked ? report.findings : []
    }
    private var changes: [Finding] { findings(in: .change) }
    private var historyIssues: [Finding] { findings(in: .history) }
    private var worthKnowing: [Finding] {
        findings(in: .observation).filter { finding in
            !blockedFindings.contains(where: { $0.id == finding.id })
        }
    }
    private func findings(in section: Finding.Section) -> [Finding] {
        report.findings.filter { inventorySection(for: $0) == section }
    }

    /// Reports persisted before Finding gained a section still need a safe home.
    /// This compatibility path preserves the old Inventory layout; current
    /// reports never depend on IDs for presentation.
    private func inventorySection(for finding: Finding) -> Finding.Section {
        if let section = finding.section { return section }
        if finding.severity >= .drift { return .attention }
        switch finding.id {
        case "inventory.unrecorded", "inventory.host.changed", "inventory.managers.changed":
            return .change
        case let id where id.hasPrefix("inventory.coverage.")
            || id.hasPrefix("inventory.change.")
            || id.hasPrefix("inventory.software.coverage.")
            || id.hasPrefix("inventory.software.change."):
            return .change
        case "inventory.nogit", "inventory.recordFailed", "inventory.historyFailed",
             "inventory.snapshotUnreadable", "inventory.probeRefused",
             "inventory.softwareDiscoveryRefused":
            return .history
        default:
            return .observation
        }
    }

    private var nextSteps: [String] {
        Self.unique((consequences + blockedFindings + historyIssues).compactMap { finding in
            finding.remedy.map { t($0, finding.args) }
        })
    }
    private var programCount: String { report.facts["programs"] ?? "—" }
    private var softwareCount: String { report.facts["software"] ?? "—" }
    private var rootCount: String { report.facts["searched"] ?? "—" }
    private var managerCount: Int {
        report.facts.keys.filter { $0.hasPrefix("manager.") }.count
    }
    private var fault: RecipeFault? {
        guard case .failed(let fault) = result?.outcome else { return nil }
        return fault
    }

    var body: some View {
        Form {
            Section {
                if let fault {
                    FaultMessage(fault: fault)
                } else if result == nil {
                    Text(t("state.unknown"))
                } else if result?.outcome == .blocked {
                    if blockedFindings.isEmpty {
                        Text(t("state.blocked"))
                    } else {
                        findingRows(blockedFindings, showsEvidence: true)
                    }
                } else {
                    Text(t(consequences.isEmpty
                           ? "inventory.overview.clean"
                           : "inventory.overview.attention"))
                        .fixedSize(horizontal: false, vertical: true)
                    LabeledContent(t("inventory.overview.programs")) {
                        Text(programCount).monospacedDigit()
                    }
                    LabeledContent(t("inventory.overview.software")) {
                        Text(softwareCount).monospacedDigit()
                    }
                    LabeledContent(t("inventory.overview.locations")) {
                        Text(rootCount).monospacedDigit()
                    }
                    LabeledContent(t("inventory.overview.managers")) {
                        Text(String(managerCount)).monospacedDigit()
                    }
                    ForEach(report.checks) { check in
                        CheckRow(check: check)
                    }
                }
            } header: {
                header
            }

            if !consequences.isEmpty {
                Section(t("detail.findings")) {
                    findingRows(consequences, showsEvidence: true)
                }
            }

            if !nextSteps.isEmpty {
                Section(t("detail.nextSteps")) {
                    ForEach(nextSteps, id: \.self) { step in
                        Label {
                            Text(step)
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                        } icon: {
                            Image(systemName: "arrow.right.circle")
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }

            if !changes.isEmpty {
                Section {
                    Text(t("inventory.changes.explanation"))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    findingRows(changes)
                } header: {
                    Text(t("inventory.changes.title"))
                }
            }

            if !historyIssues.isEmpty {
                Section(t("inventory.history.title")) {
                    findingRows(historyIssues, showsEvidence: true)
                }
            }

            if !worthKnowing.isEmpty {
                Section {
                    DisclosureGroup(
                        tn("inventory.worthKnowing", worthKnowing.count),
                        isExpanded: $worthKnowingExpanded
                    ) {
                        findingRows(worthKnowing)
                    }
                }
            }

            if let result {
                Section {
                    DisclosureGroup(
                        t("detail.diagnostics"),
                        isExpanded: $diagnosticsExpanded
                    ) {
                        diagnostics(result)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .padding(.bottom, 18)
        .navigationTitle(t(recipe.name))
    }

    @ViewBuilder
    private func findingRows(
        _ findings: [Finding], showsEvidence: Bool = false
    ) -> some View {
        ForEach(Array(findings.prefix(visibleFindingLimit))) { finding in
            FindingRow(finding: finding, showsEvidence: showsEvidence)
        }
        if findings.count > visibleFindingLimit {
            DisclosureGroup(tn("findings.more", findings.count - visibleFindingLimit)) {
                ForEach(Array(findings.dropFirst(visibleFindingLimit))) { finding in
                    FindingRow(finding: finding, showsEvidence: showsEvidence)
                }
            }
        }
    }

    @ViewBuilder
    private func diagnostics(_ result: VerbResult) -> some View {
        ForEach(result.report.facts.sorted(by: { $0.key < $1.key }), id: \.key) { key, value in
            LabeledContent(key) {
                Text(RecipeDetail.abbreviate(value))
                    .font(.callout.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                    .help(value)
            }
        }
        if !result.log.isEmpty {
            Divider()
            Text(result.log)
                .font(.callout.monospaced())
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: recipe.symbol)
                .font(.title2)
                .foregroundStyle(.tint)
                .accessibilityHidden(true)
            Text(t(recipe.summary))
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
            StatusChip(outcome: result?.outcome)
                .animation(reduceMotion ? nil : .snappy, value: result?.outcome)
        }
        .padding(.bottom, 6)
        .textCase(nil)
    }

    private static func unique(_ values: [String]) -> [String] {
        var seen: Set<String> = []
        return values.filter { seen.insert($0).inserted }
    }
}
