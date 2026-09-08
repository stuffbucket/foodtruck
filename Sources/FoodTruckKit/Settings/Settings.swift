import Foundation

/// FoodTruck's versioned, user-editable policy. The shipped copy is the
/// complete policy; a user document is an overlay on that signed default.
public struct FoodTruckSettings: Codable, Sendable, Equatable {
    public static let currentSchema = "foodtruck.settings/1"

    public var schema: String
    public var vars: [String: String]
    public var inventory: InventorySettings

    public init(schema: String = Self.currentSchema, vars: [String: String] = [:],
                inventory: InventorySettings) {
        self.schema = schema
        self.vars = vars
        self.inventory = inventory
    }
}

public struct InventorySettings: Codable, Sendable, Equatable {
    public var scan: InventoryScanSettings
    public var discovery: InventoryDiscoverySettings
    public var probes: ProbeSettings
    public var managers: [ManagerDeclaration]
    public var origins: [OriginRule]
    public var gitCandidates: [SettingsPathSource]
    public var reporting: [ReportingDeclaration]

    public init(scan: InventoryScanSettings, probes: ProbeSettings,
                managers: [ManagerDeclaration], origins: [OriginRule],
                gitCandidates: [SettingsPathSource], reporting: [ReportingDeclaration],
                discovery: InventoryDiscoverySettings = InventoryDiscoverySettings()) {
        self.scan = scan
        self.discovery = discovery
        self.probes = probes
        self.managers = managers
        self.origins = origins
        self.gitCandidates = gitCandidates
        self.reporting = reporting
    }
}

public struct InventoryScanSettings: Codable, Sendable, Equatable {
    public var declarations: [PathDeclaration]
    public var sources: [SettingsPathSource]

    public init(declarations: [PathDeclaration] = [], sources: [SettingsPathSource]) {
        self.declarations = declarations
        self.sources = sources
    }
}

/// Generic, bounded ways to identify software without executing it or
/// maintaining an application catalogue in FoodTruck.
public enum SoftwareDiscoveryStrategy: String, Codable, Sendable, CaseIterable {
    case homebrewCellar
    case homebrewCaskroom
    case applicationBundles
    case topLevelFootprints
}

/// One configured software root. Exclusions are immediate child names, not
/// paths or patterns, so they can only narrow a strategy's shallow traversal.
public struct SoftwareDiscoveryRoot: Codable, Sendable, Equatable {
    public var source: SettingsPathSource
    public var strategy: SoftwareDiscoveryStrategy
    public var exclusions: [String]

    public init(source: SettingsPathSource, strategy: SoftwareDiscoveryStrategy,
                exclusions: [String] = []) {
        self.source = source
        self.strategy = strategy
        self.exclusions = exclusions
    }

    private enum CodingKeys: String, CodingKey { case source, strategy, exclusions }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        source = try values.decode(SettingsPathSource.self, forKey: .source)
        strategy = try values.decode(SoftwareDiscoveryStrategy.self, forKey: .strategy)
        exclusions = try values.decodeIfPresent([String].self, forKey: .exclusions) ?? []
    }
}

public struct InventoryDiscoverySettings: Codable, Sendable, Equatable {
    public var roots: [SoftwareDiscoveryRoot]
    /// Human-readable policy exclusions. The scanner also enforces a compiled
    /// minimum that an overlay cannot weaken.
    public var exclusions: [SettingsPathSource]

    public init(roots: [SoftwareDiscoveryRoot] = [],
                exclusions: [SettingsPathSource] = []) {
        self.roots = roots
        self.exclusions = exclusions
    }
}

public enum PathDeclarationKind: String, Codable, Sendable, CaseIterable {
    case file
    case directory
}

public struct PathDeclaration: Codable, Sendable, Equatable {
    public var type: PathDeclarationKind
    public var source: SettingsPathSource

