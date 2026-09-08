import Foundation

/// Compiled production limits. Tests can supply smaller internal values without
/// turning ceilings into user-configurable policy.
struct DiscoveryLimits: Sendable, Equatable {
    var roots = 64
    var entriesPerRoot = 4_096
    var artifacts = 8_192
    var metadataFileBytes = 1_048_576
    var metadataTotalBytes = 8_388_608

    static let standard = DiscoveryLimits()
}

/// A fixed safety boundary around declarative discovery. Settings choose among
/// shallow strategies and may remove more paths, but cannot widen these limits.
struct DiscoverySafetyGate {
    private let boundary: InventoryBoundary
    private let home: String?
    private let systemRoot: String?
    private let excluded: [String]?

    var isValid: Bool { home != nil && systemRoot != nil && excluded != nil }

    init(home: URL, systemRoot: URL, configuredExclusions: [URL]) {
        boundary = InventoryBoundary(home: home, systemRoot: systemRoot)
        self.home = try? CanonicalPath.resolve(home).path
        self.systemRoot = try? CanonicalPath.resolve(systemRoot).path

        let homeChildren = [
            ".ssh", ".gnupg", "Library", "Desktop", "Documents", "Downloads",
            "Movies", "Music",
        ].map { home.appending(path: $0) }
        let systemChildren = [
            "System/Volumes", "Volumes", "Network", "private/var",
        ].map { systemRoot.appending(path: $0) }
        let exclusions = configuredExclusions + homeChildren + systemChildren
        let resolved = exclusions.map { try? CanonicalPath.resolve($0).path }
        excluded = resolved.allSatisfy { $0 != nil }
            ? Set(resolved.compactMap { $0 }).sorted()
            : nil
    }

    func discoveryRoot(_ url: URL) -> URL? {
        guard let home, let systemRoot,
              let canonical = try? CanonicalPath.resolve(url) else { return nil }
        let path = canonical.path
        guard path != home, path != systemRoot, allowsCanonical(path) else { return nil }
        return canonical
    }

    func child(_ url: URL, of root: URL) -> URL? {
        guard let canonical = try? CanonicalPath.resolve(url),
              Inventory.isUnder(canonical.path, root: root.path),
              allowsCanonical(canonical.path) else { return nil }
        return canonical
    }

    func metadata(_ url: URL, under artifact: URL, root: URL) -> URL? {
        guard let canonical = try? CanonicalPath.resolve(url),
              Inventory.isUnder(canonical.path, root: artifact.path),
              Inventory.isUnder(canonical.path, root: root.path),
              allowsCanonical(canonical.path) else { return nil }
        return canonical
    }

    func allows(_ url: URL) -> Bool {
        guard let path = try? CanonicalPath.resolve(url).path else { return false }
        return allowsCanonical(path)
    }

    private func allowsCanonical(_ path: String) -> Bool {
        guard let excluded else { return false }
        return boundary.containsCanonical(path)
            && !excluded.contains(where: { Inventory.isUnder(path, root: $0) })
    }
}

private struct DiscoveryBudget {
    let limits: DiscoveryLimits
    var artifacts = 0
    var metadataBytes = 0
    var refused = false

    mutating func acceptEntries(_ count: Int, used: inout Int) -> Bool {
        guard count <= limits.entriesPerRoot - used else {
            refused = true
            return false
        }
        used += count
        return true
    }

    mutating func acceptArtifact() -> Bool {
        guard artifacts < limits.artifacts else {
            refused = true
            return false
        }
        artifacts += 1
        return true
    }

    mutating func acceptMetadata(bytes: Int, maxBytes: Int? = nil) -> Bool {
        guard bytes >= 0,
              maxBytes.map({ bytes <= $0 }) ?? true,
              bytes <= limits.metadataFileBytes,
              bytes <= limits.metadataTotalBytes - metadataBytes else {
            refused = true
            return false
        }
        metadataBytes += bytes
        return true
    }
}

private struct SoftwareDiscoveryResult {
    var artifacts: [SoftwareArtifact] = []
    var coverage: [SoftwareDiscoveryCoverage] = []
    var refused = false
}

