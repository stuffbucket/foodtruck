import Foundation

/// The recorded history of what has been installed on this machine.
///
/// A git repository under FoodTruck's own data directory, holding exactly two
/// files: the record, and a rendering of the record that a human can read in a
/// diff. Nothing is pushed anywhere and nothing leaves the machine.
///
/// Reading is a plain file read. Only `commit` invokes git, which is what keeps
/// `audit` free of side effects -- and, on a Mac without the Command Line
/// Tools, free of the install dialog described in `executable`.
public struct InventoryStore: Sendable {
    public let root: URL
    public let home: URL?
    public let systemRoot: URL
    public let gitCandidates: [URL]

    public init(root: URL, home: URL? = nil, systemRoot: URL,
                gitCandidates: [URL]) {
        self.root = root
        self.home = home.flatMap { try? CanonicalPath.resolve($0) }
        self.systemRoot = (try? CanonicalPath.resolve(systemRoot))
            ?? systemRoot.standardizedFileURL
        self.gitCandidates = gitCandidates
    }

    public var recordURL: URL { root.appending(path: "inventory.json") }
    public var readableURL: URL { root.appending(path: "inventory.txt") }

    public enum Commit: Sendable, Equatable {
        case recorded(String)
        /// The machine has not changed, so there was nothing to record.
        case unchanged
        /// No usable git. The record is still written; only the history is lost.
        case unavailable
        case failed(String)
    }

    public enum Load: Sendable {
        case missing
        case loaded(Inventory)
        case invalid(String)
    }

    public enum WriteError: LocalizedError, Sendable {
        case invalidExistingSnapshot(String)
        case incompleteObservation

        public var errorDescription: String? {
            switch self {
            case .invalidExistingSnapshot(let detail):
                "refusing to replace an unreadable inventory snapshot: \(detail)"
            case .incompleteObservation:
                "refusing to record an incomplete inventory observation"
            }
        }
    }

    /// Reads without collapsing "not recorded yet" and "record is corrupt" into
    /// the same answer. Callers which write must never overwrite the latter.
    public func read() -> Load {
        guard FileManager.default.fileExists(atPath: recordURL.path) else { return .missing }
        do {
            let data = try Data(contentsOf: recordURL)
            return .loaded(try JSONDecoder().decode(Inventory.self, from: data))
        } catch {
            return .invalid(error.localizedDescription)
        }
    }

    /// The last recorded snapshot, or nil if there is none or it is unreadable.
    /// Read-only callers which need the distinction should use `read()`.
    public func load() -> Inventory? {
        guard case .loaded(let inventory) = read() else { return nil }
        return inventory
    }

    public func write(_ inventory: Inventory) throws {
        guard !inventory.probeRefused, !inventory.softwareDiscoveryRefused else {
            throw WriteError.incompleteObservation
        }
        if case .invalid(let detail) = read() {
            throw WriteError.invalidExistingSnapshot(detail)
        }
        try FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        let encoder = JSONEncoder()
        // Sorted and pretty on purpose: this file exists to be diffed, and a
        // one-line JSON blob makes every change look like every other change.
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(inventory).write(to: recordURL, options: .atomic)
        try Data(inventory.text.utf8).write(to: readableURL, options: .atomic)
    }