    public init(type: PathDeclarationKind, source: SettingsPathSource) {
        self.type = type
        self.source = source
    }
}

public struct ProbeSettings: Codable, Sendable, Equatable {
    public var names: [String]

    public init(names: [String]) { self.names = names }
}

public enum ManagerScanRootKind: String, Codable, Sendable, CaseIterable {
    case direct
    case shim
}

public struct ManagerScanRoot: Codable, Sendable, Equatable {
    public var source: SettingsPathSource
    public var kind: ManagerScanRootKind

    public init(source: SettingsPathSource, kind: ManagerScanRootKind) {
        self.source = source
        self.kind = kind
    }
}

public struct ManagerDeclaration: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var binaries: [String]
    public var directories: [SettingsPathSource]
    public var manages: [String]
    public var scanRoots: [ManagerScanRoot]
    public var shellFunction: Bool
    public var roleEvidence: [SettingsPathSource]

    public init(id: String, binaries: [String] = [], directories: [SettingsPathSource] = [],
                manages: [String], scanRoots: [ManagerScanRoot] = [],
                shellFunction: Bool = false, roleEvidence: [SettingsPathSource] = []) {
        self.id = id
        self.binaries = binaries
        self.directories = directories
        self.manages = manages
        self.scanRoots = scanRoots
        self.shellFunction = shellFunction
        self.roleEvidence = roleEvidence
    }

    private enum CodingKeys: String, CodingKey {
        case id, binaries, directories, manages, scanRoots, shellFunction, roleEvidence
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        binaries = try values.decode([String].self, forKey: .binaries)
        directories = try values.decode([SettingsPathSource].self, forKey: .directories)
        manages = try values.decode([String].self, forKey: .manages)
        scanRoots = try values.decodeIfPresent([ManagerScanRoot].self, forKey: .scanRoots) ?? []
        shellFunction = try values.decode(Bool.self, forKey: .shellFunction)
        roleEvidence = try values.decode([SettingsPathSource].self, forKey: .roleEvidence)
    }
}

public enum OriginMatch: String, Codable, Sendable, CaseIterable {
    case contains
    case under
}

/// Ordered attribution rule. `contains` uses `patterns`; `under` resolves
/// `paths`, optionally accepting only roots containing every required marker.
public struct OriginRule: Codable, Sendable, Equatable {
    public var origin: Origin
    public var match: OriginMatch
    public var patterns: [String]
    public var paths: [SettingsPathSource]
    public var requires: [String]

    public init(origin: Origin, match: OriginMatch, patterns: [String] = [],
                paths: [SettingsPathSource] = [], requires: [String] = []) {
        self.origin = origin
        self.match = match
        self.patterns = patterns
        self.paths = paths
        self.requires = requires
    }
}

public enum ReportingCardinality: String, Codable, Sendable, CaseIterable {
    case once
    case perItem
}

/// Every inventory result that code may emit. The raw value is the stable key
/// used by settings; presentation lives in the corresponding declaration.
/// Cardinality is structural: it describes whether an emission requires an
/// item discriminator, rather than limiting how many findings may be reported.
enum InventoryReportID: String, CaseIterable, Sendable {
    case probeRefused
    case softwareDiscoveryRefused
    case snapshotUnreadable
    case firstObservation
    case hostChanged
    case coverageAdded
    case coverageRemoved
    case coverageReordered
    case softwareCoverageAdded
    case softwareCoverageRemoved
    case managersChanged
    case programAdded
    case programRemoved
    case programVersionChanged
    case programOriginChanged
    case programTargetChanged
    case programKindChanged
    case programReplaced
    case softwareAdded
    case softwareRemoved
    case softwareChanged
    case versionConflict
    case duplicated
    case shimShadowed
    case contested
    case unmanaged
    case noGit
    case historyFailed

