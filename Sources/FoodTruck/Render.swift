import Foundation
import FoodTruckKit

/// Terminal rendering.
///
/// The dotfiles crowd will run this far more often than they open the window, so
/// it gets the same care: colour only when a human is looking (`NO_COLOR`, and a
/// real TTY), alignment that survives a narrow window, and never a wall of log
/// output unless something actually went wrong.
enum Render {
    static let colour: Bool = {
        ProcessInfo.processInfo.environment["NO_COLOR"] == nil
            && ProcessInfo.processInfo.environment["TERM"] != "dumb"
            && isatty(STDOUT_FILENO) == 1
    }()

    public static func paint(_ s: String, _ code: String) -> String {
        colour ? "\u{1B}[\(code)m\(s)\u{1B}[0m" : s
    }

    static func outcomeToken(_ o: VerbOutcome) -> String {
        switch o {
        case .converged: return "converged"
        case .drift: return "drift"
        case .blocked: return "blocked"
        case .failed: return "failed"
        }
    }

    /// A glyph plus a word, never a glyph alone. Colour and shape both carry the
    /// meaning, so the line still reads correctly in a monochrome terminal, for
    /// a colour-blind reader, and piped through `grep`. This is the same rule
    /// the window follows.
    static func badge(_ o: VerbOutcome) -> String {
        // The same `state.*` keys the window uses, so the two faces of the
        // binary cannot drift apart in wording -- or in translation.
        func pad(_ s: String) -> String {
            let width = 9
            return s.count >= width ? s
                : s + String(repeating: " ", count: width - s.count)
        }
        switch o {
        case .converged: return paint("✓ " + pad(t("state.converged")), "32")
        case .drift:     return paint("▲ " + pad(t("state.drift")), "33")
        case .blocked:   return paint("· " + pad(t("state.blocked")), "90")
        case .failed:    return paint("✗ " + pad(t("state.failed")), "31")
        }
    }

    /// Said once, plainly, when FoodTruck has not finished installing itself.
    /// One sentence and one command -- not a list of internal chores.
    static func setupNeeded() {
        print(paint("• " + t("setup.needed"), "33"))
        print("  " + paint(t("setup.needed.remedy"), "36"))
        print("")
    }

    static func service(_ service: Service, faults: [RecipeFault]) {
        for fault in faults { self.fault(fault) }

        let width = service.results.map(\.recipe.count).max() ?? 20
        for r in service.results {
            let id = r.recipe.padding(toLength: max(width, 20), withPad: " ", startingAt: 0)
            print("\(badge(r.outcome))  \(paint(id, "1"))  \(t(descriptorName(r)))")
            for finding in r.report.findings.prefix(6) {
                // Shape carries the meaning as well as colour: an unmet goal is
                // an unticked box, a notice is a dot, a risk is a bang. Reads
                // correctly in a monochrome terminal and for a colour-blind eye.
                let bullet = switch finding.severity {
                case .risk: paint("!", "31")
                case .drift: "☐"
                default: "·"
                }
                print("             \(bullet) \(t(finding.title, finding.args))")
                if let remedy = finding.remedy {
                    print("               \(paint("→ " + t(remedy, finding.args), "36"))")
                }
            }
            if r.report.findings.count > 6 {
                print("             … " + tn("findings.more", r.report.findings.count - 6))
            }
            // A converged recipe lists what it actually evaluated. "Ready"
            // with nothing under it is the answer that cannot be checked, and
            // the whole point is that this one can.
            if r.outcome == .converged {
                for check in r.report.checks {
                    if check.vacuous {
                        print("             \(paint("·", "90")) \(check.label) "
                              + paint("— " + t("check.vacuous"), "90"))
                    } else {
                        print("             \(paint("✓", "32")) \(check.label)")
                    }
                }
            }
            if case .failed(let f) = r.outcome { fault(f, indent: "             ") }
        }

        // Nothing to report on is not the same as nothing wrong. Saying
        // "everything is where it should be" about an empty list is exactly the
        // confidently-wrong answer this whole path exists to avoid.
        guard !service.results.isEmpty else { return }

        print("")
        let clean = service.isClean
        // Each clause is pluralised on its own count, and a zero clause is
        // omitted entirely. Cramming three counts into one sentence forces a
        // single plural form onto all three -- which is how "1 requieren
        // atención" happens -- and "0 waiting, 0 failed" was noise anyway.
        let clauses = [
            (service.drifted.count, "summary.drift"),
            (service.blocked.count, "summary.blocked"),
            (service.failed.count, "summary.failed"),
        ].compactMap { count, key in count > 0 ? tn(key, count) : nil }

        // "Everything is where it should be" was a claim FoodTruck had not
        // earned. It rested on two predicates -- one of which passed vacuously
        // -- on a machine with seven other toolchains it had never looked at.
        // The clean summary now states its own scope, so the sentence cannot
        // outrun the evidence behind it.
        let checks = service.results.flatMap(\.report.checks)
        let proven = checks.filter { $0.passed && !$0.vacuous }.count
        let vacuous = checks.filter(\.vacuous).count

        let summary: String
        if clean {
            var parts = [paint(t("summary.nothingToFix"), "32"), tn("summary.proven", proven)]
            if vacuous > 0 { parts.append(paint(tn("summary.vacuous", vacuous), "90")) }
            summary = parts.joined(separator: t("list.separator"))
        } else {
            summary = clauses.joined(separator: t("list.separator"))
        }
        print("\(summary)  \(paint(String(format: "(%.1fs)", service.duration), "90"))")
        if !clean && service.verb.isReadOnly {
            print(paint(t("summary.hint"), "36"))
        }
    }

    /// A fault always prints three things: what, why, and the next step. If a
    /// code path can produce a message without a remedy, that is a bug in the
    /// code path, not a formatting choice here.
    static func fault(_ f: RecipeFault, indent: String = "") {
        print("\(indent)\(paint("✗ " + t(f.title, f.args), "31"))")
        print("\(indent)  \(paint(t(f.remedy, f.args), "36"))")
        if let detail = f.detail, ProcessInfo.processInfo.environment["FOODTRUCK_DEBUG"] != nil {
            for line in detail.split(separator: "\n").prefix(20) {
                print("\(indent)  \(paint(String(line), "90"))")
            }
        } else if f.detail != nil {
            print("\(indent)  \(paint(t("fault.detail.hint"), "90"))")
        }
    }

    private static func descriptorName(_ r: VerbResult) -> String {
        "recipe.\(r.recipe).name"
    }
}
