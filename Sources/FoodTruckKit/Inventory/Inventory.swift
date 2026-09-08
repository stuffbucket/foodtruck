import Foundation

/// How a program got onto this machine.
///
/// The list is of *channels*, not of tools. FoodTruck still knows nothing about
/// what `node` is -- only that something under `mise/installs` was put there by
/// mise, and that something in `~/.local/bin` was put there by a person who is
/// now the only record of the decision.
public struct Origin: RawRepresentable, Codable, Sendable, Hashable {
    public let rawValue: String

    public init(rawValue: String) { self.rawValue = rawValue }

    public static let homebrew = Self(rawValue: "homebrew")
    public static let mise = Self(rawValue: "mise")
    public static let asdf = Self(rawValue: "asdf")
    public static let cargo = Self(rawValue: "cargo")
    public static let npm = Self(rawValue: "npm")
    public static let pipx = Self(rawValue: "pipx")
    public static let gem = Self(rawValue: "gem")
    public static let go = Self(rawValue: "go")
    public static let foodtruck = Self(rawValue: "foodtruck")
    public static let apple = Self(rawValue: "apple")
    public static let xcode = Self(rawValue: "xcode")
    /// Nothing on this machine claims responsibility for it. Not an error --
    /// most people have several, deliberately -- but it is the thing no other
    /// tool will ever tell you, so it is the thing worth surfacing.
    public static let unmanaged = Self(rawValue: "unmanaged")

    /// Built-in localization coverage. Settings may introduce additional origin
    /// identities without requiring a FoodTruck code change.
    public static let allCases: [Self] = [
        .homebrew, .mise, .asdf, .cargo, .npm, .pipx, .gem, .go,
        .foodtruck, .apple, .xcode, .unmanaged,
    ]
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

/// Commands whose shims and direct installs compete between the same two
/// directories. One group is one PATH-order decision in the report.
public struct ShimShadowGroup: Sendable, Equatable {
    public var commands: [String]
    public var manager: Origin
    public var shimDirectory: String
    public var directDirectory: String
}

private struct ShimShadowKey: Hashable {
    var shimDirectory: String
    var directDirectory: String
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
    /// A versioned identity stamp for the file this entry resolves to. Legacy
    /// snapshots used `<bytes>:<epoch>` and `v2:`; current snapshots use a `v3:` stamp
    /// containing the canonical target and stable filesystem metadata.
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

public enum SoftwareArtifactKind: String, Codable, Sendable, CaseIterable {
    case formula
    case cask
    case application
    case footprint
}

public enum SoftwareArtifactEvidence: String, Codable, Sendable, CaseIterable {
    case homebrewReceipt
    case homebrewCaskMetadata
    case bundleInfoPlist
    case directoryEntry
}

/// One installed software unit or durable installation/configuration footprint.
/// This is deliberately separate from executable copies: it has package or
/// bundle identity, but no claim about PATH resolution or command precedence.
public struct SoftwareArtifact: Codable, Sendable, Equatable, Identifiable {
    public var kind: SoftwareArtifactKind
    public var name: String
    public var path: String
    public var identifier: String?
    public var versions: [String]
    public var provider: Origin?
    public var evidence: SoftwareArtifactEvidence

    public var id: String { "\(kind.rawValue):\(path)" }

    public init(kind: SoftwareArtifactKind, name: String, path: String,
                identifier: String? = nil, versions: [String] = [],
                provider: Origin? = nil, evidence: SoftwareArtifactEvidence) {
        self.kind = kind
        self.name = name
        self.path = path
        self.identifier = identifier
        self.versions = versions
        self.provider = provider
        self.evidence = evidence
    }
}

/// A root and strategy that were successfully searched. Artifact history is
/// comparable only where both snapshots carry the same coverage identity.
public struct SoftwareDiscoveryCoverage: Codable, Sendable, Equatable, Identifiable {
    public var path: String
    public var strategy: SoftwareDiscoveryStrategy

    public var id: String { "\(strategy.rawValue):\(path)" }

