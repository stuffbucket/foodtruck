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

/// Who a recipe is for.
///
/// This distinction exists because of a specific mistake: FoodTruck used to show
/// "the tool.brew recipe has not been copied to your pantry yet" as a task, with
/// a Fix button. That is FoodTruck installing its own data files. It is not a
/// fact about the user's Mac, they have no reason to care, and a button on it
/// asks them to take responsibility for our plumbing.
///
/// Housekeeping recipes are settled silently before the first audit and never
/// appear in the list. They surface only when they FAIL, because a failure
/// there is real news -- it means FoodTruck cannot do its job.
public enum RecipeScope: String, Codable, Sendable {
    /// About the user's machine. This is what the app is for.
    case environment
    /// FoodTruck setting itself up. Invisible unless it breaks.
    case housekeeping
}

/// A managed thing, described entirely in data.
///
/// Note what is *not* here: no code, no tool name FoodTruck understands, no
/// special-casing. `engine` names who can run it, `requires` names what must
/// come first, `provides` names what it unlocks. The tech tree is the
/// transitive closure of those two fields and nothing else.
public struct Recipe: Codable, Sendable, Identifiable, Equatable {
    private enum CodingKeys: String, CodingKey {
        case id, name, summary, engine, requires, provides, verbs, blast, scope, timeout, symbol
    }

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
    public var scope: RecipeScope
    /// Whether the user has edited this recipe. Surfaced as a quiet badge on
    /// the recipe itself rather than as a task somewhere else -- it is a fact
    /// about this recipe, so it belongs on this recipe.
    public var customised: Bool
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
        scope: RecipeScope = .environment,
        customised: Bool = false,
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
        self.scope = scope
        self.customised = customised
        self.timeout = timeout
        self.symbol = symbol
    }

    /// Decoded by hand, for two reasons worth stating.
    ///
    /// Every field is optional with a sensible default, so a `recipe.json`
    /// written before we added a field still loads -- a user's forked recipe is
    /// their work, and a field of ours appearing later is not a reason to break
    /// it. And `customised` is deliberately absent from the wire format: it is
    /// derived at load time by comparing against the shipped copy, so a recipe
    /// cannot declare itself unmodified.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        summary = try c.decode(String.self, forKey: .summary)
        engine = try c.decode(String.self, forKey: .engine)
        requires = try c.decodeIfPresent([String].self, forKey: .requires) ?? []
        provides = try c.decodeIfPresent([String].self, forKey: .provides) ?? []
        verbs = try c.decodeIfPresent([Verb].self, forKey: .verbs)
            ?? [.detect, .audit, .plan, .converge, .verify]
        blast = try c.decodeIfPresent(Blast.self, forKey: .blast) ?? .contained
        scope = try c.decodeIfPresent(RecipeScope.self, forKey: .scope) ?? .environment
        timeout = try c.decodeIfPresent(Double.self, forKey: .timeout) ?? 120
        symbol = try c.decodeIfPresent(String.self, forKey: .symbol) ?? "shippingbox"
        customised = false
    }
}
