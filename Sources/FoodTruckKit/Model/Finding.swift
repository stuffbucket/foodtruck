import Foundation

/// How much a finding matters. Ordered, so a list can sort by it.
public enum Severity: String, Codable, Sendable, Comparable, CaseIterable {
    /// Everything a recipe wanted is present and pinned.
    case ok
    /// Works, but not how the profile asked -- unpinned, stale, or drifted.
    case notice
    /// A thing the profile requires is missing or wrong.
    case drift
    /// Actively unsafe: an unpinned supply chain, a compromised checksum, a
    /// credential in the wrong place.
    case risk

    private var rank: Int { Severity.allCases.firstIndex(of: self)! }
    public static func < (a: Severity, b: Severity) -> Bool { a.rank < b.rank }
}

/// One specific, nameable difference between what is and what should be.
///
/// A finding is never a sentence. It is a structured claim, and the sentence is
/// produced at render time in the user's language. This is why `title` is a
/// message key rather than English: a graphic designer reviewing the Japanese
/// build must see a real translation, not an English fallback with a
/// well-designed box around it.
public struct Finding: Codable, Sendable, Identifiable, Equatable {
    public var id: String
    public var severity: Severity
    /// Localisation key, e.g. `finding.tool.missing`. Resolved via `L10n`.
    public var title: String
    /// Values interpolated into the localised string, by name.
    public var args: [String: String]
    /// What the machine actually reports right now.
    public var observed: String?
    /// What the profile asked for.
    public var desired: String?
    /// Whether `converge` on this recipe is expected to resolve this finding.
    /// A finding that is not fixable must say what the human should do
    /// instead -- there are no dead ends.
    public var fixable: Bool
    /// Localisation key for the human's next step when `fixable` is false.
    public var remedy: String?

    public init(
        id: String,
        severity: Severity,
        title: String,
        args: [String: String] = [:],
        observed: String? = nil,
        desired: String? = nil,
        fixable: Bool = true,
        remedy: String? = nil
    ) {
        self.id = id
        self.severity = severity
        self.title = title
        self.args = args
        self.observed = observed
        self.desired = desired
        self.fixable = fixable
        self.remedy = remedy
    }
}

/// One predicate that was actually evaluated, and how it came out.
///
/// This type exists because "Everything is where it should be" was not a claim
/// FoodTruck had earned. It rested on two predicates, one of which passed
/// vacuously, on a machine with seven other toolchains installed that it had
/// never looked at. The word "everything" was doing work the evidence could not
/// support.
///
/// So checks are now reported whether they pass or fail. A green result that
/// cannot show its working is indistinguishable from one that did nothing, and
/// the person reading it has no way to tell which they have.
public struct Check: Codable, Sendable, Identifiable, Equatable {
    public var id: String
    /// What this predicate guarantees, in the recipe author's words.
    public var label: String
    public var passed: Bool
    /// True when the predicate passed because nothing was asked of it, rather
    /// than because something was verified. An empty Brewfile satisfies "every
    /// formula in your Brewfile is installed" without proving anything, and
    /// counting that as evidence is how a tool talks itself into confidence.
    public var vacuous: Bool
    /// False for steps only a person may perform.
    public var automatable: Bool

    public init(id: String, label: String, passed: Bool,
                vacuous: Bool = false, automatable: Bool = true) {
        self.id = id; self.label = label; self.passed = passed
        self.vacuous = vacuous; self.automatable = automatable
    }
}

/// What a recipe printed on stdout for `audit`, `verify` or `detect`.
///
/// Every field is optional except the schema, so a recipe that prints nothing
/// at all is still a valid -- if uninformative -- recipe. We would rather show
/// "converged, no detail" than fail a run because a shell script forgot a
/// closing brace.
public struct RecipeReport: Codable, Sendable, Equatable {
    private enum CodingKeys: String, CodingKey { case schema, findings, facts, checks }

    public var schema: String
    public var findings: [Finding]
    public var facts: [String: String]
    /// Every predicate evaluated, passing ones included.
    public var checks: [Check]

    public static let currentSchema = "foodtruck.report/1"

    public init(findings: [Finding] = [], facts: [String: String] = [:],
                checks: [Check] = []) {
        self.schema = Self.currentSchema
        self.findings = findings
        self.facts = facts
        self.checks = checks
    }

    /// How much this report is actually worth. A recipe that verified nothing
    /// is not the same as a recipe that verified everything, and the UI must be
    /// able to tell them apart.
    public var provenCount: Int { checks.filter { $0.passed && !$0.vacuous }.count }

    public var worstSeverity: Severity { findings.map(\.severity).max() ?? .ok }

    /// Whether anything here actually needs doing.
    ///
    /// Not the same as "has findings". A `notice` -- you edited this recipe, this
    /// tool is unpinned -- is worth showing and not worth interrupting anyone
    /// over. Conflating the two is how a status tool trains people to ignore it.
    public var requiresAction: Bool { findings.contains { $0.severity >= .drift } }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schema = try c.decodeIfPresent(String.self, forKey: .schema) ?? Self.currentSchema
        findings = try c.decodeIfPresent([Finding].self, forKey: .findings) ?? []
        facts = try c.decodeIfPresent([String: String].self, forKey: .facts) ?? [:]
        checks = try c.decodeIfPresent([Check].self, forKey: .checks) ?? []
    }
}
