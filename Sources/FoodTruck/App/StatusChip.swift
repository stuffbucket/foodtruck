import SwiftUI
import FoodTruckKit

/// How a verdict looks, in one place.
///
/// Colour is never the only carrier. Every state has a distinct SF Symbol *and*
/// a word, so the row reads correctly for a colour-blind eye, at 40% contrast,
/// and through VoiceOver -- which is the same rule the terminal renderer
/// follows, for the same reason.
struct Verdict {
    let symbol: String
    let tint: Color
    let label: String

    init(_ outcome: VerbOutcome?) {
        switch outcome {
        case .converged:
            self.init(symbol: "checkmark.circle.fill", tint: .green, label: t("state.converged"))
        case .drift:
            self.init(symbol: "exclamationmark.triangle.fill", tint: .orange, label: t("state.drift"))
        case .blocked:
            self.init(symbol: "clock.fill", tint: .secondary, label: t("state.blocked"))
        case .failed:
            self.init(symbol: "xmark.octagon.fill", tint: .red, label: t("state.failed"))
        case nil:
            self.init(symbol: "circle.dashed", tint: .secondary, label: t("state.unknown"))
        }
    }

    init(_ severity: Severity) {
        switch severity {
        case .risk:
            self.init(symbol: "exclamationmark.octagon.fill", tint: .red,
                      label: t("severity.risk"))
        case .drift:
            self.init(symbol: "exclamationmark.triangle.fill", tint: .orange,
                      label: t("severity.drift"))
        case .notice:
            self.init(symbol: "info.circle", tint: .secondary,
                      label: t("severity.notice"))
        case .ok:
            self.init(symbol: "checkmark.circle", tint: .green,
                      label: t("severity.ok"))
        }
    }

    private init(symbol: String, tint: Color, label: String) {
        self.symbol = symbol; self.tint = tint; self.label = label
    }
}

/// The status badge used in the sidebar and the detail header.
struct StatusChip: View {
    let outcome: VerbOutcome?
    var showsLabel = true
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        let verdict = Verdict(outcome)
        HStack(spacing: 5) {
            Image(systemName: verdict.symbol)
                .foregroundStyle(verdict.tint)
                .imageScale(.small)
            if showsLabel {
                Text(verdict.label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, showsLabel ? 8 : 0)
        .padding(.vertical, showsLabel ? 3 : 0)
        .background {
            if showsLabel {
                Capsule().fill(
                    // Someone who has asked for less transparency gets a solid
                    // fill rather than a material -- honouring the setting, not
                    // approximating it.
                    reduceTransparency
                        ? AnyShapeStyle(verdict.tint.opacity(0.16))
                        : AnyShapeStyle(.quaternary))
            }
        }
        // One label for the pair, so VoiceOver says "Needs attention" rather
        // than reading an icon name and then the same word again.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(t("a11y.status", ["state": verdict.label]))
    }
}
