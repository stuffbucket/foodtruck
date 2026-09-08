import Foundation

public struct ExecResult: Sendable {
    public var status: Int32
    public var stdout: String
    public var stderr: String
    public var timedOut: Bool
    public var duration: Double
}

/// Runs subprocesses with an environment we constructed, never one we inherited.
///
/// A GUI app launched from Finder does not get the user's shell rc, so a tool
/// that works in Terminal and fails when double-clicked is the classic bug in
/// this category. FoodTruck's answer is to never rely on ambient PATH at all:
/// the environment handed to every recipe is built here, explicitly, from the
/// same `Locations` a test can relocate. What works in the app works in the CLI
/// works in the test, because there is only one environment builder.
public enum Exec {
    /// The floor every recipe gets. Deliberately small.
    ///
    /// `PATH` puts FoodTruck's own toolbox first so an unlocked `task` wins over
    /// a stale system copy, then the standard system directories. Homebrew's
    /// prefix is *not* here by default -- a recipe that needs brew declares it
    /// via `requires`, which is the entire point of the tech tree.
    public static func baseEnvironment(
        _ loc: Locations,
        inherit: [String: String] = ProcessInfo.processInfo.environment,
        extra: [String: String] = [:]
    ) -> [String: String] {
        var env: [String: String] = [
            "PATH": "\(loc.toolbox.path):/usr/bin:/bin:/usr/sbin:/sbin",
            "HOME": inherit["HOME"] ?? NSHomeDirectory(),
            "LANG": inherit["LANG"] ?? "en_US.UTF-8",
            "TMPDIR": inherit["TMPDIR"] ?? "/tmp",
            // Recipes read these instead of guessing. A recipe that hard-codes
            // ~/.config is a bug we can catch in review.
            "FOODTRUCK_CONFIG_DIR": loc.config.path,
            "FOODTRUCK_DATA_DIR": loc.data.path,
            "FOODTRUCK_STATE_DIR": loc.state.path,
            "FOODTRUCK_CACHE_DIR": loc.cache.path,
            "FOODTRUCK_TOOLBOX": loc.toolbox.path,
            // Anything reading XDG directly lands in the same sandbox.
            "XDG_CONFIG_HOME": loc.config.deletingLastPathComponent().path,
            "XDG_DATA_HOME": loc.data.deletingLastPathComponent().path,
            "XDG_STATE_HOME": loc.state.deletingLastPathComponent().path,
            "XDG_CACHE_HOME": loc.cache.deletingLastPathComponent().path,
            // Non-interactive by construction: nothing we run may block on a
            // TTY prompt, because there may not be a TTY.
            "CI": "1",
            "NONINTERACTIVE": "1",
            "TERM": "dumb",
        ]
        for (k, v) in extra { env[k] = v }
        return env
    }

    /// Run a command with a hard deadline. Never uses a shell unless the caller
    /// explicitly passes one as `executable`.
    public static func run(
        _ executable: URL,
        _ arguments: [String],
        environment: [String: String],
        workingDirectory: URL? = nil,
        stdin: String? = nil,
        timeout: Double = 120
    ) async -> ExecResult {
        let started = Date()
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.environment = environment
        if let workingDirectory { process.currentDirectoryURL = workingDirectory }

        let outPipe = Pipe(), errPipe = Pipe(), inPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        process.standardInput = inPipe

        // Drain both pipes concurrently and *before* waiting. A 64KB write into
        // a full pipe deadlocks the child forever, and "it hangs sometimes on
        // big output" is exactly the un-debuggable failure we refuse to ship.
        let outBox = Box(), errBox = Box()
        outPipe.fileHandleForReading.readabilityHandler = { outBox.append($0.availableData) }
        errPipe.fileHandleForReading.readabilityHandler = { errBox.append($0.availableData) }

        do {
            try process.run()
        } catch {
            return ExecResult(
                status: 127, stdout: "",
                stderr: "\(executable.path): \(error.localizedDescription)",
                timedOut: false, duration: 0
            )
        }

        if let stdin, let data = stdin.data(using: .utf8) {
            try? inPipe.fileHandleForWriting.write(contentsOf: data)
        }
        try? inPipe.fileHandleForWriting.close()

        let didTimeOut = Box()
        let deadline = Task {
            try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            if process.isRunning {
                didTimeOut.flag = true
                // SIGTERM first so a well-behaved recipe can clean up, then
                // SIGKILL: a stuck child must never outlive the run.
                process.terminate()
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            }
        }

        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            process.terminationHandler = { _ in c.resume() }
        }
        deadline.cancel()

        outPipe.fileHandleForReading.readabilityHandler = nil
        errPipe.fileHandleForReading.readabilityHandler = nil
        outBox.append(try? outPipe.fileHandleForReading.readToEnd())
        errBox.append(try? errPipe.fileHandleForReading.readToEnd())

        return ExecResult(
            status: process.terminationStatus,
            stdout: outBox.string,
            stderr: errBox.string,
            timedOut: didTimeOut.flag,
            duration: Date().timeIntervalSince(started)
        )
    }

    /// Locate an executable using only the PATH we constructed, never the
    /// caller's. Returns nil rather than guessing.
    public static func which(_ name: String, environment: [String: String]) -> URL? {
        guard !name.contains("/") else {
            let u = URL(filePath: name)
            return FileManager.default.isExecutableFile(atPath: u.path) ? u : nil
        }
        for dir in (environment["PATH"] ?? "").split(separator: ":") {
            let u = URL(filePath: String(dir)).appending(path: name)
            if FileManager.default.isExecutableFile(atPath: u.path) { return u }
        }
        return nil
    }
}

/// Minimal thread-safe accumulator for pipe drains. Not public API.
private final class Box: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    var flag = false
    func append(_ d: Data?) {
        guard let d, !d.isEmpty else { return }
        lock.lock(); data.append(d); lock.unlock()
    }
    var string: String {
        lock.lock(); defer { lock.unlock() }
        return String(decoding: data, as: UTF8.self)
    }
}