    var cardinality: ReportingCardinality {
        switch self {
        case .programAdded, .programRemoved, .programVersionChanged,
             .programOriginChanged, .programTargetChanged, .programKindChanged,
             .programReplaced, .softwareAdded, .softwareRemoved, .softwareChanged,
             .versionConflict, .shimShadowed, .contested, .unmanaged:
            .perItem
        case .probeRefused, .softwareDiscoveryRefused, .snapshotUnreadable,
             .firstObservation, .hostChanged, .coverageAdded, .coverageRemoved,
             .coverageReordered, .softwareCoverageAdded, .softwareCoverageRemoved,
             .managersChanged, .duplicated, .noGit, .historyFailed:
            .once
        }
    }
}

/// A declarative inventory result. IDs are stable policy hooks; title and
/// remedy are localisation keys rather than prose.
public struct ReportingDeclaration: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var severity: Severity
    public var section: Finding.Section
    public var cardinality: ReportingCardinality
    public var title: String
    public var remedy: String?
    public var fixable: Bool

    public init(id: String, severity: Severity, section: Finding.Section,
                cardinality: ReportingCardinality = .once, title: String,
                remedy: String? = nil, fixable: Bool = false) {
        self.id = id
        self.severity = severity
        self.section = section
        self.cardinality = cardinality
        self.title = title
        self.remedy = remedy
        self.fixable = fixable
    }
}

public enum SettingsPathKind: String, Codable, Sendable, CaseIterable {
    case literal
    case environment
}

/// A path without a command language. Literal paths are absolute or home based.
/// Environment sources split one variable (or its fallback), then append a
/// relative suffix. Nothing invokes a shell, expands a glob, or substitutes `$`.
public struct SettingsPathSource: Codable, Sendable, Equatable {
    public var type: SettingsPathKind
    public var path: String?
    public var environment: String?
    public var fallback: String?
    public var suffix: String?
    public var separator: String?
    /// Scan-only safety metadata. A source declared as a shim is inventoried but
    /// never executed to discover a version, independently of manager detection.
    public var scanKind: ManagerScanRootKind?

    public init(literal path: String, scanKind: ManagerScanRootKind? = nil) {
        self.type = .literal
        self.path = path
        self.environment = nil
        self.fallback = nil
        self.suffix = nil
        self.separator = nil
        self.scanKind = scanKind
    }

    public init(environment: String, fallback: String, suffix: String = "",
                separator: String = ":", scanKind: ManagerScanRootKind? = nil) {
        self.type = .environment
        self.path = nil
        self.environment = environment
        self.fallback = fallback
        self.suffix = suffix
        self.separator = separator
        self.scanKind = scanKind
    }

    /// Resolve using only supplied inputs. Absolute entries are rooted beneath
    /// `systemRoot`, which is what keeps sealed scans out of the host filesystem.
    public func resolve(home: URL, systemRoot: URL,
                        environment values: [String: String]) throws -> [URL] {
        try validateShape()
        switch type {
        case .literal:
            return [try Self.resolve(path!, suffix: nil, home: home, systemRoot: systemRoot)]
        case .environment:
            let raw = values[environment!].flatMap { $0.isEmpty ? nil : $0 } ?? fallback!
            let pieces = raw.components(separatedBy: separator!)
            guard !pieces.isEmpty, pieces.allSatisfy({ !$0.isEmpty }) else {
                throw SettingsValidationError("environment path contains an empty entry")
            }
            return try pieces.map { entry in
                try Self.resolve(entry, suffix: suffix, home: home, systemRoot: systemRoot)
            }
        }
    }

