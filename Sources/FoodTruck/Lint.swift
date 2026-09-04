import Foundation
import FoodTruckKit

/// Checks that only make sense against the network or the wider world, kept out
/// of `selftest` so that command stays offline, fast and deterministic.
enum Lint {
    static func run(_ locations: Locations, _ args: [String]) async -> Int32 {
        switch args.first {
        case "pins", nil: return await pins(locations)
        case "strings": return strings()
        default:
            FileHandle.standardError.write(Data("foodtruck lint: unknown check\n".utf8))
            return 64
        }
    }

    /// Reports translation coverage per locale.
    ///
    /// Deliberately does not fail the build on an incomplete locale -- shipping
    /// English for an untranslated string is correct behaviour, and a red build
    /// would only tempt someone to paste machine translation in to clear it.
    /// It fails only when the *source* language has a hole, because that is a
    /// string no fallback can rescue.
    static func strings() -> Int32 {
        let english = L10n.keys(for: "en")
        guard !english.isEmpty else {
            FileHandle.standardError.write(Data(
                "foodtruck lint strings: no English strings found.\n".utf8))
            return 1
        }
        for locale in L10n.supported {
            let have = L10n.keys(for: locale)
            let missing = english.subtracting(have)
            let pct = Int((Double(english.count - missing.count) / Double(english.count)) * 100)
            let mark = missing.isEmpty ? Render.paint("✓", "32") : Render.paint("·", "33")
            print("\(mark) \(locale.padding(toLength: 8, withPad: " ", startingAt: 0)) "
                  + "\(pct)%  \(english.count - missing.count)/\(english.count)")
            for key in missing.sorted().prefix(5) {
                print("    \(Render.paint("missing: " + key, "90"))")
            }
            if missing.count > 5 {
                print("    \(Render.paint("… and \(missing.count - 5) more", "90"))")
            }
        }
        return 0
    }

    /// Re-derives every pinned digest from upstream and compares it to what we
    /// shipped.
    ///
    /// The point is not to catch upstream changing a release -- a digest that
    /// changed under a fixed version is exactly what the pin is for, and the
    /// converge path already refuses it. The point is to catch *us*: a pin
    /// transcribed wrong, or copied from a research note nobody re-checked.
    /// Trust the source, verify the transcription.
    static func pins(_ locations: Locations) async -> Int32 {
        guard let manifest = PinManifest.load(locations) else {
            let message = "foodtruck lint pins: no pin manifest found. "
                + "Set FOODTRUCK_PANTRY_SEED, or run from the app bundle.\n"
            FileHandle.standardError.write(Data(message.utf8))
            return 1
        }
        var bad = 0
        for pin in manifest.artifacts {
            let result = await Exec.run(
                URL(filePath: "/bin/sh"), ["-c", pin.verify],
                environment: Exec.baseEnvironment(
                    locations, extra: ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin"]),
                timeout: 60)
            let upstream = result.stdout.lowercased()
            let ok = result.status == 0 && upstream.contains(pin.sha256.lowercased())
            if ok {
                print("\(Render.paint("✓", "32")) \(pin.id) \(pin.version)  "
                      + "\(Render.paint("digest matches upstream", "90"))")
            } else {
                bad += 1
                print("\(Render.paint("✗", "31")) \(pin.id) \(pin.version)")
                print("    pinned:   \(pin.sha256)")
                print("    upstream: \(upstream.trimmingCharacters(in: .whitespacesAndNewlines))")
                print("    \(Render.paint("re-run: " + pin.verify, "36"))")
            }
            print("    \(Render.paint(pin.provenance, "90"))")
        }
        return bad == 0 ? 0 : 1
    }
}
