import Foundation

extension Inventory {

    /// Look at the machine and describe it, without running any of it.
    ///
    /// This half is directory reads, `lstat` and two plists -- nothing here
    /// executes anything, because the alternative is running a few thousand
    /// unknown binaries to find out what they are. The versions this can
    /// produce are therefore inferred from install layouts, and marked as such.
    ///
    /// Asking the programs themselves is a second, deliberately narrow pass:
    /// see `probingVersions`.
    public static func scan(
        home: URL,
        locations: Locations,
        systemRoot: URL = URL(filePath: "/"),
        roots explicitRoots: [URL]? = nil
    ) -> Inventory {
        let searched = explicitRoots ?? Self.roots(
            home: home, locations: locations, systemRoot: systemRoot)
        let homePath = home.standardizedFileURL.path
        let toolbox = locations.toolbox.standardizedFileURL.path
        let brewPrefixes = homebrewPrefixes(systemRoot: systemRoot)

        var tools: [Installed] = []
        for root in searched {
            for program in programs(in: root) {
                // `attributesOfItem` does not follow the link, so this asks
                // "is this entry a symlink" rather than "does resolving it
                // change the string" -- which would answer yes for every file
                // under a temp directory, where `/var` is itself a link.
                let attributes = try? FileManager.default.attributesOfItem(atPath: program.path)
                let isLink = (attributes?[.type] as? FileAttributeType) == .typeSymbolicLink
                let real = isLink ? program.resolvingSymlinksInPath().path : nil
                // Every manager that works this way uses the same word for the
                // directory, which is what makes one test cover mise, asdf,
                // pyenv and rbenv alike.
                let isShim = program.path.contains("/shims/")
                // A shim's link is followed at your peril. `mise/shims/node`
                // points at the mise binary, which is itself a Cellar symlink,
                // so resolving the chain lands on `Cellar/mise/2026.8.8/` --
                // and reading that back gives Homebrew as the installer of
                // `node` and mise's version as the version of `node`. Both
                // wrong, and wrong in the confident way. A shim is described by
                // where it sits and nothing else.
                let origin = isShim
                    ? origin(of: program.path, real: nil, home: homePath,
                             toolbox: toolbox, brewPrefixes: brewPrefixes)
                    : origin(of: program.path, real: real, home: homePath,
                             toolbox: toolbox, brewPrefixes: brewPrefixes)
                // Nil for a shim, and not by omission: a shim has no version of
                // its own, and the only path leading away from it describes the
                // manager instead.
                let inferred = isShim ? nil : version(from: real ?? program.path)
                tools.append(Installed(
                    name: program.lastPathComponent,
                    path: abbreviate(program.path, home: homePath),
                    real: real.map { abbreviate($0, home: homePath) },
                    origin: origin,
                    version: inferred,
                    versionSource: inferred == nil ? nil : .inferred,
                    shim: isShim,
                    stamp: stamp(of: real ?? program.path)))
            }
        }
        // Sorted so that two snapshots of an unchanged machine are byte
        // identical, which is what makes a diff mean something.
        tools.sort { ($0.name, $0.path) < ($1.name, $1.path) }

        let rootPaths = searched.map { abbreviate($0.path, home: homePath) }
        return Inventory(
            host: host(systemRoot: systemRoot),
            roots: rootPaths,
            tools: tools,
            managers: managers(tools: tools, roots: rootPaths,
                               home: home, systemRoot: systemRoot))
    }

    // MARK: - Where to look

