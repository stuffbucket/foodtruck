import Foundation

/// How a program got onto this machine.
///
/// The list is of *channels*, not of tools. FoodTruck still knows nothing about
/// what `node` is -- only that something under `mise/installs` was put there by
/// mise, and that something in `~/.local/bin` was put there by a person who is
/// now the only record of the decision.
public enum Origin: String, Codable, Sendable, CaseIterable {
    case homebrew, mise, asdf, cargo, npm, pipx, gem, go, foodtruck, apple, xcode
    /// Nothing on this machine claims responsibility for it. Not an error --
    /// most people have several, deliberately -- but it is the thing no other
    /// tool will ever tell you, so it is the thing worth surfacing.
    case unmanaged
}

/// How FoodTruck came to believe a version number.
///
/// Recorded because the two are not worth the same. A probed version is what
/// the program says about itself. An inferred one is a guess read off a
/// directory name, which is right for as long as the install follows the
/// convention it was built from -- and silently wrong the moment something is
/// unpacked somewhere odd, which is exactly the case an inventory exists to
/// catch. Keeping the distinction in the record means a reader can tell which
/// kind of claim they are looking at.
public enum VersionSource: String, Codable, Sendable {
    case probed
    case inferred
}

/// One executable found on this machine, and the best answer available for how
/// it got here.
public struct Installed: Codable, Sendable, Equatable, Identifiable {
    public var name: String
    /// The directory entry, with `$HOME` written as `~`.
    public var path: String
    /// Where that entry actually resolves, when it resolves somewhere else.
    public var real: String?
    public var origin: Origin
    public var version: String?
    /// Nil exactly when `version` is nil.
    public var versionSource: VersionSource?
    /// Size and modification time of the file this entry resolves to, as
    /// `<bytes>:<epoch>`.
    ///
    /// Two jobs. It lets a repeat scan tell that a binary is byte-for-byte the
    /// one already probed, so the version can be reused instead of re-running
    /// the program -- which is what stops every audit re-launching a few dozen
    /// subprocesses. And it gives change detection to the programs that have no
    /// version at all: a hand-installed binary that gets replaced looks
    /// identical by name and path, and only this notices.
    public var stamp: String?
    /// A stand-in that resolves to a real tool when run -- a mise, asdf, pyenv
    /// or rbenv shim. Two consequences, both important. It must never be run to
    /// ask its version (see `shouldProbe`), and it does not have one to ask
    /// for: which version a shim resolves to depends on the directory it is
    /// invoked from, which is the entire reason those managers exist.
    public var shim: Bool

    /// The path, because the same name in two directories is two installs and
    /// the whole point is to be able to see both.
    public var id: String { path }

    public init(name: String, path: String, real: String? = nil,
                origin: Origin, version: String? = nil,
                versionSource: VersionSource? = nil, shim: Bool = false,
                stamp: String? = nil) {
        self.name = name; self.path = path; self.real = real
        self.origin = origin; self.version = version
        self.versionSource = versionSource; self.shim = shim
        self.stamp = stamp
    }
}

/// The machine itself.
///
/// Every field here is read out of a file or `uname`. Nothing shells out, so
/// this is safe to gather on the read-only path and costs no measurable time.
public struct Host: Codable, Sendable, Equatable {
    public var product: String
    public var version: String
    public var build: String
    /// As reported to *this process*. Under Rosetta a native build and a
    /// translated one would disagree, and that disagreement is worth seeing
    /// rather than hiding behind a hardware query.
    public var arch: String
    public var kernel: String
    /// The Command Line Tools SDK version, or nil when they are not installed.
    /// Their absence is the difference between `git` working and `git` opening
    /// a 15 GB download dialog, so it is a fact about the machine, not trivia.
    public var commandLineTools: String?

    public var describe: String { "\(product) \(version) (\(build))" }
}

/// What is on this machine, at one moment, as a value.
///
/// Note what is *not* here: a timestamp. A record that carries the time it was
/// taken differs from the previous one every single time it is taken, which
/// would make "commit only when something changed" impossible and turn the
/// history into a heartbeat. Git already knows when each snapshot was made.
public struct Inventory: Codable, Sendable, Equatable {
    private enum CodingKeys: String, CodingKey { case schema, host, roots, tools, managers }