    fileprivate func validateShape() throws {
        switch type {
        case .literal:
            guard let path else { throw SettingsValidationError("literal path has no path") }
            _ = try Self.pathForm(path)
            guard environment == nil, fallback == nil, suffix == nil, separator == nil else {
                throw SettingsValidationError("literal path has environment fields")
            }
        case .environment:
            guard path == nil else {
                throw SettingsValidationError("environment path also has a literal path")
            }
            guard let environment,
                  environment.range(of: #"^[A-Za-z_][A-Za-z0-9_]*$"#,
                                    options: .regularExpression) != nil else {
                throw SettingsValidationError("invalid environment variable name")
            }
            guard let fallback, let separator, separator.count == 1,
                  separator != "/", !separator.contains("\0") else {
                throw SettingsValidationError("environment path needs a one-character separator")
            }
            let pieces = fallback.components(separatedBy: separator)
            guard !pieces.isEmpty, pieces.allSatisfy({ !$0.isEmpty }) else {
                throw SettingsValidationError("fallback contains an empty path")
            }
            for piece in pieces { _ = try Self.pathForm(piece) }
            if let suffix, !suffix.isEmpty { try Self.validateRelative(suffix) }
        }
    }

    private enum Form { case absolute, home }

    private static func pathForm(_ path: String) throws -> Form {
        try rejectExpansion(path)
        guard !path.isEmpty else { throw SettingsValidationError("empty path") }
        let form: Form
        if path == "~" || path.hasPrefix("~/") { form = .home }
        else if path.hasPrefix("/") { form = .absolute }
        else { throw SettingsValidationError("path must be absolute or start with ~/") }
        let remainder: String
        switch form {
        case .home: remainder = String(path.dropFirst(path == "~" ? 1 : 2))
        case .absolute: remainder = String(path.dropFirst())
        }
        try validateComponents(remainder)
        return form
    }

    fileprivate static func validateRelative(_ path: String) throws {
        try rejectExpansion(path)
        guard !path.isEmpty, !path.hasPrefix("/"), path != "~", !path.hasPrefix("~/") else {
            throw SettingsValidationError("path suffix must be relative")
        }
        try validateComponents(path)
    }

    private static func validateComponents(_ path: String) throws {
        guard !path.split(separator: "/", omittingEmptySubsequences: false)
            .contains(where: { $0 == "." || $0 == ".." }) else {
            throw SettingsValidationError("path may not contain . or ..")
        }
    }

    private static func rejectExpansion(_ value: String) throws {
        let unsafe = CharacterSet(charactersIn: "$`*?[]{};|&<>()!\n\r\0")
        guard value.rangeOfCharacter(from: unsafe) == nil else {
            throw SettingsValidationError("path contains shell or glob syntax")
        }
    }

    private static func resolve(_ path: String, suffix: String?, home: URL,
                                systemRoot: URL) throws -> URL {
        let base: URL
        var candidate: URL
        switch try pathForm(path) {
        case .home:
            base = home
            candidate = path == "~"
                ? home
                : home.appending(path: String(path.dropFirst(2)))
        case .absolute:
            base = systemRoot
            candidate = path == "/"
                ? systemRoot
                : systemRoot.appending(path: String(path.dropFirst()))
        }
        if let suffix, !suffix.isEmpty { candidate.append(path: suffix) }

        // Standardisation alone is only lexical. Resolve every existing symlink
        // component even when the final descendant does not exist, then prove the
        // result remains under the runtime boundary before exposing it.
        let canonicalBase = try CanonicalPath.resolve(base)
        let canonical = try CanonicalPath.resolve(candidate)
        let basePath = canonicalBase.path
        let candidatePath = canonical.path
        let contained = basePath == "/"
            ? candidatePath.hasPrefix("/")
            : candidatePath == basePath || candidatePath.hasPrefix(basePath + "/")
        guard contained else {
            throw SettingsValidationError("resolved path escapes its runtime root")
        }
        return canonical
    }


}

public struct SettingsValidationError: Error, Sendable, Equatable, CustomStringConvertible {
    public var reason: String
    public init(_ reason: String) { self.reason = reason }
    public var description: String { reason }
}

public struct SettingsFailure: Error, Sendable, Equatable, CustomStringConvertible {
    public enum Source: String, Sendable { case bundled, user }
    public var source: Source
    public var path: String
    public var reason: String