    /// Record the current state, if it differs from the last one.
    public func commit(message: String, environment: [String: String]) async -> Commit {
        guard let git = executable() else { return .unavailable }

        let env = gitEnvironment(environment)

        func run(_ args: [String]) async -> ExecResult {
            // The repository is FoodTruck's storage mechanism, not an extension
            // point. Local hooks and fsmonitor commands must never turn an
            // automatic snapshot into execution of user-controlled programs.
            let sealed = [
                "-c", "core.hooksPath=/dev/null",
                "-c", "core.fsmonitor=false",
                "-c", "core.attributesFile=/dev/null",
            ] + args
            return await Exec.run(
                git, sealed, environment: env, workingDirectory: root, timeout: 30)
        }

        if !FileManager.default.fileExists(atPath: root.appending(path: ".git").path) {
            let created = await run(["init", "-q"])
            guard created.status == 0 else {
                return .failed(created.stderr.isEmpty ? created.stdout : created.stderr)
            }
            // `git init -b main` needs git 2.28. Setting the ref directly works
            // on every version and says the same thing.
            _ = await run(["symbolic-ref", "HEAD", "refs/heads/main"])
        }

        // Per-directory attributes can name executable clean filters. This
        // private repository never needs attributes, so refuse the history step
        // rather than interpreting an unexpected file as configuration.
        for attributes in [root.appending(path: ".gitattributes"),
                           root.appending(path: ".git/info/attributes")]
        where FileManager.default.fileExists(atPath: attributes.path) {
            return .failed("refusing repository attributes at \(attributes.path)")
        }

        // Reset the index before staging exactly the two files FoodTruck owns.
        // Otherwise a stale or modified index could smuggle unrelated files into
        // an automatic commit. An unborn repository has no HEAD, so its empty
        // index is established explicitly.
        let hasHead = await run(["rev-parse", "--verify", "HEAD"]).status == 0
        let reset = await run(hasHead ? ["reset", "-q", "HEAD", "--"]
                                      : ["read-tree", "--empty"])
        guard reset.status == 0 else {
            return .failed(reset.stderr.isEmpty ? reset.stdout : reset.stderr)
        }
        let owned = [recordURL.lastPathComponent, readableURL.lastPathComponent]
        let staged = await run(["add", "--"] + owned)
        guard staged.status == 0 else {
            return .failed(staged.stderr.isEmpty ? staged.stdout : staged.stderr)
        }
        // Exit 0 means no staged difference: the machine is as it was, and a
        // commit here would be a heartbeat rather than a record.
        if await run(["diff", "--cached", "--quiet", "--"] + owned).status == 0 {
            return .unchanged
        }

        let committed = await run([
            "-c", "user.name=FoodTruck",
            "-c", "user.email=foodtruck@localhost",
            "-c", "commit.gpgsign=false",
            "commit", "-q", "-m", message, "--",
        ] + owned)
        guard committed.status == 0 else {
            return .failed(committed.stderr.isEmpty ? committed.stdout : committed.stderr)
        }
        let head = await run(["rev-parse", "--short", "HEAD"])
        return .recorded(head.stdout.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// One line per recorded snapshot, newest first. Empty when there is no
    /// history to show, which is not an error.
    public func history(limit: Int, environment: [String: String]) async -> [String] {
        guard let git = executable(),
              FileManager.default.fileExists(atPath: root.appending(path: ".git").path)
        else { return [] }
        let env = gitEnvironment(environment)
        let log = await Exec.run(
            git, ["log", "--max-count=\(limit)", "--date=short",
                  "--format=%h  %ad  %s"],
            environment: env, workingDirectory: root, timeout: 30)
        guard log.status == 0 else { return [] }
        return log.stdout.split(separator: "\n").map(String.init)
    }

    /// Git has environment variables for redirecting its repository, work tree,
    /// object database, hooks, and inline configuration. None are legitimate
    /// inputs to FoodTruck's private history store.
    private func gitEnvironment(_ environment: [String: String]) -> [String: String] {
        var result = environment
        for key in result.keys where key.hasPrefix("GIT_") { result.removeValue(forKey: key) }
        result["GIT_CONFIG_GLOBAL"] = "/dev/null"
        result["GIT_CONFIG_SYSTEM"] = "/dev/null"
        result["GIT_TERMINAL_PROMPT"] = "0"
        return result
    }

    /// A git we can actually run, or nil.
    ///
    /// `/usr/bin/git` is deliberately never used. On macOS it is not git: it is
    /// a stub that, on a machine without the Command Line Tools, opens a modal
    /// dialog offering a multi-gigabyte download. Invoking it to find out
    /// whether git exists would turn a silent bookkeeping step into an
    /// interruption the user did not ask for, so we establish the real thing is
    /// present by looking for it on disk instead of by asking the stub.
    public func executable() -> URL? {
        Self.executable(home: home, systemRoot: systemRoot, candidates: gitCandidates)
    }

    /// Resolve only candidates already sealed by the settings profile. The
    /// explicit root is checked again here so a direct API caller cannot smuggle
    /// a host path into a sandboxed store.
    public static func executable(
        home: URL? = nil, systemRoot: URL, candidates: [URL]
    ) -> URL? {
        guard let sealedRoot = try? CanonicalPath.resolve(systemRoot) else { return nil }
        let boundary = InventoryBoundary(home: home, systemRoot: sealedRoot)
        guard let denied = try? CanonicalPath.resolve(
            sealedRoot.appending(path: "usr/bin/git")).path else { return nil }
        for candidate in candidates {
            guard let path = try? CanonicalPath.resolve(candidate).path else { continue }
            guard boundary.containsCanonical(path), path != denied else { continue }
            if FileManager.default.isExecutableFile(atPath: path) {
                return URL(filePath: path)
            }
        }
        return nil
    }
}

extension Inventory {
    /// The record as something a person reads in `git diff`.
    ///
    /// Fixed-width columns and one program per line, so a change shows up as
    /// one changed line rather than as a reflowed paragraph.
    public var text: String {
        var lines: [String] = []
        lines.append("\(host.describe)  \(host.arch)  kernel \(host.kernel)")
        lines.append("command line tools: \(host.commandLineTools ?? "not installed")")
        lines.append("")
        if !managers.isEmpty {
            lines.append("managers:")
            for manager in managers {
                let id = manager.id.padding(toLength: 10, withPad: " ", startingAt: 0)
                let version = (manager.version
                               ?? (manager.shellFunction ? "shell function" : "unknown"))
                    .padding(toLength: 16, withPad: " ", startingAt: 0)
                lines.append("  \(id) \(version) manages \(manager.manages.joined(separator: " ")) "
                             + "— \(manager.evidence)")
            }
            lines.append("")
        }
        if !software.isEmpty {
            lines.append("software:")
            for artifact in software.sorted(by: {
                ($0.kind.rawValue, $0.path) < ($1.kind.rawValue, $1.path)
            }) {
                let kind = artifact.kind.rawValue.padding(
                    toLength: 12, withPad: " ", startingAt: 0)
                let provider = (artifact.provider?.rawValue ?? "").padding(
                    toLength: 10, withPad: " ", startingAt: 0)
                let name = artifact.name.padding(
                    toLength: 24, withPad: " ", startingAt: 0)
                let versions = artifact.versions.joined(separator: ",")
                let identity = artifact.identifier.map { " [\($0)]" } ?? ""
                lines.append("  \(kind) \(provider) \(name) \(versions) \(artifact.path)\(identity)")
            }
            lines.append("")
        }
        for tool in tools {
            let origin = tool.origin.rawValue.padding(toLength: 10, withPad: " ", startingAt: 0)
            let name = tool.name.padding(toLength: 24, withPad: " ", startingAt: 0)
            let version = (tool.version ?? "").padding(toLength: 14, withPad: " ", startingAt: 0)
            // A probed version is what the program said; an inferred one is a
            // guess off a directory name. Carrying the difference into the
            // history means a reader is never left to assume the stronger one.
            let source = (tool.shim ? "shim" : tool.versionSource?.rawValue ?? "")
                .padding(toLength: 8, withPad: " ", startingAt: 0)
            lines.append("\(origin) \(name) \(version) \(source) \(tool.path)")
        }
        lines.append("")
        lines.append("searched:")
        for root in roots { lines.append("  \(root)") }
        if !softwareRoots.isEmpty {
            lines.append("")
            lines.append("software searched:")
            for root in softwareRoots.sorted(by: {
                ($0.strategy.rawValue, $0.path) < ($1.strategy.rawValue, $1.path)
            }) {
                lines.append("  \(root.strategy.rawValue)  \(root.path)")
            }
        }
        return lines.joined(separator: "\n") + "\n"
    }
}