    public init(path: String, strategy: SoftwareDiscoveryStrategy) {
        self.path = path
        self.strategy = strategy
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
    private enum CodingKeys: String, CodingKey {
        case schema, host, roots, tools, managers, software, softwareRoots
    }

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
    public var software: [SoftwareArtifact]
    public var softwareRoots: [SoftwareDiscoveryCoverage]

    /// True when a pass declined to ask anything its version because the list
    /// of things to ask had grown past `probeCeiling`.
    ///
    /// Deliberately not part of the record -- it describes one run, not the
    /// machine, and putting it in the file would make snapshots differ for a
    /// reason that has nothing to do with what is installed.
    public var probeRefused: Bool = false
    /// True when a safety boundary, read failure, or compiled ceiling prevented
    /// software discovery from producing a complete observation. Transient so a
    /// partial run can never masquerade as machine history.
    public var softwareDiscoveryRefused: Bool = false

    public static let currentSchema = "foodtruck.inventory/2"
    private static let legacySchema = "foodtruck.inventory/1"

    public init(host: Host, roots: [String], tools: [Installed],
                managers: [Manager] = [], software: [SoftwareArtifact] = [],
                softwareRoots: [SoftwareDiscoveryCoverage] = []) {
        self.schema = Self.currentSchema
        self.host = host
        self.roots = roots
        self.tools = tools
        self.managers = managers
        self.software = software
        self.softwareRoots = softwareRoots
    }

    /// Schema-less snapshots predate fields added to the record and retain the
    /// narrow compatibility defaults they were written against. Once a snapshot
    /// declares a schema, that schema is a complete contract: missing fields or
    /// an unknown version make the record invalid so it is preserved for repair
    /// rather than silently reinterpreted and overwritten.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)

        if c.contains(.schema) {
            let decodedSchema = try c.decode(String.self, forKey: .schema)
            guard decodedSchema == Self.currentSchema || decodedSchema == Self.legacySchema else {
                throw DecodingError.dataCorruptedError(
                    forKey: .schema, in: c,
                    debugDescription: "unsupported inventory schema \(decodedSchema)")
            }
            schema = Self.currentSchema
            host = try c.decode(Host.self, forKey: .host)
            roots = try c.decode([String].self, forKey: .roots)
            tools = try c.decode([Installed].self, forKey: .tools)
            managers = try c.decode([Manager].self, forKey: .managers)
            if decodedSchema == Self.currentSchema {
                software = try c.decode([SoftwareArtifact].self, forKey: .software)
                softwareRoots = try c.decode(
                    [SoftwareDiscoveryCoverage].self, forKey: .softwareRoots)
            } else {
                software = []
                softwareRoots = []
            }
        } else {
            schema = Self.currentSchema
            host = try c.decode(Host.self, forKey: .host)
            roots = try c.decodeIfPresent([String].self, forKey: .roots) ?? []
            tools = try c.decodeIfPresent([Installed].self, forKey: .tools) ?? []
            managers = try c.decodeIfPresent([Manager].self, forKey: .managers) ?? []
            software = []
            softwareRoots = []
        }
    }

    /// Programs belonging to the environment rather than FoodTruck itself.
    /// New scans exclude private tools at the boundary; this filter keeps old
    /// snapshots and hand-built values from polluting later analysis.
    public var environmentTools: [Installed] {
        tools.filter { $0.origin != .foodtruck }
    }

    public var unmanaged: [Installed] {
        environmentTools.filter { $0.origin == .unmanaged }
    }

    /// Names installed in more than one place. Which copy wins depends on a
    /// `PATH` this type deliberately does not claim to know; that there are two
    /// is true regardless.
    public var duplicated: [String: [Installed]] {
        Dictionary(grouping: environmentTools, by: \.name)
            .filter { $0.value.count > 1 }
            .mapValues { inSearchOrder($0) }
    }

    public var countsByOrigin: [Origin: Int] {
        Dictionary(grouping: environmentTools, by: \.origin).mapValues(\.count)
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
        Dictionary(grouping: environmentTools, by: \.name)
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
        Dictionary(grouping: environmentTools, by: \.name)
            .filter { _, copies in
                copies.contains(where: \.shim) && copies.contains(where: { !$0.shim })
            }
            .mapValues { inSearchOrder($0) }
    }

    /// Shim conflicts grouped by the pair of directories the user must choose
    /// between. The exhaustive inventory above stays keyed by command name;
    /// this is the report-sized view of the same evidence.
    public var shimShadowGroups: [ShimShadowGroup] {
        var groups: [ShimShadowKey: ShimShadowGroup] = [:]
        let shadows = shadowedShims

        for name in shadows.keys.sorted() {
            guard let copies = shadows[name],
                  let shim = copies.first(where: \.shim),
                  let direct = copies.first(where: { !$0.shim }) else { continue }
            let key = ShimShadowKey(
                shimDirectory: directory(of: shim.path),
                directDirectory: directory(of: direct.path))
            if var group = groups[key] {
                group.commands.append(name)
                groups[key] = group
            } else {
                groups[key] = ShimShadowGroup(
                    commands: [name], manager: shim.origin,
                    shimDirectory: key.shimDirectory,
                    directDirectory: key.directDirectory)
            }
        }

        return groups.values.sorted {
            ($0.shimDirectory, $0.directDirectory)
                < ($1.shimDirectory, $1.directDirectory)
        }
    }

