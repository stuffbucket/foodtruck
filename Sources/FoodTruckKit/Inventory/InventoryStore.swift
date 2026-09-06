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

    public init(root: URL) { self.root = root }

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

    /// The last recorded snapshot, or nil if there is none.
    /// Creates nothing -- this runs on the read-only path.
    public func load() -> Inventory? {
        guard let data = try? Data(contentsOf: recordURL) else { return nil }
        return try? JSONDecoder().decode(Inventory.self, from: data)
    }

    public func write(_ inventory: Inventory) throws {
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
        guard let git = Self.executable() else { return .unavailable }

        var env = environment
        // Hermetic. The user's global config may enable commit signing, a
        // template directory, or hooks -- all of which would either prompt or
        // fail inside what is supposed to be a silent bookkeeping write.
        env["GIT_CONFIG_GLOBAL"] = "/dev/null"
        env["GIT_CONFIG_SYSTEM"] = "/dev/null"
        env["GIT_TERMINAL_PROMPT"] = "0"

        func run(_ args: [String]) async -> ExecResult {
            await Exec.run(git, args, environment: env, workingDirectory: root, timeout: 30)
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

        let staged = await run(["add", "-A"])
        guard staged.status == 0 else {
            return .failed(staged.stderr.isEmpty ? staged.stdout : staged.stderr)
        }
        // Exit 0 means no staged difference: the machine is as it was, and a
        // commit here would be a heartbeat rather than a record.
        if await run(["diff", "--cached", "--quiet"]).status == 0 { return .unchanged }

        let committed = await run([
            "-c", "user.name=FoodTruck",
            "-c", "user.email=foodtruck@localhost",
            "-c", "commit.gpgsign=false",
            "commit", "-q", "-m", message,
        ])
        guard committed.status == 0 else {
            return .failed(committed.stderr.isEmpty ? committed.stdout : committed.stderr)
        }
        let head = await run(["rev-parse", "--short", "HEAD"])
        return .recorded(head.stdout.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// One line per recorded snapshot, newest first. Empty when there is no
    /// history to show, which is not an error.
    public func history(limit: Int, environment: [String: String]) async -> [String] {
        guard let git = Self.executable(),
              FileManager.default.fileExists(atPath: root.appending(path: ".git").path)
        else { return [] }
        var env = environment
        env["GIT_CONFIG_GLOBAL"] = "/dev/null"
        env["GIT_CONFIG_SYSTEM"] = "/dev/null"
        let log = await Exec.run(
            git, ["log", "--max-count=\(limit)", "--date=short",
                  "--format=%h  %ad  %s"],
            environment: env, workingDirectory: root, timeout: 30)
        guard log.status == 0 else { return [] }
        return log.stdout.split(separator: "\n").map(String.init)
    }

    /// A git we can actually run, or nil.
    ///
    /// `/usr/bin/git` is deliberately never used. On macOS it is not git: it is
    /// a stub that, on a machine without the Command Line Tools, opens a modal
    /// dialog offering a multi-gigabyte download. Invoking it to find out
    /// whether git exists would turn a silent bookkeeping step into an
    /// interruption the user did not ask for, so we establish the real thing is
    /// present by looking for it on disk instead of by asking the stub.
    public static func executable(
        systemRoot: URL = URL(filePath: "/")
    ) -> URL? {
        let candidates = [
            "opt/homebrew/bin/git",
            "usr/local/bin/git",
            "Library/Developer/CommandLineTools/usr/bin/git",
            "Applications/Xcode.app/Contents/Developer/usr/bin/git",
        ]
        for candidate in candidates {
            let url = systemRoot.appending(path: candidate)
            if FileManager.default.isExecutableFile(atPath: url.path) { return url }
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
        return lines.joined(separator: "\n") + "\n"
    }
}