    public var schema: String
    public var host: Host
    /// The directories that were actually looked in. Recorded so that the
    /// scope of a snapshot is never in doubt -- a tool that did not look
    /// somewhere must not read as a tool that looked and found nothing.
    public var roots: [String]
    public var tools: [Installed]
    /// The tools whose job is installing other tools. Kept apart from `tools`
    /// because they are answers to a different question: `tools` is what is on
    /// the machine, `managers` is what decides what is on the machine.
    public var managers: [Manager]

    /// True when a pass declined to ask anything its version because the list
    /// of things to ask had grown past `probeCeiling`.
    ///
    /// Deliberately not part of the record -- it describes one run, not the
    /// machine, and putting it in the file would make snapshots differ for a
    /// reason that has nothing to do with what is installed.
    public var probeRefused: Bool = false

    public static let currentSchema = "foodtruck.inventory/1"

    public init(host: Host, roots: [String], tools: [Installed],
                managers: [Manager] = []) {
        self.schema = Self.currentSchema
        self.host = host
        self.roots = roots
        self.tools = tools
        self.managers = managers
    }

    /// Decoded by hand so a snapshot written before a field existed still
    /// loads. A history whose older entries cannot be read is not a history,
    /// and re-recording from scratch would erase the very comparison the file
    /// is kept for.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schema = try c.decodeIfPresent(String.self, forKey: .schema) ?? Self.currentSchema
        host = try c.decode(Host.self, forKey: .host)
        roots = try c.decodeIfPresent([String].self, forKey: .roots) ?? []
        tools = try c.decodeIfPresent([Installed].self, forKey: .tools) ?? []
        managers = try c.decodeIfPresent([Manager].self, forKey: .managers) ?? []
    }

    public var unmanaged: [Installed] { tools.filter { $0.origin == .unmanaged } }

    /// Names installed in more than one place. Which copy wins depends on a
    /// `PATH` this type deliberately does not claim to know; that there are two
    /// is true regardless.
    public var duplicated: [String: [Installed]] {
        Dictionary(grouping: tools, by: \.name)
            .filter { $0.value.count > 1 }
            .mapValues { inSearchOrder($0) }
    }

    public var countsByOrigin: [Origin: Int] {
        Dictionary(grouping: tools, by: \.origin).mapValues(\.count)
    }

    /// Runtimes that more than one installed manager is capable of managing.
    ///
    /// This is the conflict worth naming. Whichever manager reaches `PATH`
    /// first decides which `python` you get, the decision is made in shell
    /// startup files nobody reads twice, and the losing manager keeps happily
    /// reporting the version it thinks you are on.
    public var contested: [String: [String]] {
        var byRuntime: [String: [String]] = [:]
        for manager in managers {
            for runtime in manager.manages { byRuntime[runtime, default: []].append(manager.id) }
        }
        return byRuntime.filter { $0.value.count > 1 }.mapValues { $0.sorted() }
    }

    /// Orders copies of one command by the search root they sit in.
    ///
    /// Wherever several copies exist and one has to be named -- the shim in a
    /// shadowing pair, the `mise` a manager's version is read from -- the pick
    /// has to follow some rule. Sorting by path makes it alphabetical, which is
    /// stable and means nothing: `/opt/homebrew/bin/mise` wins over
    /// `~/.local/bin/mise` because `/` sorts before `~`.
    ///
    /// So it follows FoodTruck's own search order instead: `/etc/paths` first,
    /// then the manager directories. That is the nearest defensible thing to
    /// "the copy you would get", and no more than that -- it is not the shell's
    /// `PATH` and does not claim to be. `roots` travels in the snapshot, so the
    /// order actually used is readable rather than assumed.
    ///
    /// An instance method, not a free function taking roots: the ranking is
    /// only meaningful against the roots these copies were found under, and
    /// passing the wrong ones -- or none -- silently restores the alphabet.
    func inSearchOrder(_ copies: [Installed]) -> [Installed] {
        var order: [String: Int] = [:]
        for (index, root) in roots.enumerated() where order[root] == nil { order[root] = index }
        // A program sits directly in its root; the scan does not recurse. Cut
        // rather than bridged through NSString, which the rest of the sources
        // do not do and which allocates inside the comparator.
        func rank(_ tool: Installed) -> Int {
            let path = tool.path
            let directory = path[..<(path.lastIndex(of: "/") ?? path.startIndex)]
            return order[String(directory)] ?? roots.count
        }
        return copies.sorted { (rank($0), $0.path) < (rank($1), $1.path) }
    }

    /// Command names installed more than once at demonstrably different
    /// versions.
    ///
    /// Two copies of `gh` at 2.96.0 is tidiness, not a problem, and reporting
    /// it as one trains people to ignore the report. Two at different versions
    /// means `PATH` order decides which you get, which is worth a sentence.
    ///
    /// Copies with no established version are excluded rather than assumed to
    /// differ. "I could not tell" is not evidence of a conflict, and a report
    /// that says otherwise is guessing in the direction that generates alarm.
    /// The case that actually matters there -- a shim next to a real install --
    /// is named exactly by `shadowedShims` instead.
    public var conflictingVersions: [String: [Installed]] {
        Dictionary(grouping: tools, by: \.name)
            .filter { _, copies in Set(copies.compactMap(\.version)).count > 1 }
            .mapValues { inSearchOrder($0) }
    }

    /// Commands that exist both as a manager's shim and as a directly
    /// installed program.
    ///
    /// The most consequential thing an inventory can find, and invisible to
    /// every other check here. Both are on `PATH`, neither knows about the
    /// other, and the shim's version cannot be compared because it does not
    /// have one -- it depends on the directory. So which `node` you get is
    /// decided by the order of two lines in a shell startup file, and the
    /// manager will keep reporting the version it believes you are using.
    public var shadowedShims: [String: [Installed]] {
        Dictionary(grouping: tools, by: \.name)
            .filter { _, copies in
                copies.contains(where: \.shim) && copies.contains(where: { !$0.shim })
            }
            .mapValues { inSearchOrder($0) }
    }

    /// Command names FoodTruck will actually run to ask what version they are.
    ///
    /// A list, and a short one, because the two failure modes here pull in
    /// opposite directions. Running every executable on the machine is not a
    /// read-only operation by any honest definition -- it is a few thousand
    /// unknown programs, and one of them will be a script that does something.
    /// But refusing to run any of them means the only version FoodTruck can
    /// report is one read off a directory name, which is absent for anything
    /// installed by hand and wrong for anything unpacked somewhere unusual.
    ///
    /// So: these, wherever they are found, however they were installed. The
    /// membership test is the command's name, not its location, precisely
    /// because a `node` in a strange place is more interesting than one in the
    /// expected place, not less.
    ///
    /// This list belongs in the profile once there is one. Until then it lives
    /// here, where it is at least visible and reviewable.
    public static let interesting: Set<String> = [
        // Language runtimes and their package managers.
        "node", "npm", "npx", "pnpm", "yarn", "bun", "deno",
        "python", "python3", "pip", "pip3", "pipx", "uv",
        "ruby", "gem", "bundle", "go", "rustc", "cargo", "rustup",
        "java", "javac", "kotlin", "php", "composer", "perl", "lua",
        // Toolchains.
        "swift", "swiftc", "clang", "gcc", "make", "cmake", "ninja",
        // Version control.
        "git", "gh", "hg", "svn",
        // Infrastructure. These authenticate, and that is fine: asking one for
        // its version does not consult a credential store. They were pulled
        // from this list once on the theory that they caused a keychain storm;
        // they did not. Running every binary on the machine did, `security`
        // and `codesign` among them, because a gate had been inverted.
        "docker", "podman", "kubectl", "helm", "terraform", "tofu",
        "ansible", "vagrant", "aws", "gcloud", "az",
        // The managers themselves, which is how you find out one is stale.
        "brew", "mise", "asdf", "nix", "port", "task", "just",
        // Databases.
        "psql", "mysql", "sqlite3", "redis-cli",
        // Everyday tools whose version people actually pin.
        "jq", "rg", "fd", "fzf", "direnv", "tmux", "nvim", "vim",
        "zsh", "bash", "fish",
    ]
}