    private func directory(of path: String) -> String {
        guard let separator = path.lastIndex(of: "/") else { return "." }
        return separator == path.startIndex ? "/" : String(path[..<separator])
    }

}


/// A change to one software unit at a stable kind-and-path identity.
public struct SoftwareModification: Sendable, Equatable {
    public var before: SoftwareArtifact
    public var after: SoftwareArtifact

    public init(before: SoftwareArtifact, after: SoftwareArtifact) {
        self.before = before
        self.after = after
    }
}

private extension SoftwareArtifactKind {
    var discoveryStrategy: SoftwareDiscoveryStrategy {
        switch self {
        case .formula: .homebrewCellar
        case .cask: .homebrewCaskroom
        case .application: .applicationBundles
        case .footprint: .topLevelFootprints
        }
    }
}

/// A change to one executable at a stable path.
public struct InventoryModification: Sendable, Equatable {
    public var before: Installed
    public var after: Installed

    public init(before: Installed, after: Installed) {
        self.before = before
        self.after = after
    }
}

/// The trustworthy difference between two observations of one environment.
///
/// Paths are the identity of an installation. Changes are only claimed in
/// roots both observations actually searched; a newly searched directory is a
/// coverage change, not proof that its contents were newly installed.
public struct InventoryDelta: Sendable, Equatable {
    public var added: [Installed]
    public var removed: [Installed]
    public var modified: [InventoryModification]
    public var addedRoots: [String]
    public var removedRoots: [String]
    public var rootsReordered: Bool
    public var addedSoftware: [SoftwareArtifact]
    public var removedSoftware: [SoftwareArtifact]
    public var modifiedSoftware: [SoftwareModification]
    public var addedSoftwareRoots: [SoftwareDiscoveryCoverage]
    public var removedSoftwareRoots: [SoftwareDiscoveryCoverage]
    public var previousHost: Host?
    public var currentHost: Host?
    public var previousManagers: [Manager]?
    public var currentManagers: [Manager]?

    public init(
        previous: Inventory,
        current: Inventory,
        excludingRoots: Set<String> = []
    ) {
        let oldRoots = previous.roots.filter { !excludingRoots.contains($0) }
        let newRoots = current.roots.filter { !excludingRoots.contains($0) }
        let commonRoots = Set(oldRoots).intersection(newRoots)
        addedRoots = Array(Set(newRoots).subtracting(oldRoots)).sorted()
        removedRoots = Array(Set(oldRoots).subtracting(newRoots)).sorted()
        rootsReordered = addedRoots.isEmpty && removedRoots.isEmpty && oldRoots != newRoots

        let oldSoftwareRoots = Dictionary(
            previous.softwareRoots.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first })
        let newSoftwareRoots = Dictionary(
            current.softwareRoots.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first })
        let oldSoftwareCoverage = Set(oldSoftwareRoots.keys)
        let newSoftwareCoverage = Set(newSoftwareRoots.keys)
        let commonSoftwareCoverage = oldSoftwareCoverage.intersection(newSoftwareCoverage)
        addedSoftwareRoots = newSoftwareCoverage.subtracting(oldSoftwareCoverage)
            .compactMap { newSoftwareRoots[$0] }
            .sorted { ($0.strategy.rawValue, $0.path) < ($1.strategy.rawValue, $1.path) }
        removedSoftwareRoots = oldSoftwareCoverage.subtracting(newSoftwareCoverage)
            .compactMap { oldSoftwareRoots[$0] }
            .sorted { ($0.strategy.rawValue, $0.path) < ($1.strategy.rawValue, $1.path) }

