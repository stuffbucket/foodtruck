import Foundation

extension Inventory {

    /// Ask the programs we actually care about what version they are.
    ///
    /// The scan can only infer a version from an install layout, which fails in
    /// both directions: a hand-installed binary has no layout to read, and a
    /// managed one moved somewhere unusual reads as whatever the directory
    /// above it happens to be called. Neither is a good enough answer about a
    /// tool someone is trying to keep pinned, so for a declared and short list
    /// in the resolved settings profile, FoodTruck runs the program and believes
    /// what it says instead.
    ///
    /// What keeps this defensible is the boundary, not the act. Executing a
    /// named tool is something the Homebrew recipe's audit already does. What
    /// would not be defensible is executing everything found, which is why
    /// membership is a list somebody wrote down rather than a heuristic.
    /// How many programs may be running at once.
    ///
    /// There was no limit here, and `withTaskGroup` started every candidate at
    /// the same instant: twenty-three processes, each with two pipe readers and
    /// a deadline task, launched together, several times per audit. When one of
    /// them blocked -- and one did, on a keychain prompt -- the rest piled up
    /// behind the timeout while the next pass began. Four at a time costs a
    /// fraction of a second on a first run and cannot do that.
    static let probeWindow = 4
    static let probeTimeout: Double = 3
    /// Independent of configurable policy: a bad eligibility gate still cannot
    /// launch an unbounded number of distinct programs.
    static let probeCeiling = 256

    /// Ask the tools we care about what version they are, reusing anything
    /// already known.
    ///
    /// - Parameter reusing: the last recorded inventory. A program whose path
    ///   and `stamp` are unchanged is byte-for-byte the one already asked, so
    ///   its answer is carried over rather than asked again. This is what makes
    ///   a repeat audit cost no subprocesses at all; without it every audit
    ///   re-ran every tool, which is how a mutation run launched a few thousand
    ///   processes.
    public func probingVersions(
        home: URL, environment: [String: String],
        settings: ResolvedInventorySettings, systemRoot: URL,
        reusing previous: Inventory? = nil
    ) async -> Inventory {
        let homePath = (try? CanonicalPath.resolve(home).path)
            ?? home.standardizedFileURL.path
        let developer = Self.developerDirectory(systemRoot: systemRoot)
        let eligibleNames = Set(settings.probes.names)

        var known: [String: Installed] = [:]
        for tool in previous?.tools ?? [] where tool.versionSource == .probed {
            known[tool.path] = tool
        }

        var updated = self
        var candidateOrder: [String] = []
        var candidateIndices: [String: [Int]] = [:]
        for index in tools.indices {
            let tool = tools[index]
            guard let target = probeTarget(
                for: tool, eligibleNames: eligibleNames, home: homePath,
                systemRoot: systemRoot, developerDirectory: developer
            ) else { continue }
            if let cached = known[tool.path], cached.stamp != nil, cached.stamp == tool.stamp {
                updated.tools[index].version = cached.version
                updated.tools[index].versionSource = .probed
            } else {
                if candidateIndices[target] == nil { candidateOrder.append(target) }
                candidateIndices[target, default: []].append(index)
            }
        }

        // Managers are reconstructed by the directory scan, so their versions
        // need the same cache treatment and the same request batch as programs.
        // A manager cache hit is valid only while the executable stamp matches;
        // evidence directories alone survive in-place upgrades.
        let toolsByPath = Dictionary(
            updated.tools.map { ($0.path, $0) }, uniquingKeysWith: { first, _ in first })
        let oldManagers = Dictionary(
            (previous?.managers ?? []).map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first })
        var managerTargets: [String: String] = [:]
        var managerTargetOrder: [String] = []
        for index in updated.managers.indices {
            let manager = updated.managers[index]
            let target: String?
            if let tool = toolsByPath[manager.evidence] {
                updated.managers[index].stamp = tool.stamp
                if tool.versionSource == .probed {
                    updated.managers[index].version = tool.version
                    continue
                }
                target = Self.gatedProbeTarget(
                    path: Self.expand(tool.path, home: homePath), name: tool.name,
                    shim: tool.shim, home: homePath, systemRoot: systemRoot,
                    developerDirectory: developer)
            } else {
                target = Self.managerProbeTarget(
                    for: manager, home: homePath, settings: settings,
                    systemRoot: systemRoot, developerDirectory: developer)
                updated.managers[index].stamp = target.flatMap(Self.stamp(of:))
            }

            if let old = oldManagers[manager.id], old.evidence == manager.evidence,
               old.stamp != nil, old.stamp == updated.managers[index].stamp,
               old.version != nil {
                updated.managers[index].version = old.version
                continue
            }
            if let target {
                managerTargets[manager.id] = target
                if !managerTargetOrder.contains(target) { managerTargetOrder.append(target) }
            }
        }
        for target in managerTargetOrder where candidateIndices[target] == nil
            && !candidateOrder.contains(target) {
            candidateOrder.append(target)
        }

