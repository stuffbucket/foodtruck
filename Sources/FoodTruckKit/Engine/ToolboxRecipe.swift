import Foundation
import CryptoKit

/// One pinned artifact FoodTruck installs for its own use.
public struct PinnedArtifact: Codable, Sendable, Identifiable, Equatable {
    public var id: String
    public var version: String
    public var url: URL
    public var sha256: String
    /// Path to the executable inside the unpacked archive.
    public var binary: String
    public var provides: String
    public var provenance: String
    /// Command that re-derives `sha256` from upstream, for `lint pins`.
    public var verify: String
}

public struct PinManifest: Codable, Sendable {
    public var schema: String
    public var artifacts: [PinnedArtifact]

    /// Read from the signed bundle, never from the writable pantry.
    ///
    /// A user is encouraged to fork a recipe -- that is what the pantry is for.
    /// They must not thereby be able to repoint a download at another host, so
    /// the file that says *what to fetch and what digest to demand* lives where
    /// nothing but a new signed release can change it.
    public static func load(_ locations: Locations) -> PinManifest? {
        guard let seed = locations.seed else { return nil }
        let url = seed.deletingLastPathComponent().appending(path: "pins.json")
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(PinManifest.self, from: data)
    }
}

/// Installs and keeps honest every pinned binary FoodTruck runs.
///
/// This is the root of the tech tree, and it is one recipe rather than one per
/// tool on purpose: the fetch-verify-unpack-install dance is identical every
/// time, and reimplementing it in each recipe's shell would mean reimplementing
/// the checksum check too. Recipes get to be about their tool; the one piece of
/// code that touches the network on FoodTruck's own behalf lives here, in Swift,
/// where it is testable.
struct ToolboxRecipe: BuiltinRecipe {
    var descriptor: Recipe {
        Recipe(
            id: "core.toolbox",
            name: "recipe.core.toolbox.name",
            summary: "recipe.core.toolbox.summary",
            engine: "builtin",
            requires: ["core.locations"],
            // Deliberately generic. What the toolbox actually provides is
            // whatever pins.json lists, and naming those tools here would put
            // tool knowledge back into the code the moment someone edits the
            // manifest without editing this line.
            provides: ["toolbox"],
            verbs: [.detect, .audit, .plan, .converge, .verify],
            blast: .contained,
            timeout: 180,
            symbol: "wrench.and.screwdriver"
        )
    }

    func audit(_ context: RunContext) async -> RecipeReport {
        var report = RecipeReport()
        guard let manifest = PinManifest.load(context.locations) else {
            report.findings.append(Finding(
                id: "toolbox.nopins", severity: .risk, title: "finding.pins.missing",
                fixable: false, remedy: "fault.recipeMissing.remedy"))
            return report
        }
        for pin in manifest.artifacts {
            let installed = context.locations.toolbox.appending(path: pin.id)
            guard FileManager.default.isExecutableFile(atPath: installed.path) else {
                report.findings.append(Finding(
                    id: "toolbox.absent:\(pin.id)", severity: .drift,
                    title: "finding.tool.absent", args: ["tool": pin.id],
                    observed: "absent", desired: pin.version))
                continue
            }
            let version = await Exec.run(installed, ["--version"],
                                         environment: context.environment, timeout: 10)
            let observed = version.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            report.facts[pin.id] = pin.version
            if !observed.contains(pin.version) {
                report.findings.append(Finding(
                    id: "toolbox.stale:\(pin.id)", severity: .drift,
                    title: "finding.tool.stale",
                    args: ["tool": pin.id, "observed": observed.isEmpty ? "?" : observed,
                           "desired": pin.version],
                    observed: observed, desired: pin.version))
            }
        }
        return report
    }

