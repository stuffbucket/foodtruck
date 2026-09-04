import SwiftUI
import FoodTruckKit

struct RecipeDetail: View {
    let model: AppModel
    let recipe: Recipe
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var result: VerbResult? { model.results[recipe.id] }
    private var findings: [Finding] { result?.report.findings ?? [] }

    var body: some View {
        Form {
            Section {
                LabeledContent(t("detail.blast")) {
                    Text(t("blast.\(recipe.blast.rawValue)"))
                }
            } header: {
                header
            }


            if !findings.isEmpty {
                Section {
                    ForEach(findings) { finding in
                        FindingRow(finding: finding)
                    }
                    if findings.contains(where: \.fixable) {
                        Button(t("action.converge.one")) {
                            Task { await model.converge(only: recipe.id) }
                        }
                        .disabled(model.activity.isBusy)
                    }
                } header: {
                    Text(t("detail.findings"))
                }
            }

            if let checks = result?.report.checks, !checks.isEmpty {
                Section(t("detail.checked")) {
                    ForEach(checks) { check in
                        CheckRow(check: check)
                    }
                }
            } else if result != nil {
                Section {
                    // No checks and no findings means the recipe declares
                    // nothing we can verify -- say that, rather than implying
                    // we looked and were satisfied.
                    Label(t("detail.nothingToCheck"), systemImage: "questionmark.circle")
                        .foregroundStyle(.secondary)
                }
            }

            if let facts = result?.report.facts, !facts.isEmpty {
                Section {
                    // Collapsed by default, and it matters that it is. Facts are
                    // diagnostic detail; left expanded, five absolute paths
                    // wrapped over three lines each pushed the findings -- the
                    // thing the person actually came for -- below the fold.
                    DisclosureGroup(t("detail.facts")) {
                        ForEach(facts.sorted(by: { $0.key < $1.key }), id: \.key) { key, value in
                            LabeledContent(key) {
                                Text(Self.abbreviate(value))
                                    .font(.callout.monospaced())
                                    .foregroundStyle(.secondary)
                                    // Middle truncation keeps both the useful
                                    // ends of a path: which volume, and which
                                    // leaf. Head or tail alone loses one.
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                    .textSelection(.enabled)
                                    .help(value)
                            }
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle(t(recipe.name))
        .navigationSubtitle(recipe.id)
    }

    /// `~` for the home directory, the way every other Mac tool writes it.
    static func abbreviate(_ value: String) -> String {
        let home = ProcessInfo.processInfo.environment["HOME"] ?? NSHomeDirectory()
        guard !home.isEmpty, value.hasPrefix(home) else { return value }
        return "~" + value.dropFirst(home.count)
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: recipe.symbol)
                .font(.title2)
                .foregroundStyle(.tint)
                // Decorative: the name is right beside it, and hearing the
                // symbol read aloud would be noise.
                .accessibilityHidden(true)
            // The window title already carries the name; repeating it here
            // would be the kind of redundancy that reads as carelessness.
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

    private var symbol: String {
        switch finding.severity {
        case .risk:   "exclamationmark.octagon.fill"
        case .drift:  "square"                       // an unticked box
        case .notice: "info.circle"
        case .ok:     "checkmark.circle"
        }
    }
    private var tint: Color {
        switch finding.severity {
        case .risk: .red
        case .drift: .orange
        case .notice, .ok: .secondary
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: symbol)
                .foregroundStyle(tint)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(t(finding.title, finding.args))
                    .fixedSize(horizontal: false, vertical: true)
                if let remedy = finding.remedy {
                    // A finding FoodTruck cannot fix must always say what the
                    // person should do instead. This is the last stop before a
                    // dead end, so it is never conditional on space.
                    Text(t(remedy, finding.args))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "\(t("severity.\(finding.severity.rawValue)")). \(t(finding.title, finding.args))")
        .accessibilityHint(finding.remedy.map { t($0, finding.args) } ?? "")
    }
}


struct CheckRow: View {
    let check: Check

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: check.vacuous ? "minus.circle"
                  : check.passed ? "checkmark.circle.fill" : "square")
                .foregroundStyle(check.vacuous ? AnyShapeStyle(.secondary)
                                 : check.passed ? AnyShapeStyle(Color.green)
                                 : AnyShapeStyle(Color.orange))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(check.label)
                    .foregroundStyle(check.vacuous ? .secondary : .primary)
                    .fixedSize(horizontal: false, vertical: true)
                if check.vacuous {
                    // The distinction that matters: this passed because nothing
                    // was asked of it, not because anything was verified.
                    Text(t("check.vacuous"))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 1)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "\(check.label). \(t(check.vacuous ? "check.vacuous" : check.passed ? "check.passed" : "check.failed"))")
    }
}