        guard !candidateOrder.isEmpty else { return updated }
        // The ceiling is compiled independently of every configurable list and
        // covers tool probes and directory-only manager probes together.
        guard candidateOrder.count <= Self.probeCeiling else {
            updated.probeRefused = true
            return updated
        }

        // Even a well-behaved tool keeps books on itself. `gh --version` writes
        // a device id; `mise --version` runs its state migrations. Measured,
        // both of them, by the read-only self-test failing.
        //
        // Those writes have to land somewhere, and neither candidate is
        // acceptable: the user's real directories are what `audit` promised not
        // to touch, and FoodTruck's own are what the read-only guarantee is
        // checked against. So a probe gets a scratch home that exists for the
        // length of the pass and is then deleted. Same instinct as
        // `Exec.baseEnvironment` -- hand a subprocess a world you built, not
        // one you happened to be standing in.
        let scratch = URL(filePath: NSTemporaryDirectory())
            .appending(path: "foodtruck-probe-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(
            at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }

        var env = environment
        // A program we are only asking the version of has no business knowing
        // where FoodTruck keeps anything, or seeing the variables which chose
        // configured scan paths. Remove those inputs before restoring the
        // intentionally isolated HOME and XDG values below.
        for key in env.keys where key.hasPrefix("FOODTRUCK_")
            || settings.pathSourceEnvironment.contains(key) {
            env.removeValue(forKey: key)
        }
        env["HOME"] = scratch.path
        for key in ["XDG_CONFIG_HOME", "XDG_DATA_HOME", "XDG_STATE_HOME", "XDG_CACHE_HOME"] {
            env[key] = scratch.path
        }

        let probed: [String: String] = await withTaskGroup(
            of: (String, String?).self
        ) { group in
            var found: [String: String] = [:]
            var next = 0
            // A fixed window rather than one task per candidate. Start at most
            // `probeWindow`, and only add another as one finishes.
            func start() {
                guard next < candidateOrder.count else { return }
                let target = candidateOrder[next]
                next += 1
                group.addTask {
                    (target, await Self.version(ofProgramAt: target,
                                                environment: env,
                                                workingDirectory: scratch,
                                                timeout: Self.probeTimeout))
                }
            }
            for _ in 0..<Swift.min(Self.probeWindow, candidateOrder.count) { start() }
            while let (target, version) = await group.next() {
                if let version { found[target] = version }
                start()
            }
            return found
        }

