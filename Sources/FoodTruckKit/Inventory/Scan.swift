import Darwin
import Foundation

/// Canonical filesystem roots authorized by one resolved settings profile.
/// Home and the system root are separate trust domains: either may be a sibling
/// of the other in a sealed run, and symlinks may not escape either domain.
struct InventoryBoundary: Sendable {
    private let roots: Set<String>

    init(home: URL? = nil, systemRoot: URL) {
        let urls = [home, systemRoot].compactMap { $0 }
        roots = Set(urls.compactMap { try? CanonicalPath.resolve($0).path })
    }

    func contains(_ url: URL) -> Bool {
        guard let path = try? CanonicalPath.resolve(url).path else { return false }
        return containsCanonical(path)
    }

    func containsCanonical(_ path: String) -> Bool {
        roots.contains { root in
            root == "/" ? path.hasPrefix("/")
                : path == root || path.hasPrefix(root + "/")
        }
    }
}

extension Inventory {

    /// Look at the machine and describe it, without running any of it.
    /// Policy is supplied by a resolved settings profile; the code here retains
    /// only the boundaries that must not be configurable.
    public static func scan(
        home: URL,
        locations: Locations,
        settings: ResolvedInventorySettings,
        systemRoot: URL,
        roots explicitRoots: [URL]? = nil
    ) -> Inventory {
        let toolbox = locations.toolbox.standardizedFileURL.path
        let resolvedToolbox = (try? CanonicalPath.resolve(locations.toolbox).path)
            ?? locations.toolbox.standardizedFileURL.path
        let configuredRoots = explicitRoots ?? Self.roots(
            home: home, settings: settings, systemRoot: systemRoot)
        let shimRoots = declaredShimRoots(settings: settings)
        let matchers = originMatchers(
            home: home, settings: settings, systemRoot: systemRoot)
        let boundary = InventoryBoundary(home: home, systemRoot: systemRoot)

        // Canonicalize before enumerating. In a sealed scan, a lexical child can
        // itself be a symlink to the host filesystem; rejecting that resolved
        // path is what makes systemRoot a boundary rather than a spelling rule.
        // Production uses `/`, where ordinary symlinked PATH entries remain valid.
        var seenRoots: Set<String> = []
        let searched: [(url: URL, shimOrigin: Origin?)] = configuredRoots.compactMap { root in
            let standardized = root.standardizedFileURL
            guard let resolvedURL = try? CanonicalPath.resolve(standardized) else { return nil }
            let resolved = resolvedURL.path
            guard !isUnder(standardized.path, root: toolbox),
                  !isUnder(resolved, root: resolvedToolbox),
                  boundary.containsCanonical(resolved),
                  seenRoots.insert(resolved).inserted else { return nil }
            return (resolvedURL, shimRoots[standardized.path] ?? shimRoots[resolved])
        }
        let homePath = (try? CanonicalPath.resolve(home).path)
            ?? home.standardizedFileURL.path

        var tools: [Installed] = []
        var scanned: [URL] = []
        for root in searched {
            guard let programs = programs(in: root.url) else { continue }
            scanned.append(root.url)
            for program in programs {
                guard let resolvedProgram = try? CanonicalPath.resolve(program).path else {
                    continue
                }
                guard !isUnder(resolvedProgram, root: resolvedToolbox),
                      boundary.containsCanonical(resolvedProgram)
                else { continue }

                // `attributesOfItem` does not follow the link, so this asks if
                // the directory entry is a symlink rather than whether resolving
                // its parents changes the spelling of the path.
                let attributes = try? FileManager.default.attributesOfItem(atPath: program.path)
                let isLink = (attributes?[.type] as? FileAttributeType) == .typeSymbolicLink
                let real = isLink ? (try? CanonicalPath.resolve(program).path) : nil

                // A shim's target describes its manager, not the tool represented
                // by the shim. The root is classified by explicit scan metadata,
                // rather than treating any path containing `/shims/` as trusted.
                let origin = root.shimOrigin
                    ?? origin(of: program.path, real: root.shimOrigin == nil ? real : nil,
                              toolbox: toolbox, matchers: matchers)
                guard origin != .foodtruck else { continue }

                let inferred = root.shimOrigin == nil ? version(from: real ?? program.path) : nil
                tools.append(Installed(
                    name: program.lastPathComponent,
                    path: abbreviate(program.path, home: homePath),
                    real: real.map { abbreviate($0, home: homePath) },
                    origin: origin,
                    version: inferred,
                    versionSource: inferred == nil ? nil : .inferred,
                    shim: root.shimOrigin != nil,
                    stamp: stamp(of: real ?? program.path)))
            }
        }
        tools.sort { ($0.name, $0.path) < ($1.name, $1.path) }

        var inventory = Inventory(
            host: host(systemRoot: systemRoot),
            roots: scanned.map { abbreviate($0.path, home: homePath) },
            tools: tools)
        inventory.managers = inventory.detectedManagers(
            home: home, settings: settings, systemRoot: systemRoot)
        let discovery = discoverSoftware(
            home: home, settings: settings, systemRoot: systemRoot)
        inventory.software = discovery.artifacts
        inventory.softwareRoots = discovery.roots
        inventory.softwareDiscoveryRefused = discovery.refused
        return inventory
    }

