import Foundation

/// One environment manager found on this machine.
public struct Manager: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    /// What proved it is here -- the binary found, or the directory that exists.
    public var evidence: String
    /// Its own version. Managers move fast and a stale one is its own problem,
    /// so this is asked for directly rather than inferred.
    public var version: String?
    /// Identity of the executable that supplied `version`. Optional so snapshots
    /// written before manager probe caching remain readable and are re-probed.
    public var stamp: String?
    public var manages: [String]
    public var shellFunction: Bool

    public init(id: String, evidence: String, version: String? = nil,
                stamp: String? = nil, manages: [String], shellFunction: Bool = false) {
        self.id = id
        self.evidence = evidence
        self.version = version
        self.stamp = stamp
        self.manages = manages
        self.shellFunction = shellFunction
    }
}

extension Inventory {

    /// Which declared managers are on this machine. Reads directories and looks
    /// at the programs already found; runs nothing.
    func detectedManagers(home: URL, settings: ResolvedInventorySettings,
                          systemRoot: URL) -> [Manager] {
        let fm = FileManager.default
        let homePath = (try? CanonicalPath.resolve(home).path)
            ?? home.standardizedFileURL.path
        let boundary = InventoryBoundary(home: home, systemRoot: systemRoot)
        var found: [Manager] = []

        func existingDirectory(_ url: URL) -> URL? {
            var isDirectory: ObjCBool = false
            guard let canonical = try? CanonicalPath.resolve(url),
                  boundary.containsCanonical(canonical.path),
                  fm.fileExists(atPath: canonical.path, isDirectory: &isDirectory),
                  isDirectory.boolValue else { return nil }
            return canonical
        }

        // Indexed once. Directory-only managers never enter this lookup.
        let wanted = Set(settings.managers.flatMap(\.binaries))
        var byName: [String: [Installed]] = [:]
        for tool in environmentTools where wanted.contains(tool.name) {
            byName[tool.name, default: []].append(tool)
        }

        for declaration in settings.managers {
            // A tool whose managing role is optional does not count until there
            // is evidence that role is in use.
            if !declaration.roleEvidence.isEmpty,
               !declaration.roleEvidence.contains(where: {
                   existingDirectory($0) != nil
               }) {
                continue
            }

            // When several copies exist, quote the first one in scan order.
            var evidence = inSearchOrder(
                declaration.binaries.flatMap { byName[$0] ?? [] }
            ).first?.path

            // A directory is the only evidence available for shell functions and
            // managers that are installed without putting a binary on PATH.
            if evidence == nil,
               let directory = declaration.directories.lazy.compactMap(existingDirectory).first {
                evidence = Self.abbreviate(directory.path, home: homePath)
            }

            guard let evidence else { continue }
            found.append(Manager(
                id: declaration.id,
                evidence: evidence,
                manages: declaration.manages,
                shellFunction: declaration.shellFunction))
        }
        return found.sorted { $0.id < $1.id }
    }
}