    func converge(_ context: RunContext) async -> Result<RecipeReport, RecipeFault> {
        guard let manifest = PinManifest.load(context.locations) else {
            return .failure(RecipeFault(kind: .recipeMissing, recipe: descriptor.id,
                                        verb: .converge, args: ["recipe": descriptor.id]))
        }
        // Independent downloads, so they run at once rather than in a queue.
        let faults = await withTaskGroup(of: RecipeFault?.self) { group in
            for pin in manifest.artifacts {
                group.addTask { await install(pin, context) }
            }
            var acc: [RecipeFault] = []
            for await f in group { if let f { acc.append(f) } }
            return acc
        }
        if let first = faults.first { return .failure(first) }
        return .success(await audit(context))
    }

    private func install(_ pin: PinnedArtifact, _ context: RunContext) async -> RecipeFault? {
        let dest = context.locations.toolbox.appending(path: pin.id)
        // Idempotence: an artifact already at the pinned version is left alone,
        // so converge does no network work on a settled machine.
        if FileManager.default.isExecutableFile(atPath: dest.path) {
            let v = await Exec.run(dest, ["--version"],
                                   environment: context.environment, timeout: 10)
            if v.stdout.contains(pin.version) { return nil }
        }

        let fm = FileManager.default
        let staging = context.locations.downloads.appending(path: "\(pin.id)-\(pin.version)")
        do {
            try? fm.removeItem(at: staging)
            try fm.createDirectory(at: staging, withIntermediateDirectories: true)
            defer { try? fm.removeItem(at: staging) }

            let archive = staging.appending(path: "artifact.tar.gz")
            let (tmp, response) = try await URLSession.shared.download(from: pin.url)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                return RecipeFault(
                    kind: .unexpectedExit, recipe: descriptor.id, verb: .converge,
                    args: ["recipe": descriptor.id, "verb": "converge"],
                    detail: "HTTP \((response as? HTTPURLResponse)?.statusCode ?? -1) for \(pin.id)")
            }
            try fm.moveItem(at: tmp, to: archive)

            // Verify BEFORE unpacking. tar is a parser, and a parser fed
            // unverified bytes is attack surface -- so nothing we have not
            // already vouched for is ever handed to it.
            let digest = SHA256.hash(data: try Data(contentsOf: archive))
                .map { String(format: "%02x", $0) }.joined()
            guard digest == pin.sha256 else {
                return RecipeFault(
                    kind: .integrityFailure, recipe: descriptor.id, verb: .converge,
                    args: ["recipe": pin.id],
                    detail: "\(pin.id) \(pin.version)\nexpected \(pin.sha256)\nobserved \(digest)")
            }

            let untar = await Exec.run(
                URL(filePath: "/usr/bin/tar"), ["-xzf", archive.path, "-C", staging.path],
                environment: context.environment, timeout: 120)
            guard untar.status == 0 else {
                return RecipeFault(
                    kind: .unexpectedExit, recipe: descriptor.id, verb: .converge,
                    args: ["recipe": descriptor.id, "verb": "converge"], detail: untar.stderr)
            }

            let unpacked = staging.appending(path: pin.binary)
            guard fm.fileExists(atPath: unpacked.path) else {
                return RecipeFault(
                    kind: .malformedReport, recipe: descriptor.id, verb: .converge,
                    args: ["recipe": pin.id],
                    detail: "archive has no \(pin.binary); the pin's layout is wrong")
            }
            try fm.createDirectory(at: context.locations.toolbox,
                                   withIntermediateDirectories: true)
            // Atomic replace: a crash mid-write must never leave a half-copied
            // binary that the next run would cheerfully execute.
            if fm.fileExists(atPath: dest.path) {
                _ = try fm.replaceItemAt(dest, withItemAt: unpacked)
            } else {
                try fm.moveItem(at: unpacked, to: dest)
            }
            try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dest.path)
            return nil
        } catch {
            return RecipeFault(
                kind: .unexpectedExit, recipe: descriptor.id, verb: .converge,
                args: ["recipe": descriptor.id, "verb": "converge"],
                detail: "\(pin.id): \(error.localizedDescription)")
        }
    }
}