extension Inventory {
    static func discoverSoftware(
        home: URL, settings: ResolvedInventorySettings, systemRoot: URL,
        limits: DiscoveryLimits = .standard
    ) -> (artifacts: [SoftwareArtifact], roots: [SoftwareDiscoveryCoverage], refused: Bool) {
        guard settings.discoveryRoots.count <= limits.roots else {
            return ([], [], true)
        }

        let gate = DiscoverySafetyGate(
            home: home, systemRoot: systemRoot,
            configuredExclusions: settings.discoveryExclusions)
        guard gate.isValid else { return ([], [], true) }
        let fm = FileManager.default
        guard let homePath = try? CanonicalPath.resolve(home).path else {
            return ([], [], true)
        }
        var budget = DiscoveryBudget(limits: limits)
        var result = SoftwareDiscoveryResult()
        var seenCoverage: Set<String> = []

        for configured in settings.discoveryRoots {
            guard let root = gate.discoveryRoot(configured.url) else {
                result.refused = true
                continue
            }
            var isDirectory: ObjCBool = false
            guard fm.fileExists(atPath: root.path, isDirectory: &isDirectory) else { continue }
            guard isDirectory.boolValue else {
                result.refused = true
                continue
            }

            var entriesUsed = 0
            guard let entries = directoryEntries(
                root, budget: &budget, entriesUsed: &entriesUsed) else {
                result.refused = true
                continue
            }
            let discovered: [SoftwareArtifact]?
            switch configured.strategy {
            case .homebrewCellar:
                guard provesHomebrew(root: root, gate: gate) else { continue }
                discovered = discoverCellar(
                    root: root, entries: entries, excluded: configured.exclusions,
                    home: homePath, gate: gate, budget: &budget,
                    entriesUsed: &entriesUsed)
            case .homebrewCaskroom:
                guard provesHomebrew(root: root, gate: gate) else { continue }
                discovered = discoverCaskroom(
                    root: root, entries: entries, excluded: configured.exclusions,
                    home: homePath, gate: gate, budget: &budget,
                    entriesUsed: &entriesUsed)
            case .applicationBundles:
                discovered = discoverApplications(
                    root: root, entries: entries, excluded: configured.exclusions,
                    home: homePath, gate: gate, budget: &budget)
            case .topLevelFootprints:
                discovered = discoverFootprints(
                    root: root, entries: entries, excluded: configured.exclusions,
                    home: homePath, gate: gate, budget: &budget)
            }
            guard let discovered, !budget.refused else {
                result.refused = true
                continue
            }

            let coverage = SoftwareDiscoveryCoverage(
                path: abbreviate(root.path, home: homePath),
                strategy: configured.strategy)
            if seenCoverage.insert(coverage.id).inserted { result.coverage.append(coverage) }
            result.artifacts += discovered
        }

        if result.refused {
            return ([], [], true)
        }
        let unique = Dictionary(
            result.artifacts.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first })
        let artifacts = unique.values.sorted {
            ($0.kind.rawValue, $0.path) < ($1.kind.rawValue, $1.path)
        }
        let roots = result.coverage.sorted {
            ($0.strategy.rawValue, $0.path) < ($1.strategy.rawValue, $1.path)
        }
        return (artifacts, roots, false)
    }

    private static func directoryEntries(
        _ directory: URL, budget: inout DiscoveryBudget, entriesUsed: inout Int
    ) -> [URL]? {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil,
            options: []) else { return nil }
        let sorted = entries.sorted { $0.lastPathComponent < $1.lastPathComponent }
        guard budget.acceptEntries(sorted.count, used: &entriesUsed) else { return nil }
        return sorted
    }

    private static func directory(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
            && isDirectory.boolValue
    }

    private static func regularFile(_ url: URL) -> Bool {
        guard !symbolicLink(url),
              let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        else { return false }
        return (attributes[.type] as? FileAttributeType) == .typeRegular
    }

    private static func symbolicLink(_ url: URL) -> Bool {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        else { return false }
        return (attributes[.type] as? FileAttributeType) == .typeSymbolicLink
    }

    private static func provesHomebrew(root: URL, gate: DiscoverySafetyGate) -> Bool {
        let prefix = root.deletingLastPathComponent()
        let marker = prefix.appending(path: "Library/Homebrew")
        return gate.allows(marker) && directory(marker)
    }

    private static func discoverCellar(
        root: URL, entries: [URL], excluded: Set<String>, home: String,
        gate: DiscoverySafetyGate, budget: inout DiscoveryBudget,
        entriesUsed: inout Int
    ) -> [SoftwareArtifact]? {
        var artifacts: [SoftwareArtifact] = []
        for entry in entries where !excluded.contains(entry.lastPathComponent) {
            guard !symbolicLink(entry),
                  let formula = gate.child(entry, of: root), directory(formula) else { continue }
            guard let versions = directoryEntries(
                formula, budget: &budget, entriesUsed: &entriesUsed) else { return nil }
            var accepted: [String] = []
            for versionEntry in versions {
                guard !symbolicLink(versionEntry),
                      let version = gate.child(versionEntry, of: root),
                      directory(version) else { continue }
                let receiptEntry = version.appending(path: "INSTALL_RECEIPT.json")
                let formulaFileEntry = version.appending(
                    path: ".brew/\(formula.lastPathComponent).rb")
                guard !symbolicLink(receiptEntry), !symbolicLink(formulaFileEntry),
                      let receipt = gate.metadata(
                        receiptEntry, under: version, root: root),
                      regularFile(receipt),
                      let receiptData = readJSONDictionary(
                        receipt, budget: &budget, maxBytes: 65_536),
                      acceptedFormulaVersion(
                        version.lastPathComponent, receipt: receiptData),
                      let formulaFile = gate.metadata(
                        formulaFileEntry, under: version, root: root),
                      regularFile(formulaFile) else { continue }
                accepted.append(version.lastPathComponent)
            }
            guard !accepted.isEmpty, budget.acceptArtifact() else {
                if accepted.isEmpty { continue }
                return nil
            }
            artifacts.append(SoftwareArtifact(
                kind: .formula, name: formula.lastPathComponent,
                path: abbreviate(formula.path, home: home),
                versions: Array(Set(accepted)).sorted(), provider: .homebrew,
                evidence: .homebrewReceipt))
        }
        return artifacts
    }

    private static func discoverCaskroom(
        root: URL, entries: [URL], excluded: Set<String>, home: String,
        gate: DiscoverySafetyGate, budget: inout DiscoveryBudget,
        entriesUsed: inout Int
    ) -> [SoftwareArtifact]? {
        var artifacts: [SoftwareArtifact] = []
        for entry in entries where entry.lastPathComponent != ".metadata"
            && !excluded.contains(entry.lastPathComponent) {
            guard !symbolicLink(entry),
                  let token = gate.child(entry, of: root), directory(token) else { continue }
            guard let versions = directoryEntries(
                token, budget: &budget, entriesUsed: &entriesUsed) else { return nil }
            var accepted: [String] = []
            for versionEntry in versions where versionEntry.lastPathComponent != ".metadata" {
                guard !symbolicLink(versionEntry),
                      let version = gate.child(versionEntry, of: root),
                      directory(version) else { continue }
                let metadataEntry = version.appending(path: ".metadata")
                let receiptEntry = metadataEntry.appending(path: "INSTALL_RECEIPT.json")
                let versionMetadataEntry = metadataEntry.appending(path: version.lastPathComponent)
                guard !symbolicLink(metadataEntry), !symbolicLink(receiptEntry),
                      !symbolicLink(versionMetadataEntry),
                      let metadata = gate.metadata(
                        metadataEntry, under: version, root: root),
                      directory(metadata),
                      let receipt = gate.metadata(
                        receiptEntry, under: version, root: root),
                      regularFile(receipt),
                      let dictionary = readJSONDictionary(
                        receipt, budget: &budget, maxBytes: 65_536),
                      let source = dictionary["source"] as? [String: Any],
                      string(source["version"]) == version.lastPathComponent,
                      let versionMetadata = gate.metadata(
                        versionMetadataEntry, under: version, root: root),
                      directory(versionMetadata) else { continue }
                accepted.append(version.lastPathComponent)
            }
            guard !accepted.isEmpty, budget.acceptArtifact() else {
                if accepted.isEmpty { continue }
                return nil
            }
            artifacts.append(SoftwareArtifact(
                kind: .cask, name: token.lastPathComponent,
                path: abbreviate(token.path, home: home),
                versions: Array(Set(accepted)).sorted(), provider: .homebrew,
                evidence: .homebrewCaskMetadata))
        }
        return artifacts
    }

    private static func discoverApplications(
        root: URL, entries: [URL], excluded: Set<String>, home: String,
        gate: DiscoverySafetyGate, budget: inout DiscoveryBudget
    ) -> [SoftwareArtifact]? {
        var artifacts: [SoftwareArtifact] = []
        for entry in entries {
            let filename = entry.lastPathComponent
            guard filename.lowercased().hasSuffix(".app"),
                  !excluded.contains(filename), !symbolicLink(entry),
                  let bundle = gate.child(entry, of: root), directory(bundle) else { continue }
            let plistEntry = bundle.appending(path: "Contents/Info.plist")
            guard !symbolicLink(plistEntry),
                  let plist = gate.metadata(plistEntry, under: bundle, root: root),
                  let info = readPlistDictionary(plist, budget: &budget) else { continue }
            let fallback = String(filename.dropLast(4))
            let name = string(info["CFBundleDisplayName"])
                ?? string(info["CFBundleName"]) ?? fallback
            let identifier = string(info["CFBundleIdentifier"])
            let versions = [
                string(info["CFBundleShortVersionString"]),
                string(info["CFBundleVersion"]),
            ].compactMap { $0 }
            guard budget.acceptArtifact() else { return nil }
            artifacts.append(SoftwareArtifact(
                kind: .application, name: name,
                path: abbreviate(bundle.path, home: home), identifier: identifier,
                versions: Array(Set(versions)).sorted(),
                evidence: .bundleInfoPlist))
        }
        return artifacts
    }

    private static func discoverFootprints(
        root: URL, entries: [URL], excluded: Set<String>, home: String,
        gate: DiscoverySafetyGate, budget: inout DiscoveryBudget
    ) -> [SoftwareArtifact]? {
        var artifacts: [SoftwareArtifact] = []
        for entry in entries where !excluded.contains(entry.lastPathComponent) {
            guard !symbolicLink(entry),
                  let footprint = gate.child(entry, of: root), directory(footprint) else { continue }
            guard budget.acceptArtifact() else { return nil }
            artifacts.append(SoftwareArtifact(
                kind: .footprint, name: footprint.lastPathComponent,
                path: abbreviate(footprint.path, home: home),
                evidence: .directoryEntry))
        }
        return artifacts
    }

    private static func acceptedFormulaVersion(
        _ directoryVersion: String, receipt: [String: Any]
    ) -> Bool {
        guard !directoryVersion.isEmpty,
              let source = receipt["source"] as? [String: Any],
              string(source["spec"]) == "stable",
              let versions = source["versions"] as? [String: Any],
              let stable = string(versions["stable"]) else { return false }
        if directoryVersion == stable { return true }
        guard directoryVersion.hasPrefix(stable + "_") else { return false }
        let revision = directoryVersion.dropFirst(stable.count + 1)
        return !revision.isEmpty && revision.allSatisfy(\.isNumber)
    }

    private static func readData(
        _ url: URL, budget: inout DiscoveryBudget,
        maxBytes: Int? = nil
    ) -> Data? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = (attributes[.size] as? NSNumber)?.intValue,
              budget.acceptMetadata(bytes: size, maxBytes: maxBytes),
              let data = try? Data(contentsOf: url, options: [.mappedIfSafe]),
              data.count == size else { return nil }
        return data
    }

    private static func readJSONDictionary(
        _ url: URL, budget: inout DiscoveryBudget,
        maxBytes: Int? = nil
    ) -> [String: Any]? {
        guard let data = readData(url, budget: &budget, maxBytes: maxBytes),
              let value = try? JSONSerialization.jsonObject(with: data),
              let dictionary = value as? [String: Any] else { return nil }
        return dictionary
    }

    private static func readPlistDictionary(
        _ url: URL, budget: inout DiscoveryBudget
    ) -> [String: Any]? {
        guard let data = readData(url, budget: &budget),
              let value = try? PropertyListSerialization.propertyList(
                from: data, options: [], format: nil),
              let dictionary = value as? [String: Any] else { return nil }
        return dictionary
    }

    private static func string(_ value: Any?) -> String? {
        guard let value = value as? String, !value.isEmpty else { return nil }
        return value
    }
}
