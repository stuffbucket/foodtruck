import Foundation

/// A tool whose job is installing other tools.
///
/// This category needs its own handling for three reasons the rest of the
/// inventory cannot cover.
///
/// One: several of them are not programs. `nvm` is a shell function sourced
/// from `~/.nvm/nvm.sh`, and `sdkman` likewise. Nothing on `PATH` names them,
/// so a scan that only walks directories of executables concludes they are not
/// installed -- while they are, in fact, deciding which `node` you get.
///
/// Two: the tools they install do not carry a version anyone can read. A shim
/// resolves per directory, and running it to find out installs a toolchain (see
/// `Inventory.shouldProbe`). Only the manager knows, and each one has to be
/// asked in its own language -- which is a recipe's job, not the core's.
///
/// Three, and the one that actually bites people: two of them can want the same
/// runtime. mise and pyenv and conda and uv all install Python; whichever gets
/// on `PATH` first wins, silently, and the loser's version is what you thought
/// you were running. That overlap is knowable *before* anything is run, because
/// what each manager is capable of managing is a fact about the tool rather
/// than about this machine -- which is why `manages` below is declared here
/// rather than discovered by interrogating anything.
public struct ManagerSpec: Sendable {
    public let id: String
    /// Command names that are this manager, when it is a program at all.
    public let binaries: [String]
    /// Paths proving it is installed even when nothing is on `PATH`.
    /// A leading `~` is expanded against the home directory being scanned.
    public let directories: [String]
    /// Runtimes it is capable of managing.
    public let manages: [String]
    /// Not an executable. There is no binary to ask for a version, and that is
    /// a fact about the tool, not a gap in the scan.
    public let shellFunction: Bool
    /// Paths that must exist before this counts as a manager at all.
    ///
    /// For tools whose managing role is optional. `pnpm` can install Node with
    /// `pnpm env use`, but almost nobody does; treating every machine with
    /// pnpm on it as having a second Node manager announces a conflict that is
    /// not happening. Empty means presence is enough.
    public let roleEvidence: [String]

    public init(_ id: String, binaries: [String] = [], directories: [String] = [],
                manages: [String], shellFunction: Bool = false,
                roleEvidence: [String] = []) {
        self.id = id; self.binaries = binaries; self.directories = directories
        self.manages = manages; self.shellFunction = shellFunction
        self.roleEvidence = roleEvidence
    }
}

/// One environment manager found on this machine.
public struct Manager: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    /// What proved it is here -- the binary found, or the directory that exists.
    public var evidence: String
    /// Its own version. Managers move fast and a stale one is its own problem,
    /// so this is asked for directly rather than inferred.
    public var version: String?
    public var manages: [String]
    public var shellFunction: Bool

    public init(id: String, evidence: String, version: String? = nil,
                manages: [String], shellFunction: Bool = false) {
        self.id = id; self.evidence = evidence; self.version = version
        self.manages = manages; self.shellFunction = shellFunction
    }
}

extension Inventory {