    /// The directories FoodTruck searches.
    ///
    /// Deliberately a declared list rather than `$PATH`. An app launched from
    /// Finder does not inherit the shell's `PATH` -- the same fact `Exec` is
    /// built around -- so scanning `$PATH` would make the inventory depend on
    /// how FoodTruck happened to be started, and every one of those differences
    /// would land in the history as a change that never happened.
    ///
    /// The system's own answer comes from `/etc/paths` and `/etc/paths.d`, read
    /// directly rather than by running `path_helper`. Then the per-manager
    /// directories, which is where anything interesting actually lives. A
    /// directory a shell rc invented is not searched, and is not claimed to be:
    /// `roots` travels in the snapshot for exactly that reason.
    public static func roots(home: URL, locations: Locations, systemRoot: URL) -> [URL] {
        var out: [URL] = []
        var seen: Set<String> = []
        let fm = FileManager.default

        func add(_ url: URL) {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue
            else { return }
            let path = url.standardizedFileURL.path
            if seen.insert(path).inserted { out.append(URL(filePath: path)) }
        }

        let etc = systemRoot.appending(path: "etc")
        var declared: [String] = []
        if let text = try? String(contentsOf: etc.appending(path: "paths"), encoding: .utf8) {
            declared += text.split(separator: "\n").map(String.init)
        }
        if let files = try? fm.contentsOfDirectory(
            at: etc.appending(path: "paths.d"), includingPropertiesForKeys: nil) {
            for file in files.sorted(by: { $0.path < $1.path }) {
                if let text = try? String(contentsOf: file, encoding: .utf8) {
                    declared += text.split(separator: "\n").map(String.init)
                }
            }
        }
        for entry in declared {
            let trimmed = entry.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            add(trimmed.hasPrefix("/")
                ? systemRoot.appending(path: String(trimmed.dropFirst()))
                : URL(filePath: trimmed))
        }

        for path in ["opt/homebrew/bin", "opt/homebrew/sbin",
                     "usr/local/bin", "usr/local/sbin"] {
            add(systemRoot.appending(path: path))
        }
        for path in [".local/bin", ".local/share/mise/shims", ".asdf/shims",
                     ".cargo/bin", "go/bin", ".bun/bin", ".deno/bin"] {
            add(home.appending(path: path))
        }
        add(locations.toolbox)
        return out
    }