        func softwareComparable(
            _ artifact: SoftwareArtifact, coverage: [String: SoftwareDiscoveryCoverage]
        ) -> Bool {
            coverage.values.contains { root in
                root.strategy == artifact.kind.discoveryStrategy
                    && commonSoftwareCoverage.contains(root.id)
                    && Inventory.isUnder(artifact.path, root: root.path)
            }
        }
        let oldSoftware = Dictionary(
            previous.software.filter {
                softwareComparable($0, coverage: oldSoftwareRoots)
            }.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first })
        let newSoftware = Dictionary(
            current.software.filter {
                softwareComparable($0, coverage: newSoftwareRoots)
            }.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first })
        let oldSoftwareIDs = Set(oldSoftware.keys)
        let newSoftwareIDs = Set(newSoftware.keys)
        addedSoftware = newSoftwareIDs.subtracting(oldSoftwareIDs)
            .compactMap { newSoftware[$0] }.sorted { $0.id < $1.id }
        removedSoftware = oldSoftwareIDs.subtracting(newSoftwareIDs)
            .compactMap { oldSoftware[$0] }.sorted { $0.id < $1.id }
        modifiedSoftware = oldSoftwareIDs.intersection(newSoftwareIDs).compactMap { id in
            guard let before = oldSoftware[id], let after = newSoftware[id],
                  before != after else { return nil }
            return SoftwareModification(before: before, after: after)
        }.sorted { $0.after.id < $1.after.id }

        func directory(of path: String) -> String {
            guard let slash = path.lastIndex(of: "/") else { return "" }
            if slash == path.startIndex { return "/" }
            return String(path[..<slash])
        }
        func comparable(_ tool: Installed) -> Bool {
            tool.origin != .foodtruck && commonRoots.contains(directory(of: tool.path))
        }

        let oldTools = Dictionary(
            previous.tools.filter(comparable).map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first })
        let newTools = Dictionary(
            current.tools.filter(comparable).map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first })
        let oldPaths = Set(oldTools.keys)
        let newPaths = Set(newTools.keys)

        added = newPaths.subtracting(oldPaths).compactMap { newTools[$0] }
            .sorted { $0.path < $1.path }
        removed = oldPaths.subtracting(newPaths).compactMap { oldTools[$0] }
            .sorted { $0.path < $1.path }
        enum StampGeneration: Equatable { case legacy, v2, v3 }
        func generation(of stamp: String?) -> StampGeneration? {
            guard let stamp else { return nil }
            if stamp.hasPrefix("v3:") { return .v3 }
            return stamp.hasPrefix("v2:") ? .v2 : .legacy
        }
        func comparableStampChanged(before: String?, after: String?) -> Bool {
            guard before != after,
                  let beforeGeneration = generation(of: before),
                  let afterGeneration = generation(of: after),
                  beforeGeneration == afterGeneration else { return false }
            return true
        }

        modified = oldPaths.intersection(newPaths).compactMap { path in
            guard let before = oldTools[path], let after = newTools[path] else { return nil }
            // How a version was learned is evidence quality, not a machine
            // change. A stamp is evidence only within one stamp generation: a
            // format upgrade invalidates the probe cache, but says nothing about
            // whether the executable itself changed.
            let changed = before.name != after.name
                || before.real != after.real
                || before.origin != after.origin
                || before.version != after.version
                || comparableStampChanged(before: before.stamp, after: after.stamp)
                || before.shim != after.shim
            guard changed else { return nil }
            return InventoryModification(before: before, after: after)
        }.sorted { $0.after.path < $1.after.path }

        if previous.host == current.host {
            previousHost = nil
            currentHost = nil
        } else {
            previousHost = previous.host
            currentHost = current.host
        }

        func environmentalManagers(_ inventory: Inventory) -> [Manager] {
            inventory.managers.filter { manager in
                !excludingRoots.contains { root in
                    manager.evidence == root
                        || (root == "/" ? manager.evidence.hasPrefix("/")
                            : manager.evidence.hasPrefix(root + "/"))
                }
            }
        }
        let oldManagers = environmentalManagers(previous)
        let newManagers = environmentalManagers(current)
        // A manager stamp validates the version cache; it is not itself a
        // user-facing manager change. Keep it in the snapshot so an in-place
        // replacement is re-probed, but do not emit identical before/after
        // evidence when only that internal cache key changed.
        let sameManagers = oldManagers.count == newManagers.count
            && zip(oldManagers, newManagers).allSatisfy { before, after in
                before.id == after.id
                    && before.evidence == after.evidence
                    && before.version == after.version
                    && before.manages == after.manages
                    && before.shellFunction == after.shellFunction
            }
        if sameManagers {
            previousManagers = nil
            currentManagers = nil
        } else {
            previousManagers = oldManagers
            currentManagers = newManagers
        }
    }

    public var isEmpty: Bool {
        added.isEmpty && removed.isEmpty && modified.isEmpty
            && addedRoots.isEmpty && removedRoots.isEmpty && !rootsReordered
            && addedSoftware.isEmpty && removedSoftware.isEmpty
            && modifiedSoftware.isEmpty && addedSoftwareRoots.isEmpty
            && removedSoftwareRoots.isEmpty
            && previousHost == nil && previousManagers == nil
    }
}