    public init(source: Source, path: String, reason: String) {
        self.source = source
        self.path = path
        self.reason = reason
    }

    public var description: String { "\(source.rawValue) settings at \(path): \(reason)" }
}

/// `missing` means only the user file is absent; it still carries the decoded
/// bundled defaults that callers should use in memory.
public enum SettingsLoad: Sendable, Equatable {
    case missing(FoodTruckSettings)
    case loaded(FoodTruckSettings)
    case invalid(SettingsFailure)

    public var settings: FoodTruckSettings? {
        switch self {
        case .missing(let settings), .loaded(let settings): return settings
        case .invalid: return nil
        }
    }
}

public enum SettingsLoader {
    public static func load(_ locations: Locations) -> SettingsLoad {
        guard let bundledURL = locations.bundledSettings else {
            return .invalid(SettingsFailure(source: .bundled, path: "Cookbook/settings.json",
                                            reason: "bundled defaults are unavailable"))
        }
        let defaults: FoodTruckSettings
        do {
            let data = try Data(contentsOf: bundledURL)
            defaults = try JSONDecoder().decode(FoodTruckSettings.self, from: data)
            try validate(defaults)
        } catch {
            return .invalid(SettingsFailure(source: .bundled, path: bundledURL.path,
                                            reason: String(describing: error)))
        }

        guard FileManager.default.fileExists(atPath: locations.settings.path) else {
            return .missing(defaults)
        }
        do {
            let data = try Data(contentsOf: locations.settings)
            let overlay = try JSONDecoder().decode(SettingsOverlay.self, from: data)
            guard overlay.schema == FoodTruckSettings.currentSchema else {
                throw SettingsValidationError("unsupported schema \(overlay.schema)")
            }
            let merged = overlay.applying(to: defaults)
            try validate(merged)
            return .loaded(merged)
        } catch {
            return .invalid(SettingsFailure(source: .user, path: locations.settings.path,
                                            reason: String(describing: error)))
        }
    }

    fileprivate static func validate(_ settings: FoodTruckSettings) throws {
        guard settings.schema == FoodTruckSettings.currentSchema else {
            throw SettingsValidationError("unsupported schema \(settings.schema)")
        }
        for key in settings.vars.keys { try validateIdentifier(key) }
        var identifiers = Set<String>()
        for value in settings.inventory.probes.names
            + settings.inventory.managers.flatMap({ [$0.id] + $0.binaries + $0.manages }) {
            try validateIdentifier(value)
        }
        for manager in settings.inventory.managers {
            guard identifiers.insert(manager.id).inserted else {
                throw SettingsValidationError("duplicate manager \(manager.id)")
            }
            try manager.directories.forEach { try $0.validateShape() }
            try manager.scanRoots.forEach { try $0.source.validateShape() }
            try manager.roleEvidence.forEach { try $0.validateShape() }
        }
        try settings.inventory.scan.sources.forEach { try $0.validateShape() }
        try settings.inventory.scan.declarations.forEach { try $0.source.validateShape() }
        for root in settings.inventory.discovery.roots {
            try root.source.validateShape()
            for exclusion in root.exclusions {
                try validateDiscoveryChildName(exclusion)
            }
        }
        try settings.inventory.discovery.exclusions.forEach { try $0.validateShape() }
        try settings.inventory.gitCandidates.forEach { try $0.validateShape() }
        for rule in settings.inventory.origins {
            switch rule.match {
            case .contains:
                guard !rule.patterns.isEmpty, rule.paths.isEmpty, rule.requires.isEmpty else {
                    throw SettingsValidationError("contains origin rule has the wrong fields")
                }
                for pattern in rule.patterns {
                    guard pattern.hasPrefix("/"), !pattern.contains("..") else {
                        throw SettingsValidationError("unsafe origin pattern")
                    }
                }
            case .under:
                guard rule.patterns.isEmpty, !rule.paths.isEmpty else {
                    throw SettingsValidationError("under origin rule has the wrong fields")
                }
                try rule.paths.forEach { try $0.validateShape() }
                for marker in rule.requires { try SettingsPathSource.validateRelative(marker) }
            }
        }
        var reports: [InventoryReportID: ReportingDeclaration] = [:]
        for report in settings.inventory.reporting {
            try validateIdentifier(report.id)
            guard let id = InventoryReportID(rawValue: report.id) else {
                throw SettingsValidationError("unknown reporting declaration \(report.id)")
            }
            guard reports[id] == nil else {
                throw SettingsValidationError("duplicate reporting declaration \(report.id)")
            }
            guard report.cardinality == id.cardinality else {
                throw SettingsValidationError(
                    "reporting declaration \(report.id) must be \(id.cardinality.rawValue)")
            }
            guard !report.fixable else {
                throw SettingsValidationError(
                    "inventory reporting declaration \(report.id) cannot be fixable")
            }
            reports[id] = report
        }
        let missing = InventoryReportID.allCases.filter { reports[$0] == nil }
        guard missing.isEmpty else {
            throw SettingsValidationError(
                "missing reporting declarations \(missing.map(\.rawValue).joined(separator: ", "))")
        }
    }