    /// Executable regular files in one directory.
    ///
    /// Directories are excluded explicitly: `isExecutableFile` is true for any
    /// directory you have search permission on, so trusting it alone would file
    /// every subfolder of `/usr/local/bin` as an installed program.
    static func programs(in root: URL) -> [URL] {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: root.path) else { return [] }
        return names.sorted().compactMap { name in
            let url = root.appending(path: name)
            var isDir: ObjCBool = false
            // Follows symlinks, so a dangling link is absent rather than a
            // program that cannot be run.
            guard fm.fileExists(atPath: url.path, isDirectory: &isDir), !isDir.boolValue,
                  fm.isExecutableFile(atPath: url.path) else { return nil }
            return url
        }
    }

    // MARK: - Attribution

    /// Which channel installed this, judged by where it lands.
    ///
    /// Both the directory entry and what it resolves to get a vote, because the
    /// two managers in play here hide the evidence in opposite places. Homebrew
    /// puts a symlink in `bin` pointing into a Cellar, so only the *resolved*
    /// path names it. mise puts a shim in its own directory pointing at the mise
    /// binary, so only the *entry* path names it -- following the link there
    /// leads to `mise` itself and loses the tool entirely.
    ///
    /// The resolved path is asked first and only overruled when it has nothing
    /// to say. That ordering is what keeps `/opt/homebrew/bin` honest: a symlink
    /// into a Cellar is Homebrew's, and a real binary somebody copied in beside
    /// it belongs to nobody -- which is exactly the thing worth reporting, and
    /// what `brew doctor` would say about it too.
    static func origin(of path: String, real: String?, home: String,
                       toolbox: String, brewPrefixes: [String] = []) -> Origin {
        if let real {
            let resolved = classify(real, home: home, toolbox: toolbox,
                                    brewPrefixes: brewPrefixes)
            if resolved != .unmanaged { return resolved }
        }
        return classify(path, home: home, toolbox: toolbox, brewPrefixes: brewPrefixes)
    }

    /// Directories that are demonstrably a Homebrew installation, established by
    /// looking for the two things one always has rather than by recognising a
    /// path name.
    ///
    /// This matters because the two layouts disagree about where `brew` itself
    /// lives. On Intel the prefix is `/usr/local` and the checkout is
    /// `/usr/local/Homebrew`, so `brew` is a symlink between them. On Apple
    /// silicon the prefix *is* the checkout, so `brew` is a plain file sitting
    /// in `/opt/homebrew/bin` -- indistinguishable, by shape alone, from
    /// something a person copied there.
    ///
    /// The cost of this is real and worth stating: a file somebody did copy
    /// into `<prefix>/bin` is now attributed to Homebrew rather than reported
    /// as unmanaged. Telling those apart properly means asking the checkout --
    /// `git -C <prefix> ls-files` -- which is what `brew doctor` does for its
    /// "unbrewed files" check, and is the better answer once there is a
    /// Homebrew recipe to put it in. Until then this errs towards not making a
    /// false accusation about a tool the user certainly did not install by hand.
    static func homebrewPrefixes(systemRoot: URL) -> [String] {
        let fm = FileManager.default
        return ["opt/homebrew", "usr/local", "home/linuxbrew/.linuxbrew"].compactMap { relative in
            let prefix = systemRoot.appending(path: relative)
            for marker in ["Cellar", "Library/Homebrew"] {
                var isDir: ObjCBool = false
                guard fm.fileExists(atPath: prefix.appending(path: marker).path,
                                    isDirectory: &isDir), isDir.boolValue else { return nil }
            }
            return prefix.standardizedFileURL.path
        }
    }

    private static func classify(_ p: String, home: String, toolbox: String,
                                 brewPrefixes: [String]) -> Origin {
        func under(_ prefix: String) -> Bool {
            p.hasPrefix(prefix.hasSuffix("/") ? prefix : prefix + "/")
        }

        if under(toolbox) { return .foodtruck }
        // Never a bare `/homebrew/` match: `/opt/homebrew/bin` is a directory
        // anyone can drop a file into, and crediting Homebrew for that would
        // hide the one install nobody is looking after.
        if p.contains("/Cellar/") { return .homebrew }
        for prefix in brewPrefixes where under(prefix) { return .homebrew }
        if p.contains("/mise/installs/") || p.contains("/mise/shims/") { return .mise }
        if p.contains("/.asdf/") { return .asdf }
        if under(home + "/.cargo") { return .cargo }
        if p.contains("/lib/node_modules/") { return .npm }
        if p.contains("/pipx/venvs/") { return .pipx }
        if p.contains("/gems/") { return .gem }
        if under(home + "/go/bin") { return .go }
        if under("/Library/Developer/CommandLineTools") { return .xcode }
        if under("/Applications/Xcode.app") { return .xcode }
        // `/System` covers the cryptexes, where macOS now keeps things like
        // safaridriver that used to sit in /usr/bin.
        for system in ["/usr/bin", "/bin", "/usr/sbin", "/sbin", "/usr/libexec", "/System"]
        where under(system) { return .apple }
        return .unmanaged
    }

    /// The version a package manager already wrote into the path it installed
    /// to. Nil when the layout does not say, which is the honest answer for
    /// anything installed by hand.
    ///
    /// This is a convention, not a fact, which is why what it produces is
    /// recorded as `.inferred` and why a probe overrules it.
    static func version(from path: String) -> String? {
        let parts = path.split(separator: "/").map(String.init)
        for marker in ["Cellar", "installs"] {
            guard let i = parts.firstIndex(of: marker), i + 2 < parts.count else { continue }
            let candidate = parts[i + 2]
            // Guard against reading a directory name that merely sits in the
            // right position. A version starts with a digit.
            if let first = candidate.first, first.isNumber { return candidate }
        }
        return nil
    }

    /// Size and modification time of a file, as `<bytes>:<epoch>`.
    ///
    /// Enough to say "this is the same binary I looked at last time" without
    /// hashing a few hundred megabytes, and enough to say "this one changed"
    /// for a program that carries no version anywhere.
    static func stamp(of path: String) -> String? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
              let size = attributes[.size] as? Int,
              let modified = attributes[.modificationDate] as? Date else { return nil }
        return "\(size):\(Int(modified.timeIntervalSince1970))"
    }

    /// `$HOME` written as `~`, so a snapshot carries no username and two Macs
    /// belonging to the same person produce comparable records.
    static func abbreviate(_ path: String, home: String) -> String {
        guard !home.isEmpty, path == home || path.hasPrefix(home + "/") else { return path }
        return "~" + path.dropFirst(home.count)
    }

    // MARK: - The machine

    static func host(systemRoot: URL) -> Host {
        let plist = systemRoot.appending(
            path: "System/Library/CoreServices/SystemVersion.plist")
        let system = dictionary(at: plist)

        var uts = utsname()
        uname(&uts)

        return Host(
            product: system["ProductName"] ?? "macOS",
            version: system["ProductVersion"] ?? "unknown",
            build: system["ProductBuildVersion"] ?? "unknown",
            arch: string(from: &uts.machine),
            kernel: string(from: &uts.release),
            commandLineTools: dictionary(at: systemRoot.appending(
                path: "Library/Developer/CommandLineTools/SDKs/MacOSX.sdk/SDKSettings.plist"
            ))["Version"])
    }

    private static func dictionary(at url: URL) -> [String: String] {
        guard let data = try? Data(contentsOf: url),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil),
              let dict = plist as? [String: Any] else { return [:] }
        return dict.compactMapValues { $0 as? String }
    }

    /// `utsname` fields are fixed-size C char tuples; this is the standard way
    /// to read one back as a String without guessing at its length.
    private static func string<T>(from field: inout T) -> String {
        withUnsafePointer(to: &field) {
            $0.withMemoryRebound(to: CChar.self, capacity: MemoryLayout<T>.size) {
                String(cString: $0)
            }
        }
    }
}
