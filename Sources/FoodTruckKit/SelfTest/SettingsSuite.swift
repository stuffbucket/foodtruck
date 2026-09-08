import Foundation

private struct SettingsSandbox {
    let root: URL
    let seedRecipes: URL
    var locations: Locations { Locations(root: root, seed: seedRecipes) }

    init() throws {
        root = URL(filePath: NSTemporaryDirectory())
            .appending(path: "foodtruck-settings-test-\(UUID().uuidString)")
        seedRecipes = root.appending(path: "seed/Cookbook/recipes")
        try FileManager.default.createDirectory(at: seedRecipes, withIntermediateDirectories: true)
        try Data(Self.defaultJSON.utf8).write(
            to: seedRecipes.deletingLastPathComponent().appending(path: "settings.json"))
    }

    func destroy() { try? FileManager.default.removeItem(at: root) }

    static var defaultJSON: String {
        let reporting = InventoryReportID.allCases.map { id in
            ReportingDeclaration(
                id: id.rawValue, severity: .notice, section: .observation,
                cardinality: id.cardinality, title: "test.\(id.rawValue)")
        }
        let settings = FoodTruckSettings(
            vars: ["base": "one", "shared": "default"],
            inventory: InventorySettings(
                scan: InventoryScanSettings(
                    declarations: [PathDeclaration(
                        type: .file, source: SettingsPathSource(literal: "/etc/paths"))],
                    sources: [SettingsPathSource(literal: "~/.local/bin")]),
                probes: ProbeSettings(names: ["git", "swift"]),
                managers: [], origins: [],
                gitCandidates: [SettingsPathSource(literal: "/usr/local/bin/git")],
                reporting: reporting,
                discovery: InventoryDiscoverySettings(
                    roots: [SoftwareDiscoveryRoot(
                        source: SettingsPathSource(literal: "~/.config"),
                        strategy: .topLevelFootprints,
                        exclusions: ["foodtruck"])],
                    exclusions: [SettingsPathSource(literal: "~/.ssh")])))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return String(decoding: try! encoder.encode(settings), as: UTF8.self)
    }
}

private actor SettingsContextCapture: RecipeEngine {
    let id = "settings-capture"
    private var value: RunContext?

    func availability(_ context: RunContext) async -> EngineAvailability { .ready }

    func run(_ verb: Verb, recipe: Recipe, context: RunContext) async -> VerbResult {
        value = context
        return VerbResult(recipe: recipe.id, verb: verb, outcome: .converged)
    }

    func context() -> RunContext? { value }
}

