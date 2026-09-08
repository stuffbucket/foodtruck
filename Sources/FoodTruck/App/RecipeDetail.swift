import SwiftUI
import FoodTruckKit

struct RecipeDetail: View {
    let model: AppModel
    let recipe: Recipe
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var diagnosticsExpanded = false

    private let visibleFindingLimit = 6

    private var result: VerbResult? { model.results[recipe.id] }
    private var report: RecipeReport { result?.report ?? RecipeReport() }
    private var actionFindings: [Finding] { report.findingsRequiringAction }
    private var observations: [Finding] {
        result?.outcome == .blocked ? [] : report.observations
    }
    private var fixableCount: Int { report.fixableActionFindings.count }
    private var checksByEvidence: [Check] {
        report.checks.enumerated().sorted { lhs, rhs in
            lhs.element.vacuous == rhs.element.vacuous
                ? lhs.offset < rhs.offset
                : !lhs.element.vacuous
        }.map(\.element)
    }
    private var fault: RecipeFault? {
        guard let outcome = result?.outcome,
              case .failed(let fault) = outcome else { return nil }
        return fault
    }

    private var stateSummary: String {
        switch result?.outcome {
        case .converged:
            return t("detail.noAction")
        case .drift:
            return actionFindings.first.map { t($0.title, $0.args) }
                ?? t("state.drift")
        case .blocked:
            guard let finding = report.findings.first else { return t("state.blocked") }
            return t(finding.title, finding.args)
        case .failed(let fault):
            return t(fault.title, fault.args)
        case nil:
            return t("state.unknown")
        }
    }

    private var convergeLabel: String {
        recipe.convergeLabel.map { t($0) } ?? t("action.converge.one")
    }

    private var convergeHelp: String? {
        recipe.convergeHelp.map { t($0) }
    }

    private var nextSteps: [String] {
        var values: [String] = []
        if let fault {
            values.append(t(fault.remedy, fault.args))
        }
        let candidates = result?.outcome == .blocked
            ? report.findings
            : actionFindings.filter { !$0.fixable }
        values += candidates.compactMap { finding in
            finding.remedy.map { t($0, finding.args) }
        }
        return Self.unique(values)
    }

    private var observationRemedies: [String] {
        Self.unique(observations.compactMap { finding in
            finding.remedy.map { t($0, finding.args) }
        })
    }

