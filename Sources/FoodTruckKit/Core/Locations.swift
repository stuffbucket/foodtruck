import Foundation

/// Where FoodTruck is allowed to put things.
///
/// Two rules, and they are the reason this type exists rather than string
/// literals scattered through the code:
///
/// 1. **XDG, not `~/Library`.** The people who will live in this tool already
///    have `~/.config` and `~/.local/share` under version control. Honouring
///    `XDG_*` is what lets a profile survive a migration to a new Mac.
/// 2. **Every path is derived from this one struct**, so a test can relocate
///    the entire world by constructing `Locations(root:)` and nothing on the
///    host is touched. There is no second code path that reads `$HOME`.
///
/// `$HOME` is read from the environment rather than `NSHomeDirectory()`
/// deliberately: `NSHomeDirectory()` consults the password database when it
/// feels like it, which would let a test escape its sandbox.
public struct Locations: Sendable, Equatable {
    public let config: URL   // user-editable intent
    public let data: URL     // the pantry: recipes, profiles, git store
    public let state: URL    // run journals, logs -- disposable but not cache
    public let cache: URL    // downloads, checksummed artifacts -- safe to rm
    /// The read-only recipes that shipped inside the signed app bundle.
    ///
    /// This is host configuration, not recipe input, which is why it lives here
    /// rather than being read from the environment down inside a recipe: the
    /// environment handed to recipes is deliberately hermetic and must not carry
    /// FoodTruck's own wiring.
    public let seed: URL?

    public init(config: URL, data: URL, state: URL, cache: URL, seed: URL? = nil) {
        self.config = config
        self.data = data
        self.state = state
        self.cache = cache
        self.seed = seed
    }

    /// Collapse all four directories under a single root. This is what the test
    /// harness uses, and what `FOODTRUCK_ROOT` gives a user who wants a
    /// throwaway environment without editing four variables.
    public init(root: URL, seed: URL? = nil) {
        self.init(
            config: root.appending(path: "config"),
            data: root.appending(path: "data"),
            state: root.appending(path: "state"),
            cache: root.appending(path: "cache"),
            seed: seed
        )
    }

    public static func resolved(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Locations {
        let seed = Self.seedURL(environment)
        if let root = environment["FOODTRUCK_ROOT"], !root.isEmpty {
            return Locations(root: URL(filePath: root), seed: seed)
        }
        let home = environment["HOME"].flatMap { $0.isEmpty ? nil : $0 }
            ?? NSHomeDirectory()

        func dir(_ key: String, _ fallback: String) -> URL {
            let base = environment[key].flatMap { $0.isEmpty ? nil : $0 }
                ?? "\(home)/\(fallback)"
            return URL(filePath: base).appending(path: "foodtruck")
        }
        return Locations(
            config: dir("XDG_CONFIG_HOME", ".config"),
            data:   dir("XDG_DATA_HOME",   ".local/share"),
            state:  dir("XDG_STATE_HOME",  ".local/state"),
            cache:  dir("XDG_CACHE_HOME",  ".cache"),
            seed:   seed
        )
    }

    /// Inside the app bundle in a release; overridable so a developer working in
    /// a checkout, and the test harness, use the same code path as the shipped
    /// app rather than a special case.
    private static func seedURL(_ environment: [String: String]) -> URL? {
        if let o = environment["FOODTRUCK_COOKBOOK_SEED"], !o.isEmpty {
            return URL(filePath: o)
        }
        return Bundle.main.url(forResource: "Cookbook", withExtension: nil)?
            .appending(path: "recipes")
    }

    // MARK: - Derived paths

    /// The user's settings overlay, under XDG_CONFIG_HOME/foodtruck.
    public var settings: URL { config.appending(path: "settings.json") }
    /// The complete defaults beside recipes and pins in the signed Cookbook.
    public var bundledSettings: URL? {
        seed?.deletingLastPathComponent().appending(path: "settings.json")
    }

    /// The git-backed store of recipes. `main` is last-known-good.
    ///
    /// Named for what it holds. Recipes live in a cookbook; a pantry holds
    /// ingredients, and "copy the recipe to your pantry" described neither.
    public var cookbook: URL { data.appending(path: "cookbook") }
    /// Recipes on disk. Editable -- a recipe you have changed is yours.
    public var recipes: URL { cookbook.appending(path: "recipes") }
    /// Tools FoodTruck has unlocked for itself. Never on the user's PATH
    /// unless they ask -- this directory is FoodTruck's, not the system's.
    public var toolbox: URL { data.appending(path: "toolbox/bin") }
    /// Snapshots of what is installed on this machine, in a git repository so
    /// that "what changed since last week" is a question with an answer.
    public var inventory: URL { data.appending(path: "inventory") }
    public var runs: URL { state.appending(path: "runs") }
    public var downloads: URL { cache.appending(path: "downloads") }

    public var all: [URL] { [config, data, state, cache] }
}