enum SettingsSuite {
    static let suite = Suite("settings", [
        Case("the XDG settings path is derived from Locations") { s in
            let locations = Locations.resolved(environment: [
                "HOME": "/Users/nobody", "XDG_CONFIG_HOME": "/tmp/config"
            ])
            s.equal(locations.settings.path, "/tmp/config/foodtruck/settings.json",
                    "settings did not live under XDG config")
        },
        Case("a missing user file loads defaults without writing") { s in
            let box = try SettingsSandbox(); defer { box.destroy() }
            guard case .missing(let settings) = SettingsLoader.load(box.locations) else {
                s.require(false, "missing settings did not return defaults"); return
            }
            s.equal(settings.vars["base"], "one", "bundled vars were not loaded")
            s.require(!FileManager.default.fileExists(atPath: box.locations.settings.path),
                      "the read-only loader installed settings")
        },
        Case("user arrays replace while vars merge and unknown keys are ignored") { s in
            let box = try SettingsSandbox(); defer { box.destroy() }
            try FileManager.default.createDirectory(at: box.locations.config,
                                                    withIntermediateDirectories: true)
            let user = #"""
            {
              "schema":"foodtruck.settings/1",
              "future":{"anything":true},
              "vars":{"shared":"user","added":"two"},
              "inventory":{"probes":{"names":[],"timeout":999,"concurrency":999}}
            }
            """#
            try Data(user.utf8).write(to: box.locations.settings)
            guard case .loaded(let settings) = SettingsLoader.load(box.locations) else {
                s.require(false, "valid overlay did not load"); return
            }
            s.equal(settings.vars["base"], "one", "missing var did not inherit")
            s.equal(settings.vars["shared"], "user", "user var did not win")
            s.equal(settings.vars["added"], "two", "new user var was lost")
            s.require(settings.inventory.probes.names.isEmpty,
                      "present array merged instead of replacing")
            s.equal(settings.inventory.discovery.roots.map(\.strategy),
                    [.topLevelFootprints],
                    "omitted discovery policy did not inherit bundled defaults")
        },
        Case("Kitchen injects one profile and explicit vars win") { s in
            let box = try SettingsSandbox(); defer { box.destroy() }
            guard let settings = SettingsLoader.load(box.locations).settings else {
                s.require(false, "bundled settings did not load"); return
            }
            let environment = [
                "HOME": box.root.path,
                "FOODTRUCK_SCAN_ROOT": box.root.path,
            ]
            let profile = try SettingsProfile(settings: settings, environment: environment)
            let engine = SettingsContextCapture()
            let recipe = Recipe(
                id: "capture", name: "capture", summary: "capture",
                engine: engine.id)
            let kitchen = Kitchen(
                locations: box.locations, recipes: [recipe], profile: profile,
                engines: [engine], environment: environment)

            _ = await kitchen.inspect(
                .audit, vars: ["shared": "call", "explicit": "three"])
            guard let context = await engine.context() else {
                s.require(false, "engine did not receive a context"); return
            }
            s.equal(context.profile, profile, "Kitchen replaced the resolved profile")
            s.equal(context.vars["base"], "one", "profile-only var was lost")
            s.equal(context.vars["shared"], "call", "explicit var did not win")
            s.equal(context.vars["explicit"], "three", "explicit var was lost")
        },
        Case("Kitchen remains source-compatible without a profile") { s in
            let box = try SettingsSandbox(); defer { box.destroy() }
            let engine = SettingsContextCapture()
            let recipe = Recipe(
                id: "capture", name: "capture", summary: "capture",
                engine: engine.id)
            let kitchen = Kitchen(
                locations: box.locations, recipes: [recipe], engines: [engine],
                environment: ["HOME": box.root.path])

            _ = await kitchen.inspect(.audit, vars: ["explicit": "unchanged"])
            guard let context = await engine.context() else {
                s.require(false, "engine did not receive a context"); return
            }
            s.require(context.profile == nil, "Kitchen invented an implicit profile")
            s.equal(context.vars, ["explicit": "unchanged"],
                    "explicit vars changed without a profile")
        },
        Case("unsupported schema enum and unsafe paths are invalid") { s in
            let samples = [
                #"{"schema":"foodtruck.settings/2"}"#,
                #"{"schema":"foodtruck.settings/1","inventory":{"reporting":[{"id":"x","severity":"loud","section":"attention","cardinality":"once","title":"x","fixable":false}]}}"#,
                #"{"schema":"foodtruck.settings/1","inventory":{"reporting":[]}}"#,
                #"{"schema":"foodtruck.settings/1","inventory":{"scan":{"sources":[{"type":"literal","path":"../../etc"}]}}}"#,
                #"{"schema":"foodtruck.settings/1","inventory":{"scan":{"sources":[{"type":"literal","path":"~/bin/*"}]}}}"#,
                #"{"schema":"foodtruck.settings/1","inventory":{"origins":[{"origin":"apple","match":"under","patterns":[],"paths":[{"type":"literal","path":"/usr"}],"requires":[""]}]}}"#,
                #"{"schema":"foodtruck.settings/1","inventory":{"managers":[{"id":"x","binaries":[],"directories":[],"manages":[],"scanRoots":[{"source":{"type":"literal","path":"~/bin"},"kind":"mystery"}],"shellFunction":false,"roleEvidence":[]}]}}"#,
                #"{"schema":"foodtruck.settings/1","inventory":{"discovery":{"roots":[{"source":{"type":"literal","path":"~/.config"},"strategy":"recursiveEverything","exclusions":[]}]}}}"#,
                #"{"schema":"foodtruck.settings/1","inventory":{"discovery":{"roots":[{"source":{"type":"literal","path":"~/.config"},"strategy":"topLevelFootprints","exclusions":["nested/path"]}]}}}"#,
                #"{"schema":"foodtruck.settings/1","inventory":{"discovery":{"roots":[{"source":{"type":"literal","path":"~/.config"},"strategy":"topLevelFootprints","exclusions":["*.secret"]}]}}}"#,
                #"{"schema":"foodtruck.settings/1","inventory":{"discovery":{"exclusions":[{"type":"literal","path":"~/.ssh/*"}]}}}"#,
            ]
            for (index, user) in samples.enumerated() {
                let box = try SettingsSandbox(); defer { box.destroy() }
                try FileManager.default.createDirectory(at: box.locations.config,
                                                        withIntermediateDirectories: true)
                try Data(user.utf8).write(to: box.locations.settings)
                guard case .invalid = SettingsLoader.load(box.locations) else {
                    s.require(false, "invalid sample \(index) loaded"); continue
                }
            }
        },
        Case("paths use supplied roots and never shell expansion") { s in
            let home = URL(filePath: "/sealed/home")
            let root = URL(filePath: "/sealed/system")
            let literal = SettingsPathSource(literal: "/usr/bin")
            s.equal(try literal.resolve(home: home, systemRoot: root, environment: [:]).first?.path,
                    "/sealed/system/usr/bin", "absolute path escaped systemRoot")
            let source = SettingsPathSource(environment: "TOOLS", fallback: "~/.tools",
                                            suffix: "bin", separator: ":")
            let resolved = try source.resolve(
                home: home, systemRoot: root,
                environment: ["TOOLS": "~/.one:/opt/two"])
            s.equal(resolved.map(\.path),
                    ["/sealed/home/.one/bin", "/sealed/system/opt/two/bin"],
                    "environment path source resolved incorrectly")
        },
        Case("discovery overlays replace roots and preserve independent defaults") { s in
            let box = try SettingsSandbox(); defer { box.destroy() }
            try FileManager.default.createDirectory(at: box.locations.config,
                                                    withIntermediateDirectories: true)
            let user = #"""
            {
              "schema":"foodtruck.settings/1",
              "inventory":{"discovery":{"roots":[
                {"source":{"type":"environment","environment":"SOFTWARE_ROOTS",
                 "fallback":"~/Applications","suffix":"","separator":":"},
                 "strategy":"applicationBundles"}
              ]}}
            }
            """#
            try Data(user.utf8).write(to: box.locations.settings)
            guard case .loaded(let settings) = SettingsLoader.load(box.locations) else {
                s.require(false, "discovery overlay did not load"); return
            }
            s.equal(settings.inventory.discovery.roots.count, 1,
                    "supplied discovery roots merged instead of replacing")
            s.equal(settings.inventory.discovery.exclusions,
                    [SettingsPathSource(literal: "~/.ssh")],
                    "omitted global exclusions did not inherit")

            let home = box.root.appending(path: "home")
            let system = box.root.appending(path: "system")
            try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: system, withIntermediateDirectories: true)
            let profile = try SettingsProfile(
                settings: settings, home: home, systemRoot: system,
                environment: ["SOFTWARE_ROOTS": "~/Apps:/opt/Apps"])
            let roots = profile.inventory.discoveryRoots
            let canonicalHome = try SettingsPathSource(literal: "~")
                .resolve(home: home, systemRoot: system, environment: [:])[0]
            let canonicalSystem = try SettingsPathSource(literal: "/")
                .resolve(home: home, systemRoot: system, environment: [:])[0]
            s.equal(roots.map(\.url.path), [
                canonicalHome.appending(path: "Apps").path,
                canonicalSystem.appending(path: "opt/Apps").path,
            ], "environment-derived discovery roots resolved incorrectly")
            s.equal(roots.map(\.strategy), [.applicationBundles, .applicationBundles],
                    "discovery strategy was not preserved")
            s.require(roots.allSatisfy { $0.exclusions.isEmpty },
                      "omitted root-local exclusions did not default to empty")
            s.require(profile.inventory.pathSourceEnvironment.contains("SOFTWARE_ROOTS"),
                      "discovery path variable was not removed from probe environments")
            s.equal(profile.inventory.discoveryExclusions.map(\.path),
                    [canonicalHome.appending(path: ".ssh").path],
                    "global discovery exclusions did not resolve")
        },
        Case("discovery exclusion arrays replace independently") { s in
            let box = try SettingsSandbox(); defer { box.destroy() }
            try FileManager.default.createDirectory(at: box.locations.config,
                                                    withIntermediateDirectories: true)
            let user = #"""
            {"schema":"foodtruck.settings/1","inventory":{"discovery":{
              "exclusions":[{"type":"literal","path":"~/.gnupg"}]
            }}}
            """#
            try Data(user.utf8).write(to: box.locations.settings)
            guard case .loaded(let settings) = SettingsLoader.load(box.locations) else {
                s.require(false, "discovery exclusion overlay did not load"); return
            }
            s.equal(settings.inventory.discovery.roots.count, 1,
                    "omitted discovery roots did not inherit")
            s.equal(settings.inventory.discovery.exclusions,
                    [SettingsPathSource(literal: "~/.gnupg")],
                    "supplied exclusions merged instead of replacing")
        },
        Case("explicit empty discovery arrays clear bundled policy") { s in
            let box = try SettingsSandbox(); defer { box.destroy() }
            try FileManager.default.createDirectory(at: box.locations.config,
                                                    withIntermediateDirectories: true)
            let user = #"""
            {"schema":"foodtruck.settings/1","inventory":{"discovery":{
              "roots":[],"exclusions":[]
            }}}
            """#
            try Data(user.utf8).write(to: box.locations.settings)
            guard case .loaded(let settings) = SettingsLoader.load(box.locations) else {
                s.require(false, "empty discovery overlay did not load"); return
            }
            s.require(settings.inventory.discovery.roots.isEmpty,
                      "empty roots did not clear bundled policy")
            s.require(settings.inventory.discovery.exclusions.isEmpty,
                      "empty exclusions did not clear bundled policy")
        },
        Case("manager scan roots default empty and resolve with typed kinds") { s in
            let box = try SettingsSandbox(); defer { box.destroy() }
            try FileManager.default.createDirectory(at: box.locations.config,
                                                    withIntermediateDirectories: true)
            let user = #"""
            {
              "schema":"foodtruck.settings/1",
              "inventory":{"managers":[
                {"id":"legacy","binaries":[],"directories":[],"manages":["node"],
                 "shellFunction":false,"roleEvidence":[]},
                {"id":"rooted","binaries":[],"directories":[],"manages":["ruby"],
                 "scanRoots":[
                   {"source":{"type":"literal","path":"~/.rooted/shims"},"kind":"shim"},
                   {"source":{"type":"environment","environment":"ROOTS",
                    "fallback":"/fallback","suffix":"bin","separator":":"},"kind":"direct"}
                 ],"shellFunction":false,"roleEvidence":[]}
              ]}
            }
            """#
            try Data(user.utf8).write(to: box.locations.settings)
            guard case .loaded(let settings) = SettingsLoader.load(box.locations) else {
                s.require(false, "manager scan-root overlay did not load"); return
            }
            s.require(settings.inventory.managers[0].scanRoots.isEmpty,
                      "missing scanRoots did not default to empty")
            let home = box.root.appending(path: "home")
            let system = box.root.appending(path: "system")
            try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: system, withIntermediateDirectories: true)
            let profile = try SettingsProfile(
                settings: settings, home: home, systemRoot: system,
                environment: ["ROOTS": "~/.one:/opt/two"])
            let roots = profile.inventory.managers[1].scanRoots
            let canonicalHome = try SettingsPathSource(literal: "~")
                .resolve(home: home, systemRoot: system, environment: [:])[0]
            let canonicalSystem = try SettingsPathSource(literal: "/")
                .resolve(home: home, systemRoot: system, environment: [:])[0]
            s.equal(roots.map(\.url.path), [
                canonicalHome.appending(path: ".rooted/shims").path,
                canonicalHome.appending(path: ".one/bin").path,
                canonicalSystem.appending(path: "opt/two/bin").path,
            ], "manager scan roots did not resolve through the runtime profile")
            s.equal(roots.map(\.kind), [.shim, .direct, .direct],
                    "manager scan-root kinds were not preserved")
        },
        Case("a symlink cannot escape the supplied runtime root") { s in
            let box = try SettingsSandbox(); defer { box.destroy() }
            let system = box.root.appending(path: "system")
            let outside = box.root.appending(path: "outside")
            let home = box.root.appending(path: "home")
            try FileManager.default.createDirectory(at: system, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
            try FileManager.default.createSymbolicLink(
                at: system.appending(path: "link"), withDestinationURL: outside)
            try FileManager.default.createSymbolicLink(
                at: home.appending(path: "link"), withDestinationURL: outside)
            do {
                _ = try SettingsPathSource(literal: "/link/bin").resolve(
                    home: home, systemRoot: system, environment: [:])
                s.require(false, "a symlink escaped systemRoot")
            } catch is SettingsValidationError {
                // Expected: the canonical target is outside the sealed root.
            }
            do {
                _ = try SettingsPathSource(literal: "~/link/bin").resolve(
                    home: home, systemRoot: system, environment: [:])
                s.require(false, "a symlink escaped the supplied home")
            } catch is SettingsValidationError {
                // Expected: home-relative paths stay under the canonical home.
            }
        },
        Case("missing bundled settings use a settings-specific fault") { s in
            let root = URL(filePath: NSTemporaryDirectory())
                .appending(path: "foodtruck-settings-no-seed-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: root) }
            let locations = Locations(root: root)
            let context = RunContext(locations: locations, environment: ["HOME": root.path])
            guard case .failure(let fault) = await SettingsRecipe().converge(context) else {
                s.require(false, "missing bundled settings were treated as converged"); return
            }
            s.equal(fault.kind, .settingsUnavailable,
                    "missing defaults used an unrelated recipe fault")
        },
        Case("CLI profile paths can use an explicitly configured ambient variable") { s in
            let box = try SettingsSandbox(); defer { box.destroy() }
            let bin = box.root.appending(path: "ambient-bin")
            let command = bin.appending(path: "ambient-tool")
            try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
            try Data("#!/bin/sh\nexit 0\n".utf8).write(to: command)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o755], ofItemAtPath: command.path)
            try FileManager.default.createDirectory(
                at: box.locations.config, withIntermediateDirectories: true)
            let overlay = #"""
            {
              "schema":"foodtruck.settings/1",
              "inventory":{
                "scan":{
                  "declarations":[],
                  "sources":[{"type":"environment","environment":"CUSTOM_TOOL_ROOT",
                              "fallback":"~/missing","suffix":"","separator":":"}]
                },
                "managers":[],
                "origins":[],
                "probes":{"names":[]},
                "gitCandidates":[]
              }
            }
            """#
            try Data(overlay.utf8).write(to: box.locations.settings)

            let process = Process()
            process.executableURL = URL(filePath: CommandLine.arguments[0])
            process.arguments = ["inventory", "--all"]
            process.environment = [
                "HOME": box.root.path,
                "FOODTRUCK_ROOT": box.root.path,
                "FOODTRUCK_SCAN_ROOT": box.root.path,
                "FOODTRUCK_COOKBOOK_SEED": box.seedRecipes.path,
                "CUSTOM_TOOL_ROOT": "/ambient-bin",
            ]
            let output = Pipe()
            process.standardOutput = output
            process.standardError = Pipe()
            try process.run()
            process.waitUntilExit()
            let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(),
                              as: UTF8.self)
            s.equal(process.terminationStatus, 0,
                    "inventory rejected a valid ambient path source")
            s.require(text.contains("ambient-tool"),
                      "the CLI profile discarded the configured ambient path source")
        },
        Case("invalid runtime roots use their own actionable fault") { s in
            let box = try SettingsSandbox(); defer { box.destroy() }
            let process = Process()
            process.executableURL = URL(filePath: CommandLine.arguments[0])
            process.arguments = ["audit", "--json"]
            process.environment = [
                "HOME": "relative",
                "FOODTRUCK_ROOT": box.root.path,
                "FOODTRUCK_COOKBOOK_SEED": box.seedRecipes.path,
            ]
            let output = Pipe()
            process.standardOutput = output
            process.standardError = Pipe()
            try process.run()
            process.waitUntilExit()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            let error = json?["error"] as? [String: Any]
            s.equal(error?["kind"] as? String,
                    RecipeFault.Kind.runtimeEnvironmentInvalid.rawValue,
                    "runtime validation was classified as a settings file failure")

            defer { L10n.shared.configure(locales: Locale.preferredLanguages) }
            for locale in ["en", "es"] {
                L10n.shared.configure(locales: [locale])
                let fault = RecipeFault(
                    kind: .runtimeEnvironmentInvalid, recipe: "core.settings", verb: .audit)
                s.require(t(fault.title) != fault.title,
                          "the runtime fault title was not localized for \(locale)")
                s.require(t(fault.remedy).contains("HOME"),
                          "the runtime remedy did not identify HOME for \(locale)")
            }
        },
        Case("invalid loaded user settings use a settings-specific fault") { s in
            let box = try SettingsSandbox(); defer { box.destroy() }
            try FileManager.default.createDirectory(
                at: box.locations.config, withIntermediateDirectories: true)
            let invalid = Data(#"{"schema":"foodtruck.settings/999"}"#.utf8)
            try invalid.write(to: box.locations.settings)
            let context = RunContext(
                locations: box.locations,
                environment: ["HOME": box.root.path, "FOODTRUCK_SCAN_ROOT": box.root.path])

            guard case .failure(let fault) = await SettingsRecipe().converge(context) else {
                s.require(false, "invalid user settings were treated as converged"); return
            }
            s.equal(fault.kind, .settingsInvalid,
                    "invalid user settings used an unrelated fault")
            s.equal(try Data(contentsOf: box.locations.settings), invalid,
                    "invalid user settings were overwritten")
        },
        Case("settings housekeeping collapses only an untouched generated full copy") { s in
            let box = try SettingsSandbox(); defer { box.destroy() }
            try FileManager.default.createDirectory(
                at: box.locations.config, withIntermediateDirectories: true)
            let generated = Data(SettingsSandbox.defaultJSON.utf8)
            try generated.write(to: box.locations.settings)
            let context = RunContext(
                locations: box.locations,
                environment: ["HOME": box.root.path, "FOODTRUCK_SCAN_ROOT": box.root.path])

            guard case .success = await SettingsRecipe().converge(context) else {
                s.require(false, "an untouched generated copy did not migrate"); return
            }
            let migrated = try JSONSerialization.jsonObject(
                with: Data(contentsOf: box.locations.settings)) as? [String: Any]
            s.equal(migrated?["schema"] as? String, FoodTruckSettings.currentSchema,
                    "migration wrote the wrong overlay schema")
            s.require(migrated?["inventory"] == nil,
                      "migration retained the frozen inventory catalogue")

            let edited = generated + Data("\n".utf8)
            try edited.write(to: box.locations.settings, options: .atomic)
            guard case .success = await SettingsRecipe().converge(context) else {
                s.require(false, "a valid edited full copy did not converge"); return
            }
            s.equal(try Data(contentsOf: box.locations.settings), edited,
                    "a user-edited full copy was mistaken for generated data")
        },
        Case("settings housekeeping installs an inheriting overlay and preserves invalid data") { s in
            let box = try SettingsSandbox(); defer { box.destroy() }
            let recipe = SettingsRecipe()
            let context = RunContext(
                locations: box.locations,
                environment: ["HOME": box.root.path, "FOODTRUCK_SCAN_ROOT": box.root.path])
            guard case .success = await recipe.converge(context) else {
                s.require(false, "missing settings did not converge"); return
            }
            let installed = try JSONSerialization.jsonObject(
                with: Data(contentsOf: box.locations.settings)) as? [String: Any]
            s.equal(installed?["schema"] as? String, FoodTruckSettings.currentSchema,
                    "converge wrote the wrong overlay schema")
            s.require(installed?["inventory"] == nil,
                      "generated settings froze the bundled inventory catalogue")
            guard case .loaded(let inherited) = SettingsLoader.load(box.locations) else {
                s.require(false, "the minimal overlay did not inherit defaults"); return
            }
            s.equal(inherited.inventory.probes.names, ["git", "swift"],
                    "the minimal overlay did not inherit bundled policy")

            let invalid = Data(#"{"schema":"foodtruck.settings/999"}"#.utf8)
            try invalid.write(to: box.locations.settings, options: .atomic)
            let report = await recipe.audit(context)
            s.require(report.findings.contains(where: { $0.id == "settings.invalid" }),
                      "invalid settings were not surfaced")
            guard case .failure(let fault) = await recipe.converge(context) else {
                s.require(false, "invalid settings were treated as converged"); return
            }
            s.equal(fault.kind, .settingsInvalid,
                    "invalid settings used a recipe-specific fault")
            s.equal(try Data(contentsOf: box.locations.settings), invalid,
                    "invalid settings were replaced")
        },
    ])
}