        for (target, version) in probed {
            for index in candidateIndices[target] ?? [] {
                updated.tools[index].version = version
                updated.tools[index].versionSource = .probed
            }
        }
        updated.managers = updated.managerVersions(
            probedTargets: probed, managerTargets: managerTargets)
        return updated
    }

    /// A version for each manager, which matters more than it does for most
    /// tools: these move fast, and a stale one is its own class of problem.
    ///
    /// Answered from the programs already probed wherever possible -- that is
    /// the copy that would actually run. A manager found only as a directory
    /// (a conda that is not on `PATH`) is asked directly at its own `bin`,
    /// because otherwise its version is unknowable while it is still capable
    /// of deciding which Python you get.
    ///
    /// A shell function is left without one, and says so. There is no binary
    /// to ask, and sourcing a user's shell files to find out would be running
    /// their startup configuration to satisfy a curiosity.
    func managerVersions(probedTargets: [String: String],
                         managerTargets: [String: String]) -> [Manager] {
        let byPath = Dictionary(
            tools.map { ($0.path, $0) }, uniquingKeysWith: { first, _ in first })
        return managers.map { manager in
            var manager = manager
            if let known = byPath[manager.evidence], known.versionSource == .probed {
                manager.version = known.version
            } else if let target = managerTargets[manager.id],
                      let version = probedTargets[target] {
                manager.version = version
            }
            return manager
        }
    }

    /// An executable inside a manager directory that was itself the evidence.
    /// Returning only paths declared through settings keeps relocated homes
    /// usable without turning directory discovery into a command search.
    private static func managerProbeTarget(
        for manager: Manager, home: String, settings: ResolvedInventorySettings,
        systemRoot: URL, developerDirectory: String?
    ) -> String? {
        guard !manager.shellFunction,
              let declaration = settings.managers.first(where: { $0.id == manager.id }),
              let directory = declaration.directories.first(where: {
                  abbreviate($0.path, home: home) == manager.evidence
              }) else { return nil }
        for binary in declaration.binaries {
            let candidate = directory.appending(path: "bin/\(binary)").path
            guard FileManager.default.isExecutableFile(atPath: candidate) else { continue }
            if let target = gatedProbeTarget(
                path: candidate, name: binary, shim: false, home: home,
                systemRoot: systemRoot, developerDirectory: developerDirectory) {
                return target
            }
        }
        return nil
    }

    /// The executable half of the probe gate, shared by scanned tools and
    /// managers discovered only from their configured directories.
    private static func gatedProbeTarget(
        path: String, name: String, shim: Bool, home: String, systemRoot: URL,
        developerDirectory: String?
    ) -> String? {
        guard !shim,
              let candidate = containedExecutable(path, home: home, systemRoot: systemRoot)
        else { return nil }
        guard isDeveloperStub(candidate, systemRoot: systemRoot) else { return candidate }

        // Resolve the stub only to a real developer binary that remains inside
        // the same sealed machine. A crafted xcode-select link must not turn a
        // safe refusal into execution on the host.
        guard let developerDirectory else { return nil }
        let real = URL(filePath: developerDirectory).appending(path: "usr/bin/\(name)").path
        return containedExecutable(real, systemRoot: systemRoot)
    }

    /// Canonicalize before checking the boundary. `isExecutableFile` follows
    /// symlinks, so a lexical containment check would approve an in-root name
    /// that actually executes a program outside the sealed system.
    private static func containedExecutable(
        _ path: String, home: String? = nil, systemRoot: URL
    ) -> String? {
        let boundary = InventoryBoundary(
            home: home.map { URL(filePath: $0) }, systemRoot: systemRoot)
        guard let candidate = try? CanonicalPath.resolve(URL(filePath: path)).path else {
            return nil
        }
        guard boundary.containsCanonical(candidate),
              FileManager.default.isExecutableFile(atPath: candidate) else {
            return nil
        }
        return candidate
    }

    /// The path to actually execute for this tool, or nil if it must not be
    /// run at all.
    ///
    /// One decision point, because two of them is how the last accident
    /// happened. It answers three separate questions.
    ///
    /// Is it declared? Only names in the resolved probe policy are ever run.
    ///
    /// Is it a manager's shim? Running `mise/shims/node --version` does not
    /// report a version, it makes mise install whichever Node the surrounding
    /// directory asks for -- a large download, performed by a verb that
    /// promised to change nothing. Measured: the read-only self-test caught an
    /// audit installing Node 22 into its own sandbox.
    ///
    /// Is it one of Apple's developer-tool stubs? Those are never run either,
    /// but unlike a manager's shim there is something better to run instead.
    func probeTarget(
        for tool: Installed, eligibleNames: Set<String>, home: String,
        systemRoot: URL, developerDirectory: String?
    ) -> String? {
        guard eligibleNames.contains(tool.name) else { return nil }
        return Self.gatedProbeTarget(
            path: Self.expand(tool.path, home: home), name: tool.name, shim: tool.shim,
            home: home, systemRoot: systemRoot, developerDirectory: developerDirectory)
    }

    /// One of Apple's developer-tool stubs.
    ///
    /// They are all hard links to a single file. Measured on macOS 26.6:
    /// `/usr/bin/git`, `clang`, `swift`, `make`, `python3` and `cmpdylib` share
    /// one inode with a link count of 78, while `ruby`, `perl`, `vim`, `zsh`
    /// and `xcrun` each have a link count of 1. So "many names, one file"
    /// identifies the whole family without a list of tool names to maintain --
    /// and it stays right when Apple adds one.
    ///
    /// Restricted to the system directories so that a package manager which
    /// happens to hard link something is not mistaken for Apple.
    static func isDeveloperStub(_ path: String, systemRoot: URL) -> Bool {
        guard let root = try? CanonicalPath.resolve(systemRoot).path,
              let path = try? CanonicalPath.resolve(URL(filePath: path)).path else {
            return true
        }
        let base = root == "/" ? "" : root
        let system = ["/usr/bin/", "/bin/", "/usr/sbin/", "/sbin/"].map { base + $0 }
        guard system.contains(where: { path.hasPrefix($0) }) else { return false }
        // If the link count cannot be read, assume it is a stub. Mutation
        // testing had this defaulting the other way and nothing objected,
        // which was the tell: the two outcomes are not symmetrical. Guessing
        // "stub" costs a version string, because the path is resolved through
        // the developer directory or skipped. Guessing "not a stub" means
        // running it, and if it was a stub with nothing behind it that is the
        // install dialog. Under uncertainty, take the side that cannot
        // interrupt somebody.
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
              let links = attributes[.referenceCount] as? Int else { return true }
        return links > 1
    }

    /// Where the real developer tools live.
    ///
    /// Read from the symlink `xcode-select` maintains, not by running
    /// `xcode-select` -- the whole point here is to stop invoking things to
    /// find out whether invoking them is safe.
    static func developerDirectory(systemRoot: URL) -> String? {
        let fm = FileManager.default
        guard let root = try? CanonicalPath.resolve(systemRoot) else { return nil }
        let rootPath = root.path

        func isContained(_ url: URL) -> Bool {
            let path = url.path
            return rootPath == "/"
                ? path.hasPrefix("/")
                : path == rootPath || path.hasPrefix(rootPath + "/")
        }

        func existingDeveloper(at url: URL) -> String? {
            guard let directory = try? CanonicalPath.resolve(url),
                  isContained(directory),
                  let binaries = try? CanonicalPath.resolve(
                    directory.appending(path: "usr/bin")) else { return nil }
            var isDirectory: ObjCBool = false
            guard isContained(binaries),
                  fm.fileExists(atPath: binaries.path, isDirectory: &isDirectory),
                  isDirectory.boolValue else { return nil }
            return directory.path
        }

        // Resolve the link's parent first. Otherwise a symlinked `var` or `db`
        // could make even reading xcode_select_link escape a sealed test root.
        let lexicalLink = root.appending(path: "var/db/xcode_select_link")
        if let linkParent = try? CanonicalPath.resolve(
            lexicalLink.deletingLastPathComponent()), isContained(linkParent) {
            let link = linkParent.appending(path: lexicalLink.lastPathComponent)
            if let destination = try? fm.destinationOfSymbolicLink(atPath: link.path) {
                // Absolute targets keep their filesystem meaning; relative ones
                // are interpreted from the link's directory. Both are accepted
                // only after canonicalization proves they remain under root.
                let target = destination.hasPrefix("/")
                    ? URL(filePath: destination)
                    : linkParent.appending(path: destination)
                if let found = existingDeveloper(at: target) { return found }
            }
        }

        for fallback in ["Library/Developer/CommandLineTools",
                         "Applications/Xcode.app/Contents/Developer"] {
            if let found = existingDeveloper(at: root.appending(path: fallback)) {
                return found
            }
        }
        return nil
    }

    /// One program's own account of its version, or nil.
    ///
    /// Both `--version` and `-version` are tried, because the JVM tools have
    /// never accepted the first, and both streams are read, because roughly
    /// half of all CLIs print their version to stderr.
    static func version(
        ofProgramAt path: String, environment: [String: String],
        workingDirectory: URL? = nil, timeout: Double
    ) async -> String? {
        for flag in ["--version", "-version"] {
            // The working directory is pinned for the same reason the
            // environment is. mise, direnv and asdf all answer differently
            // depending on where they are standing, and a version that depends
            // on which directory the app was launched from is not a fact.
            let result = await Exec.run(
                URL(filePath: path), [flag], environment: environment,
                workingDirectory: workingDirectory, timeout: timeout)
            // The exit status is deliberately ignored. Plenty of tools print a
            // perfectly good version banner and then exit non-zero because the
            // flag was technically a usage error.
            if let found = versionToken(in: result.stdout) ?? versionToken(in: result.stderr) {
                return found
            }
        }
        return nil
    }

    /// The first thing in a line of output that looks like a version.
    ///
    /// Deliberately dumb, and deliberately anchored on "two numbers separated
    /// by a dot". Every banner shape that matters puts the version first among
    /// the things of that shape -- `git version 2.51.0`, `go version go1.24.0
    /// darwin/arm64`, `Python 3.9.6`, `v22.1.0` -- and a parser that tried to
    /// understand the surrounding words would be a per-tool special case, which
    /// is the thing this whole design refuses to accumulate.
    static func versionToken(in output: String) -> String? {
        let pattern = "[0-9]+\\.[0-9]+(\\.[0-9]+)*(-[A-Za-z0-9.]+)?"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let text = output.prefix(2000)   // a banner, not a manual
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: String(text), range: range),
              let found = Range(match.range, in: text) else { return nil }
        return String(text[found])
    }

    /// The inverse of `abbreviate`: a stored `~/...` back to something runnable.
    static func expand(_ path: String, home: String) -> String {
        guard path == "~" || path.hasPrefix("~/") else { return path }
        return home + path.dropFirst(1)
    }
}