    var body: some View {
        Form {
            Section {
                if result?.outcome == .drift {
                    findingRows(actionFindings)
                } else {
                    Text(stateSummary)
                        .fixedSize(horizontal: false, vertical: true)
                    if result?.outcome == .converged {
                        ForEach(checksByEvidence) { check in
                            CheckRow(check: check)
                        }
                    }
                }
            } header: {
                header
            }

            if fixableCount > 0 {
                Section(t("detail.action")) {
                    if let convergeHelp {
                        Text(convergeHelp)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    LabeledContent(t("detail.changeScope")) {
                        Text(t("blast.\(recipe.blast.rawValue)"))
                    }
                    Button(convergeLabel) {
                        Task { await model.converge(only: recipe.id) }
                    }
                    .disabled(model.activity.isBusy || !model.canConverge(recipeID: recipe.id))
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

            if let result {
                Section {
                    DisclosureGroup(
                        t("detail.diagnostics"),
                        isExpanded: $diagnosticsExpanded
                    ) {
                        diagnosticContent(result)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .padding(.bottom, 18)
        .navigationTitle(t(recipe.name))
        .onChange(of: recipe.id) {
            diagnosticsExpanded = false
        }
    }

    @ViewBuilder
    private func findingRows(_ findings: [Finding], showsEvidence: Bool = true) -> some View {
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
    private func diagnosticContent(_ result: VerbResult) -> some View {
        if result.outcome != .converged {
            if result.report.checks.isEmpty {
                Label(t("detail.nothingToCheck"), systemImage: "questionmark.circle")
                    .foregroundStyle(.secondary)
            } else {
                Text(t("detail.checked"))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                ForEach(result.report.checks) { check in
                    CheckRow(check: check)
                }
            }
        }

        if !observations.isEmpty {
            Divider()
            Text(tn("detail.observations", observations.count))
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            findingRows(observations, showsEvidence: false)
            ForEach(observationRemedies, id: \.self) { remedy in
                Label {
                    Text(remedy)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "lightbulb")
                        .foregroundStyle(.secondary)
                }
            }
        }

        if !result.report.facts.isEmpty {
            Divider()
            Text(t("detail.facts"))
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            ForEach(result.report.facts.sorted(by: { $0.key < $1.key }), id: \.key) { key, value in
                LabeledContent(key) {
                    Text(Self.abbreviate(value))
                        .font(.callout.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                        .help(value)
                }
            }
        }

        if !result.log.isEmpty {
            Divider()
            Text(t("detail.runLog"))
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(result.log)
                .font(.callout.monospaced())
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        }

        if let detail = fault?.detail {
            Divider()
            Text(detail)
                .font(.callout.monospaced())
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        }
    }

    /// `~` for the home directory, the way every other Mac tool writes it.
    static func abbreviate(_ value: String) -> String {
        let home = ProcessInfo.processInfo.environment["HOME"] ?? NSHomeDirectory()
        guard !home.isEmpty, value.hasPrefix(home) else { return value }
        return "~" + value.dropFirst(home.count)
    }

    private static func unique(_ values: [String]) -> [String] {
        var seen: Set<String> = []
        return values.filter { seen.insert($0).inserted }
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
            if recipe.customised {
                Label(t("recipe.customised"), systemImage: "pencil")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .labelStyle(.titleAndIcon)
                    .help(t("recipe.customised.help"))
            }
            StatusChip(outcome: result?.outcome)
                .animation(reduceMotion ? nil : .snappy, value: result?.outcome)
        }
        .padding(.bottom, 6)
        .textCase(nil)
    }
}

struct FindingRow: View {
    let finding: Finding
    var showsEvidence = true

    var body: some View {
        let verdict = Verdict(finding.severity)
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: verdict.symbol)
                    .foregroundStyle(verdict.tint)
                    .accessibilityLabel(verdict.label)
                Text(t(finding.title, finding.args))
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            if showsEvidence, let observed = finding.observed {
                LabeledContent(t("detail.current")) {
                    Text(RecipeDetail.abbreviate(observed))
                        .font(.callout.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if showsEvidence, let desired = finding.desired {
                LabeledContent(t("detail.expected")) {
                    Text(RecipeDetail.abbreviate(desired))
                        .font(.callout.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(.vertical, 2)
    }
}

struct CheckRow: View {
    let check: Check

    /// A builtin's label is a message key; a recipe on disk supplies prose.
    /// `t` passes prose through untouched and records no miss for it, so one
    /// call serves both.
    private var label: String { t(check.label) }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: check.vacuous ? "minus.circle"
                  : check.passed ? "checkmark.circle.fill" : "square")
                .foregroundStyle(check.vacuous ? AnyShapeStyle(.secondary)
                                 : check.passed ? AnyShapeStyle(Color.green)
                                 : AnyShapeStyle(Color.orange))
                .accessibilityHidden(true)
            Text(check.vacuous ? t("check.vacuous") : label)
                .foregroundStyle(check.vacuous ? .secondary : .primary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.vertical, 1)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(check.vacuous
            ? t("check.vacuous")
            : "\(label). \(t(check.passed ? "check.passed" : "check.failed"))")
    }
}

struct FaultMessage: View {
    let fault: RecipeFault

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(t(fault.title, fault.args)).fontWeight(.medium)
                Text(t(fault.remedy, fault.args))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let detail = fault.detail {
                    DisclosureGroup(t("detail.diagnostics")) {
                        Text(detail)
                            .font(.callout.monospaced())
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }
            }
            Spacer(minLength: 0)
        }
    }
}