    private static func validateDiscoveryChildName(_ value: String) throws {
        guard !value.contains("/"), !value.contains("\\") else {
            throw SettingsValidationError("discovery exclusion must be one child name")
        }
        try SettingsPathSource.validateRelative(value)
    }

    private static func validateIdentifier(_ value: String) throws {
        guard !value.isEmpty,
              value.range(of: #"^[A-Za-z0-9][A-Za-z0-9._:-]*$"#,
                          options: .regularExpression) != nil else {
            throw SettingsValidationError("unsafe identifier \(value)")
        }
    }
}

private struct SettingsOverlay: Decodable {
    var schema: String
    var vars: [String: String]?
    var inventory: InventoryOverlay?

    func applying(to defaults: FoodTruckSettings) -> FoodTruckSettings {
        var result = defaults
        if let vars { result.vars.merge(vars) { _, user in user } }
        if let inventory { result.inventory = inventory.applying(to: result.inventory) }
        return result
    }
}

private struct InventoryOverlay: Decodable {
    var scan: ScanOverlay?
    var discovery: DiscoveryOverlay?
    var probes: ProbeOverlay?
    var managers: [ManagerDeclaration]?
    var origins: [OriginRule]?
    var gitCandidates: [SettingsPathSource]?
    var reporting: [ReportingDeclaration]?

    func applying(to defaults: InventorySettings) -> InventorySettings {
        var result = defaults
        if let scan { result.scan = scan.applying(to: result.scan) }
        if let discovery { result.discovery = discovery.applying(to: result.discovery) }
        if let probes { result.probes = probes.applying(to: result.probes) }
        if let managers { result.managers = managers }
        if let origins { result.origins = origins }
        if let gitCandidates { result.gitCandidates = gitCandidates }
        if let reporting { result.reporting = reporting }
        return result
    }
}

private struct ScanOverlay: Decodable {
    var declarations: [PathDeclaration]?
    var sources: [SettingsPathSource]?

    func applying(to defaults: InventoryScanSettings) -> InventoryScanSettings {
        var result = defaults
        if let declarations { result.declarations = declarations }
        if let sources { result.sources = sources }
        return result
    }
}

private struct DiscoveryOverlay: Decodable {
    var roots: [SoftwareDiscoveryRoot]?
    var exclusions: [SettingsPathSource]?

    func applying(to defaults: InventoryDiscoverySettings) -> InventoryDiscoverySettings {
        var result = defaults
        if let roots { result.roots = roots }
        if let exclusions { result.exclusions = exclusions }
        return result
    }
}

