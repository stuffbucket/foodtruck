import Foundation

/// The entire vocabulary FoodTruck has for talking to the things it manages.
///
/// This enum is the architectural boundary. FoodTruck knows these six words and
/// nothing else -- it has no idea Homebrew exists, what a `Brewfile` is, or that
/// Node has versions. A recipe that can answer these six questions can be
/// managed; one that cannot, cannot. Adding support for a new tool is writing a
/// recipe, never editing this file.
public enum Verb: String, CaseIterable, Sendable, Codable {
    /// Gather facts. Never judges, never mutates, always exits 0.
    /// Runs even for recipes the profile does not want, because "what is
    /// actually on this machine" is useful independently of intent.
    case detect
    /// Compare observed against desired. Never mutates. The exit code carries
    /// the verdict (see `VerbOutcome`).
    case audit
    /// Say what `converge` would do, in order, without doing it. Never mutates.
    case plan
    /// Make it so. MUST be idempotent and re-entrant: running it twice is
    /// running it once, and running it against a half-finished state finishes.
    case converge
    /// Prove the post-condition independently of `converge`'s own opinion.
    /// Same output contract as `audit`.
    case verify
    /// Return to the previous checkpoint. Optional -- a recipe that cannot
    /// safely undo itself declares so rather than pretending.
    case rollback

    /// Verbs that are contractually forbidden from changing the machine.
    /// The engine enforces this in test builds by running them against a
    /// tripwired filesystem.
    public var isReadOnly: Bool {
        switch self {
        case .detect, .audit, .plan, .verify: return true
        case .converge, .rollback: return false
        }
    }
}

/// A recipe's verdict, carried out-of-band on the process exit code so a
/// recipe can be a shell script with no JSON library.
///
/// The codes are deliberately far away from 1 and 2: almost every CLI in
/// existence exits 1 for "something went wrong", and we must never mistake a
/// crashed audit for a clean one -- or for drift.
public enum VerbOutcome: Sendable, Equatable {
    /// Observed matches desired. Nothing to do.
    case converged
    /// Observed differs from desired, and this recipe can fix it.
    case drift
    /// Cannot proceed until a dependency is satisfied. Not an error: the
    /// tech tree simply has not been unlocked this far yet.
    case blocked
    /// The recipe itself failed. Carries enough to tell the user what to do,
    /// because they will not be reading a stack trace.
    case failed(RecipeFault)

    static let convergedCode: Int32 = 0
    static let driftCode: Int32 = 10
    static let blockedCode: Int32 = 20

    public var isActionable: Bool { self == .drift }
}
