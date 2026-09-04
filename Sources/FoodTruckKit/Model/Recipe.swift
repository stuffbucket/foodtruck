import Foundation

/// How dangerous converging this recipe is. Drives confirmation UI and what
/// the test harness is willing to run outside a VM.
public enum Blast: String, Codable, Sendable, CaseIterable, Comparable {
    /// Writes only inside FoodTruck's own XDG directories.
    case contained
    /// Writes into the user's home, outside FoodTruck's directories.
    case home
    /// Writes outside the home directory -- `/opt/homebrew`, `/usr/local`.
    case system
    /// Installs launch agents, changes login shell, or needs admin.
    case privileged

    private var rank: Int { Blast.allCases.firstIndex(of: self)! }
    public static func < (a: Blast, b: Blast) -> Bool { a.rank < b.rank }
}

/// A managed thing, described entirely in data.
///
/// Note what is *not* here: no code, no tool name FoodTruck understands, no
/// special-casing. `engine` names who can run it, `requires` names what must
/// come first, `provides` names what it unlocks. The tech tree is the
/// transitive closure of those two fields and nothing else.
public struct Recipe: Codable, Sendable, Identifiable, Equatable {
    public var id: String
    /// Localisation key for the display name.
    public var name: String
    /// Localisation key for the one-line description.
    public var summary: String
    /// Which engine executes the verbs. `builtin` is reserved for tech-tree
    /// roots that must run before any external runner exists.
    public var engine: String
    /// Recipe ids that must be converged first.
    public var requires: [String]
    /// Capability tokens this recipe makes available once converged.
    public var provides: [String]
    /// Verbs this recipe actually implements. Asking for one that is absent is
    /// a clean `verbUnsupported` fault, never a mysterious non-zero exit.
    public var verbs: [Verb]
    public var blast: Blast
    /// Seconds. A recipe that has not answered by now is stopped and reported,
    /// rather than hanging a window forever.
    public var timeout: Double
    /// SF Symbol name for the UI. Purely presentational.
    public var symbol: String

    public init(
        id: String,
        name: String,
        summary: String,
        engine: String,
        requires: [String] = [],
        provides: [String] = [],
        verbs: [Verb] = [.detect, .audit, .plan, .converge, .verify],
        blast: Blast = .contained,
        timeout: Double = 120,
        symbol: String = "shippingbox"
    ) {
        self.id = id
        self.name = name
        self.summary = summary
        self.engine = engine
        self.requires = requires
        self.provides = provides
        self.verbs = verbs
        self.blast = blast
        self.timeout = timeout
        self.symbol = symbol
    }
}