private struct ProbeOverlay: Decodable {
    var names: [String]?

    func applying(to defaults: ProbeSettings) -> ProbeSettings {
        var result = defaults
        if let names { result.names = names }
        return result
    }
}

/// Immutable policy ready for one run. Runtime roots come from the caller's
/// sealed environment, never from user JSON, so settings cannot escape a test
/// or redirect a scan onto a different filesystem.
public struct SettingsProfile: Sendable, Equatable {
    public let schema: String
    public let vars: [String: String]
    public let inventory: ResolvedInventorySettings
    public let home: URL
    public let systemRoot: URL

    /// Resolve runtime context from the same environment a Kitchen run receives.
    /// `HOME` is required. `/` is used only when FOODTRUCK_SCAN_ROOT is absent;
    /// tests and other sealed callers should always provide that override.
    public init(settings: FoodTruckSettings, environment: [String: String]) throws {
        guard let homeValue = environment["HOME"], !homeValue.isEmpty,
              homeValue.hasPrefix("/") else {
            throw SettingsValidationError("runtime HOME must be an absolute path")
        }
        let rootValue = environment["FOODTRUCK_SCAN_ROOT"].flatMap { $0.isEmpty ? nil : $0 }
            ?? "/"
        guard rootValue.hasPrefix("/") else {
            throw SettingsValidationError("runtime system root must be an absolute path")
        }
        try self.init(settings: settings, home: URL(filePath: homeValue),
                      systemRoot: URL(filePath: rootValue), environment: environment)
    }

    /// Explicit-root form for callers that already own the runtime boundary.
    public init(settings: FoodTruckSettings, home: URL, systemRoot: URL,
                environment: [String: String]) throws {
        try SettingsLoader.validate(settings)
        guard home.path.hasPrefix("/"), systemRoot.path.hasPrefix("/") else {
            throw SettingsValidationError("runtime roots must be absolute")
        }
        self.schema = settings.schema
        self.vars = settings.vars
        self.home = home.standardizedFileURL
        self.systemRoot = systemRoot.standardizedFileURL
        self.inventory = try ResolvedInventorySettings(
            settings.inventory, home: self.home, systemRoot: self.systemRoot,
            environment: environment)
    }
}

public struct ResolvedInventorySettings: Sendable, Equatable {
    public let scanDeclarations: [ResolvedPathDeclaration]
    public let scanSources: [URL]
    /// Scan-source classification survives even when manager declarations are
    /// replaced, so removing manager reporting cannot make a shim executable.
    public let scanRoots: [ResolvedManagerScanRoot]
    public let discoveryRoots: [ResolvedSoftwareDiscoveryRoot]
    public let discoveryExclusions: [URL]
    public let probes: ProbeSettings
    public let managers: [ResolvedManagerDeclaration]
    public let origins: [ResolvedOriginRule]
    public let gitCandidates: [URL]
    /// Environment variables consulted by any configured inventory path source.
    /// They are inputs to path resolution, not credentials or runtime context
    /// that a program queried only for its version should inherit.
    public let pathSourceEnvironment: Set<String>
    public let reporting: [ReportingDeclaration]