    // MARK: - Where to look

    /// Resolve the ordered scan declarations and direct sources supplied by the
    /// settings profile. Declaration files contain one root per line; declaration
    /// directories are read in filename order.
    public static func roots(home: URL, settings: ResolvedInventorySettings,
                             systemRoot: URL) -> [URL] {
        let fm = FileManager.default
        var candidates: [URL] = []

        func rootsDeclared(in file: URL) -> [URL] {
            guard let text = try? String(contentsOf: file, encoding: .utf8) else { return [] }
            return text.split(separator: "\n").compactMap { line in
                let path = line.trimmingCharacters(in: .whitespaces)
                guard !path.isEmpty else { return nil }
                if path == "~" { return home.standardizedFileURL }
                if path.hasPrefix("~/") {
                    return home.appending(path: String(path.dropFirst(2))).standardizedFileURL
                }
                guard path.hasPrefix("/") else { return nil }
                if path == "/" { return systemRoot.standardizedFileURL }
                return systemRoot.appending(path: String(path.dropFirst())).standardizedFileURL
            }
        }

        for declaration in settings.scanDeclarations {
            switch declaration.type {
            case .file:
                candidates += rootsDeclared(in: declaration.url)
            case .directory:
                guard let files = try? fm.contentsOfDirectory(
                    at: declaration.url, includingPropertiesForKeys: nil) else { continue }
                for file in files.sorted(by: { $0.path < $1.path }) {
                    candidates += rootsDeclared(in: file)
                }
            }
        }
        candidates += settings.scanSources
        candidates += settings.managers.flatMap { manager in
            manager.scanRoots.map(\.url)
        }

        var roots: [URL] = []
        var seen: Set<String> = []
        for candidate in candidates {
            let standardized = candidate.standardizedFileURL
            var isDirectory: ObjCBool = false
            guard fm.fileExists(atPath: standardized.path, isDirectory: &isDirectory),
                  isDirectory.boolValue,
                  seen.insert(standardized.path).inserted else { continue }
            roots.append(standardized)
        }
        return roots
    }

