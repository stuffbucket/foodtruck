import Foundation

extension Inventory {

    /// Ask the programs we actually care about what version they are.
    ///
    /// The scan can only infer a version from an install layout, which fails in
    /// both directions: a hand-installed binary has no layout to read, and a
    /// managed one moved somewhere unusual reads as whatever the directory
    /// above it happens to be called. Neither is a good enough answer about a
    /// tool someone is trying to keep pinned, so for a declared and short list
    /// -- `Inventory.interesting` -- FoodTruck runs the program and believes
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
        systemRoot: URL = URL(filePath: "/"), timeout: Double = 3,
        reusing previous: Inventory? = nil
    ) async -> Inventory {
        let homePath = home.standardizedFileURL.path
        let developer = Self.developerDirectory(systemRoot: systemRoot)

        var known: [String: Installed] = [:]
        for tool in previous?.tools ?? [] where tool.versionSource == .probed {
            known[tool.path] = tool
        }

        var updated = self
        var candidates: [(index: Int, target: String)] = []
        for index in tools.indices {
            let tool = tools[index]
            guard let target = probeTarget(for: tool, home: homePath, systemRoot: systemRoot,
                                           developerDirectory: developer) else { continue }
            if let cached = known[tool.path], cached.stamp != nil, cached.stamp == tool.stamp {
                updated.tools[index].version = cached.version
                updated.tools[index].versionSource = .probed
            } else {
                candidates.append((index, target))
            }
        }
        guard !candidates.isEmpty else { return updated }
        // The ceiling. Nothing below this line runs if the gate produced more
        // work than the declared list could possibly justify.
        guard candidates.count <= Self.probeCeiling else {
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
        env["HOME"] = scratch.path
        for key in ["XDG_CONFIG_HOME", "XDG_DATA_HOME", "XDG_STATE_HOME", "XDG_CACHE_HOME"] {
            env[key] = scratch.path
        }
        // A program we are only asking the version of has no business knowing
        // where FoodTruck keeps anything.
        for key in env.keys where key.hasPrefix("FOODTRUCK_") { env.removeValue(forKey: key) }

        let probed: [Int: String] = await withTaskGroup(
            of: (Int, String?).self
        ) { group in
            var found: [Int: String] = [:]
            var next = 0
            // A fixed window rather than one task per candidate. Start at most
            // `probeWindow`, and only add another as one finishes.
            func start() {
                guard next < candidates.count else { return }
                let (index, target) = candidates[next]
                next += 1
                group.addTask {
                    (index, await Self.version(ofProgramAt: target,
                                               environment: env,
                                               workingDirectory: scratch,
                                               timeout: timeout))
                }
            }
            for _ in 0..<Swift.min(Self.probeWindow, candidates.count) { start() }
            while let (index, version) = await group.next() {
                if let version { found[index] = version }
                start()
            }
            return found
        }

        for (index, version) in probed {
            updated.tools[index].version = version
            updated.tools[index].versionSource = .probed
        }
        updated.managers = await updated.managerVersions(
            environment: env, workingDirectory: scratch,
            home: homePath, timeout: timeout)
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
    func managerVersions(
        environment: [String: String], workingDirectory: URL,
        home: String, timeout: Double
    ) async -> [Manager] {
        var resolved: [Manager] = []
        for var manager in managers {
            guard !manager.shellFunction else { resolved.append(manager); continue }

            if let known = tools.first(where: {
                $0.path == manager.evidence && $0.versionSource == .probed
            }) {
                manager.version = known.version
            } else if let spec = Self.managerCatalogue.first(where: { $0.id == manager.id }),
                      let binary = spec.binaries.first {
                // Found as a directory rather than on PATH: look inside it.
                let candidate = Self.expand(manager.evidence, home: home)
                    + "/bin/" + binary
                if FileManager.default.isExecutableFile(atPath: candidate) {
                    manager.version = await Self.version(
                        ofProgramAt: candidate, environment: environment,
                        workingDirectory: workingDirectory, timeout: timeout)
                }
            }
            resolved.append(manager)
        }
        return resolved
    }

    /// The most programs one pass may run, whatever the rest of this file
    /// believes.
    ///
    /// A second bound, independent of every decision below it. `probeTarget`
    /// decides what is safe to run; a single wrong `return` inside it turned
    /// "run the declared list" into "run everything on this machine", and one
    /// character is all it took. A ceiling cannot be inverted by that mistake,
    /// because it is derived from the size of the declared list rather than
    /// from any of the reasoning about it. A candidate set larger than this is
    /// a bug in the gate, not a machine with unusual software, and the correct
    /// response to a bug in the gate is to run nothing at all.
    static var probeCeiling: Int { interesting.count }

    /// The path to actually execute for this tool, or nil if it must not be
    /// run at all.
    ///
    /// One decision point, because two of them is how the last accident
    /// happened. It answers three separate questions.
    ///
    /// Is it declared? Only names on `interesting` are ever run.
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
        for tool: Installed, home: String, systemRoot: URL, developerDirectory: String?
    ) -> String? {
        guard Self.interesting.contains(tool.name) else { return nil }
        if tool.shim { return nil }

        let path = Self.expand(tool.path, home: home)
        guard Self.isDeveloperStub(path, systemRoot: systemRoot) else { return path }

        // A stub is not the tool; it is a forwarder. Run what it forwards to,
        // and only if that is actually there. A stub with nothing behind it is
        // precisely what puts up "the cmpdylib command requires the command
        // line developer tools" -- and that dialog is not a question anybody
        // can be expected to answer, so it must never be asked.
        guard let developerDirectory else { return nil }
        let real = developerDirectory + "/usr/bin/" + tool.name
        return FileManager.default.isExecutableFile(atPath: real) ? real : nil
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
        let root = systemRoot.standardizedFileURL.path
        let base = root == "/" ? "" : root
        let system = ["/usr/bin/", "/bin/", "/usr/sbin/", "/sbin/"].map { base + $0 }
        guard system.contains(where: { path.hasPrefix($0) }) else { return false }
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
              let links = attributes[.referenceCount] as? Int else { return false }
        return links > 1
    }

    /// Where the real developer tools live.
    ///
    /// Read from the symlink `xcode-select` maintains, not by running
    /// `xcode-select` -- the whole point here is to stop invoking things to
    /// find out whether invoking them is safe.
    static func developerDirectory(systemRoot: URL) -> String? {
        let fm = FileManager.default
        let link = systemRoot.appending(path: "var/db/xcode_select_link")
        if let destination = try? fm.destinationOfSymbolicLink(atPath: link.path),
           fm.fileExists(atPath: destination + "/usr/bin") {
            return destination
        }
        for fallback in ["Library/Developer/CommandLineTools",
                         "Applications/Xcode.app/Contents/Developer"] {
            let url = systemRoot.appending(path: fallback)
            if fm.fileExists(atPath: url.appending(path: "usr/bin").path) { return url.path }
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