    fileprivate init(_ settings: InventorySettings, home: URL, systemRoot: URL,
                     environment: [String: String]) throws {
        scanDeclarations = try settings.scan.declarations.flatMap { declaration in
            try declaration.source.resolve(home: home, systemRoot: systemRoot,
                                           environment: environment).map {
                ResolvedPathDeclaration(type: declaration.type, url: $0)
            }
        }
        scanRoots = try settings.scan.sources.flatMap { source in
            try source.resolve(home: home, systemRoot: systemRoot,
                               environment: environment).map {
                ResolvedManagerScanRoot(url: $0, kind: source.scanKind ?? .direct)
            }
        }
        scanSources = scanRoots.map(\.url)
        discoveryRoots = try settings.discovery.roots.flatMap { root in
            try root.source.resolve(home: home, systemRoot: systemRoot,
                                    environment: environment).map {
                ResolvedSoftwareDiscoveryRoot(
                    url: $0, strategy: root.strategy,
                    exclusions: Set(root.exclusions))
            }
        }
        discoveryExclusions = try settings.discovery.exclusions.flatMap {
            try $0.resolve(home: home, systemRoot: systemRoot, environment: environment)
        }
        probes = settings.probes
        managers = try settings.managers.map {
            try ResolvedManagerDeclaration($0, home: home, systemRoot: systemRoot,
                                           environment: environment)
        }
        origins = try settings.origins.map {
            try ResolvedOriginRule($0, home: home, systemRoot: systemRoot,
                                   environment: environment)
        }
        gitCandidates = try settings.gitCandidates.flatMap {
            try $0.resolve(home: home, systemRoot: systemRoot, environment: environment)
        }
        let pathSources = settings.scan.sources
            + settings.scan.declarations.map(\.source)
            + settings.discovery.roots.map(\.source)
            + settings.discovery.exclusions
            + settings.managers.flatMap { manager in
                manager.directories + manager.scanRoots.map(\.source) + manager.roleEvidence
            }
            + settings.origins.flatMap(\.paths)
            + settings.gitCandidates
        pathSourceEnvironment = Set(pathSources.compactMap { source in
            source.type == .environment ? source.environment : nil
        })
        reporting = settings.reporting
    }
}

public struct ResolvedSoftwareDiscoveryRoot: Sendable, Equatable {
    public let url: URL
    public let strategy: SoftwareDiscoveryStrategy
    public let exclusions: Set<String>

    public init(url: URL, strategy: SoftwareDiscoveryStrategy,
                exclusions: Set<String> = []) {
        self.url = url
        self.strategy = strategy
        self.exclusions = exclusions
    }
}

public struct ResolvedPathDeclaration: Sendable, Equatable {
    public let type: PathDeclarationKind
    public let url: URL
}

public struct ResolvedManagerScanRoot: Sendable, Equatable {
    public let url: URL
    public let kind: ManagerScanRootKind
}

public struct ResolvedManagerDeclaration: Sendable, Equatable, Identifiable {
    public let id: String
    public let binaries: [String]
    public let directories: [URL]
    public let manages: [String]
    public let scanRoots: [ResolvedManagerScanRoot]
    public let shellFunction: Bool
    public let roleEvidence: [URL]

    fileprivate init(_ declaration: ManagerDeclaration, home: URL, systemRoot: URL,
                     environment: [String: String]) throws {
        id = declaration.id
        binaries = declaration.binaries
        directories = try declaration.directories.flatMap {
            try $0.resolve(home: home, systemRoot: systemRoot, environment: environment)
        }
        manages = declaration.manages
        scanRoots = try declaration.scanRoots.flatMap { root in
            try root.source.resolve(home: home, systemRoot: systemRoot,
                                    environment: environment).map {
                ResolvedManagerScanRoot(url: $0, kind: root.kind)
            }
        }
        shellFunction = declaration.shellFunction
        roleEvidence = try declaration.roleEvidence.flatMap {
            try $0.resolve(home: home, systemRoot: systemRoot, environment: environment)
        }
    }
}

public struct ResolvedOriginRule: Sendable, Equatable {
    public let origin: Origin
    public let match: OriginMatch
    public let patterns: [String]
    public let paths: [URL]
    public let requires: [String]

    fileprivate init(_ rule: OriginRule, home: URL, systemRoot: URL,
                     environment: [String: String]) throws {
        origin = rule.origin
        match = rule.match
        patterns = rule.patterns
        paths = try rule.paths.flatMap {
            try $0.resolve(home: home, systemRoot: systemRoot, environment: environment)
        }
        requires = rule.requires
    }
}