    /// Executable regular files in one directory. Nil distinguishes a failed
    /// directory read from a successfully read empty directory.
    static func programs(in root: URL) -> [URL]? {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: root.path) else { return nil }
        return names.sorted().compactMap { name in
            let url = root.appending(path: name)
            var isDirectory: ObjCBool = false
            guard fm.fileExists(atPath: url.path, isDirectory: &isDirectory),
                  !isDirectory.boolValue,
                  fm.isExecutableFile(atPath: url.path) else { return nil }
            return url
        }
    }

    // MARK: - Attribution

    private struct ResolvedOriginMatcher {
        let origin: Origin
        let match: OriginMatch
        let patterns: [String]
        let roots: [String]
    }

    /// Compile ordered settings rules once for a scan. Homebrew roots retain a
    /// non-configurable proof requirement: a prefix is not Homebrew merely
    /// because a user placed its path in settings.
    private static func originMatchers(
        home: URL, settings: ResolvedInventorySettings, systemRoot: URL
    ) -> [ResolvedOriginMatcher] {
        let fm = FileManager.default
        let boundary = InventoryBoundary(home: home, systemRoot: systemRoot)
        return settings.origins.compactMap { rule in
            // These are boundaries, not policy. FoodTruck is established from
            // Locations and unmanaged is the result of no rule matching.
            guard rule.origin != .foodtruck, rule.origin != .unmanaged else { return nil }
            let required = rule.origin == .homebrew && rule.match == .under
                ? Array(Set(rule.requires + ["Cellar", "Library/Homebrew"]))
                : rule.requires
            let roots = rule.paths.compactMap { url -> String? in
                guard let canonical = try? CanonicalPath.resolve(url) else { return nil }
                let root = canonical.path
                guard boundary.containsCanonical(root),
                      required.allSatisfy({ marker in
                          var isDirectory: ObjCBool = false
                          return fm.fileExists(
                              atPath: canonical.appending(path: marker).path,
                              isDirectory: &isDirectory) && isDirectory.boolValue
                      }) else { return nil }
                return root
            }
            return ResolvedOriginMatcher(
                origin: rule.origin, match: rule.match,
                patterns: rule.patterns, roots: roots)
        }
    }

    /// Which channel installed this, checking the resolved target first because
    /// link-based package managers leave their evidence there.
    private static func origin(of path: String, real: String?, toolbox: String,
                               matchers: [ResolvedOriginMatcher]) -> Origin {
        if let real {
            let resolved = classify(real, toolbox: toolbox, matchers: matchers)
            if resolved != .unmanaged { return resolved }
        }
        return classify(path, toolbox: toolbox, matchers: matchers)
    }

    private static func classify(_ path: String, toolbox: String,
                                 matchers: [ResolvedOriginMatcher]) -> Origin {
        if isUnder(path, root: toolbox) { return .foodtruck }
        for matcher in matchers {
            switch matcher.match {
            case .contains:
                if matcher.patterns.contains(where: { path.contains($0) }) {
                    return matcher.origin
                }
            case .under:
                if matcher.roots.contains(where: { isUnder(path, root: $0) }) {
                    return matcher.origin
                }
            }
        }
        return .unmanaged
    }

    /// Exact-or-descendant matching, so `/opt/homebrew-old` is not considered
    /// beneath `/opt/homebrew`.
    static func isUnder(_ path: String, root: String) -> Bool {
        var root = root
        while root.count > 1, root.hasSuffix("/") { root.removeLast() }
        if root == "/" { return path.hasPrefix("/") }
        return path == root || path.hasPrefix(root + "/")
    }

    /// Shims are an explicit property of a scan source or manager scan root,
    /// not of an arbitrary path containing a directory with that name. PathSource
    /// has already resolved relocated homes before this point.
    private static func declaredShimRoots(
        settings: ResolvedInventorySettings
    ) -> [String: Origin] {
        var roots: [String: Origin] = [:]

        func record(_ root: URL, as origin: Origin) {
            let standardized = root.standardizedFileURL
            roots[standardized.path] = origin
            if let canonical = try? CanonicalPath.resolve(standardized).path {
                roots[canonical] = origin
            }
        }

        // A scan source may declare safety independently of manager reporting.
        // Its origin remains unknown unless a manager declaration claims the
        // same root below.
        for root in settings.scanRoots where root.kind == .shim {
            record(root.url, as: .unmanaged)
        }
        for manager in settings.managers {
            for root in manager.scanRoots where root.kind == .shim {
                record(root.url, as: Origin(rawValue: manager.id))
            }
        }
        return roots
    }

    /// Infer a version only from install-layout components with a numeric value.
    static func version(from path: String) -> String? {
        let parts = path.split(separator: "/").map(String.init)
        for marker in ["Cellar", "installs"] {
            guard let index = parts.firstIndex(of: marker), index + 2 < parts.count else { continue }
            let candidate = parts[index + 2]
            if let first = candidate.first, first.isNumber { return candidate }
        }
        return nil
    }

    static func stamp(of path: String) -> String? {
        guard let target = try? CanonicalPath.resolve(URL(filePath: path)).path else {
            return nil
        }
        var metadata = Darwin.stat()
        guard Darwin.lstat(target, &metadata) == 0 else { return nil }

        // File identity catches atomic replacement; nanosecond mtime and ctime
        // catch in-place rewrites even when size and whole-second mtime survive.
        // The canonical target also invalidates the cache when a symlink retargets.
        return [
            "v3", target,
            String(metadata.st_dev), String(metadata.st_ino), String(metadata.st_size),
            String(metadata.st_mtimespec.tv_sec), String(metadata.st_mtimespec.tv_nsec),
            String(metadata.st_ctimespec.tv_sec), String(metadata.st_ctimespec.tv_nsec),
        ].joined(separator: ":")
    }

    static func abbreviate(_ path: String, home: String) -> String {
        guard !home.isEmpty else { return path }
        let canonicalHome = (try? CanonicalPath.resolve(URL(filePath: home)).path) ?? home
        let canonicalPath = path.hasPrefix("/")
            ? ((try? CanonicalPath.resolve(URL(filePath: path)).path) ?? path)
            : path
        guard canonicalPath == canonicalHome
                || canonicalPath.hasPrefix(canonicalHome + "/") else {
            return canonicalPath
        }
        return "~" + canonicalPath.dropFirst(canonicalHome.count)
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
              let dictionary = plist as? [String: Any] else { return [:] }
        return dictionary.compactMapValues { $0 as? String }
    }

    private static func string<T>(from field: inout T) -> String {
        withUnsafePointer(to: &field) {
            $0.withMemoryRebound(to: CChar.self, capacity: MemoryLayout<T>.size) {
                String(cString: $0)
            }
        }
    }
}
