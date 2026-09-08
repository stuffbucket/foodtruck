import Foundation

/// Everything that can go wrong, enumerated.
///
/// This type is a promise: **no cryptic error conditions, no dead ends.** The
/// people using FoodTruck cannot debug it, so every failure has to arrive as
/// three things -- what happened, why, and the single next thing to try. A case
/// may only be added here together with its `remedy`. If a failure mode cannot
/// be explained to a designer at 11pm, the feature that produces it does not
/// ship.
///
/// `title` and `remedy` are localisation keys, never English.
public struct RecipeFault: Codable, Sendable, Equatable, Error {
    public enum Kind: String, Codable, Sendable {
        /// The recipe file is absent or unreadable.
        case recipeMissing
        /// The recipe's metadata does not parse.
        case recipeMalformed
        /// The signed settings defaults are unavailable, or the installed copy
        /// disappeared while housekeeping was settling it.
        case settingsUnavailable
        /// The user's settings exist but do not satisfy the settings schema.
        case settingsInvalid
        /// Runtime roots or environment-derived paths cannot be resolved safely.
        case runtimeEnvironmentInvalid
        /// The recipe does not implement a verb we asked for.
        case verbUnsupported
        /// The engine this recipe needs (e.g. `task`) is not unlocked yet.
        case engineUnavailable
        /// The recipe ran and exited with a code we have no meaning for.
        case unexpectedExit
        /// The recipe printed something that is not a valid report.
        case malformedReport
        /// The recipe exceeded its time budget and was stopped.
        case timedOut
        /// A read-only verb tried to write. This is a bug in the recipe and we
        /// refuse to let it pass silently.
        case readOnlyViolation
        /// A downloaded artifact did not match its pinned checksum.
        case integrityFailure
        /// The user cancelled.
        case cancelled
    }

    public var kind: Kind
    public var recipe: String
    public var verb: Verb
    /// Localisation key for the one-line explanation.
    public var title: String
    /// Localisation key for the next thing to try. Never nil -- that is the
    /// whole point of this type.
    public var remedy: String
    public var args: [String: String]
    /// Raw output, kept for the "Copy diagnostics" affordance. Never shown as
    /// the primary message.
    public var detail: String?

    public init(
        kind: Kind,
        recipe: String,
        verb: Verb,
        args: [String: String] = [:],
        detail: String? = nil
    ) {
        self.kind = kind
        self.recipe = recipe
        self.verb = verb
        self.args = args
        // Recipes and the tools they call emit ANSI colour. It is meaningless
        // once captured, and it corrupts anything the user pastes into a bug
        // report, so it is stripped at the boundary rather than at each display.
        self.detail = detail
            .map { $0.replacingOccurrences(
                of: "\u{1B}\\[[0-9;]*[A-Za-z]", with: "", options: .regularExpression) }
            .flatMap { $0.isEmpty ? nil : String($0.suffix(4000)) }
        self.title = "fault.\(kind.rawValue).title"
        self.remedy = "fault.\(kind.rawValue).remedy"
    }
}