    /// The managers FoodTruck knows to look for.
    ///
    /// A catalogue, not a heuristic, and deliberately readable as a table: the
    /// only way to be wrong about `nvm` is to leave the row out, which is
    /// visible, rather than to have a rule that quietly fails to match.
    ///
    /// Presence here says nothing about whether a machine should have the tool.
    /// It is a list of things to look for, not a list of things to want.
    public static let managerCatalogue: [ManagerSpec] = {
        // The full set an "install any runtime" manager claims. Shared so that
        // adding a runtime to one does not silently skip its rivals.
        let everything = ["node", "python", "ruby", "go", "java", "rust",
                          "erlang", "elixir", "php", "deno", "bun"]
        return [
            ManagerSpec("mise", binaries: ["mise"],
                        directories: ["~/.local/share/mise", "~/.config/mise"],
                        manages: everything),
            ManagerSpec("asdf", binaries: ["asdf"], directories: ["~/.asdf"],
                        manages: everything),
            ManagerSpec("nix", binaries: ["nix"], directories: ["/nix"],
                        manages: everything),
            // Single-runtime managers. These are the ones that actually collide
            // with the general-purpose managers above.
            ManagerSpec("pyenv", binaries: ["pyenv"], directories: ["~/.pyenv"],
                        manages: ["python"]),
            ManagerSpec("conda", binaries: ["conda"],
                        directories: ["~/miniconda3", "~/anaconda3", "~/miniforge3",
                                      "~/mambaforge", "/opt/homebrew/Caskroom/miniconda"],
                        manages: ["python"]),
            ManagerSpec("uv", binaries: ["uv"], manages: ["python"]),
            ManagerSpec("rbenv", binaries: ["rbenv"], directories: ["~/.rbenv"],
                        manages: ["ruby"]),
            ManagerSpec("nodenv", binaries: ["nodenv"], directories: ["~/.nodenv"],
                        manages: ["node"]),
            ManagerSpec("fnm", binaries: ["fnm"], directories: ["~/.fnm"],
                        manages: ["node"]),
            ManagerSpec("volta", binaries: ["volta"], directories: ["~/.volta"],
                        manages: ["node"]),
            // pnpm only manages Node once someone has run `pnpm env use`, which
            // puts it under PNPM_HOME. Without that directory it is a package
            // manager that happens to be installed, not a rival to mise.
            ManagerSpec("pnpm", binaries: ["pnpm"], manages: ["node"],
                        roleEvidence: ["~/Library/pnpm/nodejs",
                                       "~/.local/share/pnpm/nodejs"]),
            ManagerSpec("goenv", binaries: ["goenv"], directories: ["~/.goenv"],
                        manages: ["go"]),
            ManagerSpec("jenv", binaries: ["jenv"], directories: ["~/.jenv"],
                        manages: ["java"]),
            ManagerSpec("rustup", binaries: ["rustup"], directories: ["~/.rustup"],
                        manages: ["rust"]),
            // Shell functions. Invisible to any PATH-based scan, which is
            // exactly why they are listed by directory instead.
            ManagerSpec("nvm", directories: ["~/.nvm"], manages: ["node"],
                        shellFunction: true),
            ManagerSpec("sdkman", directories: ["~/.sdkman"], manages: ["java"],
                        shellFunction: true),
        ]
    }()

    /// Which managers are on this machine. Reads directories and looks at the
    /// programs already found; runs nothing.
    func detectedManagers(home: URL, systemRoot: URL) -> [Manager] {
        let fm = FileManager.default
        let homePath = home.standardizedFileURL.path
        var found: [Manager] = []

        func exists(_ path: String) -> URL? {
            let url = path.hasPrefix("~/")
                ? home.appending(path: String(path.dropFirst(2)))
                : systemRoot.appending(path: String(path.dropFirst()))
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue
            else { return nil }
            return url
        }

        // Indexed once. Filtering every tool per spec walks the whole list
        // sixteen times -- twice for nvm and sdkman, which declare no binary at
        // all and so can never match.
        let wanted = Set(Self.managerCatalogue.flatMap(\.binaries))
        var byName: [String: [Installed]] = [:]
        for tool in tools where wanted.contains(tool.name) {
            byName[tool.name, default: []].append(tool)
        }

        for spec in Self.managerCatalogue {
            // A tool whose managing role is optional does not count until
            // there is evidence it is being used for it.
            if !spec.roleEvidence.isEmpty,
               !spec.roleEvidence.contains(where: { exists($0) != nil }) { continue }

            // A binary already picked up by the scan. Where there are several
            // -- a `mise` from Homebrew and a `mise` from its own installer is
            // the ordinary case, not an exotic one -- the earliest search root
            // wins, so the version reported for a manager belongs to a copy
            // that can be named. That there is more than one is a separate
            // finding; this only decides which one is quoted.
            var evidence = inSearchOrder(spec.binaries.flatMap { byName[$0] ?? [] }).first?.path
            // Otherwise a directory. This is the only way nvm, sdkman, and a
            // conda that is not on PATH are visible at all.
            if evidence == nil {
                for directory in spec.directories {
                    if let url = exists(directory) {
                        evidence = Self.abbreviate(url.path, home: homePath)
                        break
                    }
                }
            }

            guard let evidence else { continue }
            found.append(Manager(id: spec.id, evidence: evidence,
                                 manages: spec.manages, shellFunction: spec.shellFunction))
        }
        return found.sorted { $0.id < $1.id }
    }
}
