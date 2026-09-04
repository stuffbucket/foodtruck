import Foundation

/// Localised strings, with no way to reach a dead end.
///
/// Findings, faults and recipe names all travel as message keys and become
/// sentences here, in the user's language. Three rules:
///
/// * A missing key never crashes and never shows blank. It falls back through
///   the requested locale, then English, then the key itself -- ugly on screen,
///   but visible in a screenshot and greppable, which is what you want a
///   missing translation to be.
/// * `foodtruck lint strings` fails the build when a key used in code is absent
///   from any shipped locale, so the ugly fallback is a CI failure rather than
///   something a designer finds in the Japanese build.
/// * Interpolation is by name (`%{version}`), not by position. Translators
///   reorder clauses; positional `%@` makes that impossible in some languages.
public final class L10n: @unchecked Sendable {
    public static let shared = L10n()

    /// The five we commit to shipping and testing. Adding a sixth is adding a
    /// directory and a CI row -- deliberately cheap.
    public static let supported = ["en", "es", "zh-Hans", "de", "ja"]

    private var tables: [String: [String: String]] = [:]
    private var chain: [String] = ["en"]
    private let lock = NSLock()
    /// Keys asked for and not found. The lint command reads this after a run.
    public private(set) var misses: Set<String> = []

    private init() { configure(locales: Locale.preferredLanguages) }

    /// Build the fallback chain from the user's preferred languages, always
    /// ending at English so lookup terminates.
    public func configure(locales: [String], bundle: Bundle? = nil) {
        lock.lock(); defer { lock.unlock() }
        var order: [String] = []
        for tag in locales {
            // "zh-Hans-US" -> try "zh-Hans" then "zh"; "es-419" -> "es".
            let parts = tag.split(separator: "-").map(String.init)
            for n in stride(from: parts.count, through: 1, by: -1) {
                let candidate = parts.prefix(n).joined(separator: "-")
                if Self.supported.contains(candidate), !order.contains(candidate) {
                    order.append(candidate)
                }
            }
        }
        if !order.contains("en") { order.append("en") }
        chain = order
        tables = [:]
        for code in order { tables[code] = Self.load(code, bundle: bundle) }
    }

    private static func load(_ code: String, bundle: Bundle?) -> [String: String] {
        let candidates = [bundle, Bundle.main, Bundle.moduleIfPresent].compactMap { $0 }
        for b in candidates {
            // Three layouts, because the same source tree is built three ways:
            // SwiftPM resource bundle, a real .app bundle, and plain swiftc.
            let url = b.url(forResource: "Localizable", withExtension: "strings",
                            subdirectory: "Resources/\(code).lproj")
                ?? b.url(forResource: "Localizable", withExtension: "strings",
                         subdirectory: "\(code).lproj")
                ?? b.url(forResource: "Localizable", withExtension: "strings",
                         subdirectory: nil, localization: code)
            guard let url else { continue }
            if let d = try? Data(contentsOf: url),
               let plist = try? PropertyListSerialization.propertyList(
                    from: d, format: nil) as? [String: String] {
                return plist
            }
        }
        return [:]
    }

    /// Look up `key`, substituting `%{name}` placeholders from `args`.
    ///
    /// A string containing a space is prose, not a key -- recipes supply their
    /// own remedy text and we pass it through rather than pretending to
    /// translate it. Crucially it is not recorded as a miss, so the lint stays
    /// meaningful instead of drowning in false positives.
    public func t(_ key: String, _ args: [String: String] = [:]) -> String {
        if key.contains(" ") {
            var out = key
            for (n, v) in args { out = out.replacingOccurrences(of: "%{\(n)}", with: v) }
            return out
        }
        lock.lock()
        var template: String?
        for code in chain { if let v = tables[code]?[key] { template = v; break } }
        if template == nil { misses.insert(key) }
        lock.unlock()

        var out = template ?? key
        for (name, value) in args {
            out = out.replacingOccurrences(of: "%{\(name)}", with: value)
        }
        return out
    }

    public func resetMisses() { lock.lock(); misses = []; lock.unlock() }

    /// Plural categories, per CLDR, for the languages we actually ship.
    ///
    /// Deliberately a small explicit table rather than a general CLDR engine.
    /// These five languages need exactly two rules between them, and a lookup
    /// table that is obviously right beats a rules engine that is probably
    /// right. The cost is that adding a sixth language means adding a case
    /// here -- Polish, Russian and Arabic all need `few`/`many`/`zero` -- and
    /// `pluralRulesCoverEveryLocale` in the self-test fails until you do, so
    /// this cannot be forgotten rather than merely documented.
    static func category(_ n: Int, _ language: String) -> String {
        switch language {
        case "ja", "zh-Hans":
            // No grammatical plural; one form covers every count.
            return "other"
        case "en", "es", "de":
            return n == 1 ? "one" : "other"
        default:
            return n == 1 ? "one" : "other"
        }
    }

    /// Whether a language has an explicit rule above, as opposed to falling
    /// through to the English-shaped default.
    static func hasExplicitPluralRule(_ language: String) -> Bool {
        ["ja", "zh-Hans", "en", "es", "de"].contains(language)
    }

    /// Look up a count-dependent string.
    ///
    /// Keys are suffixed with the category: `summary.attention.one`,
    /// `summary.attention.other`. `%{count}` is filled in automatically.
    public func plural(_ key: String, _ count: Int, _ args: [String: String] = [:]) -> String {
        let language = chainHead
        var merged = args
        merged["count"] = String(count)
        let categorised = "\(key).\(Self.category(count, language))"
        let resolved = t(categorised, merged)
        // A locale that has not been given plural forms yet must not show a raw
        // key on screen; fall back to the base key before giving up.
        return resolved == categorised ? t(key, merged) : resolved
    }

    private var chainHead: String {
        lock.lock(); defer { lock.unlock() }
        return chain.first ?? "en"
    }

    /// Every key defined for a locale, for the coverage lint.
    public static func keys(for locale: String) -> Set<String> {
        Set(load(locale, bundle: nil).keys)
    }
}

/// Shorthand used everywhere a string reaches a human.
public func t(_ key: String, _ args: [String: String] = [:]) -> String {
    L10n.shared.t(key, args)
}

/// Shorthand for a string whose wording depends on a count.
public func tn(_ key: String, _ count: Int, _ args: [String: String] = [:]) -> String {
    L10n.shared.plural(key, count, args)
}

private extension Bundle {
    /// `Bundle.module` only exists when SwiftPM generated resources for the
    /// target; referencing it unconditionally breaks the plain-`swiftc` build
    /// the release producer uses.
    static var moduleIfPresent: Bundle? {
        #if SWIFT_PACKAGE
        return Bundle.module
        #else
        return nil
        #endif
    }
}
