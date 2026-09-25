import Foundation

/// Decides when to tell the user that another app's Secure Keyboard Entry is blocking the shortcuts.
/// Password fields turn it on briefly all the time, so only a stretch longer than `threshold` counts, and
/// each stretch is reported once. Feed it the system state on a timer.
public struct SecureInputWatch: Sendable {
    public enum Event: Equatable, Sendable {
        /// Secure input has been on for a while; `owner` is the app holding it (nil if unknown).
        case blocked(owner: String?)
        /// It turned off again.
        case cleared
    }

    public var threshold: TimeInterval
    private var since: TimeInterval?
    private var reported = false

    public init(threshold: TimeInterval = 8) {
        self.threshold = threshold
    }

    public var isBlocked: Bool { reported }

    public mutating func observe(enabled: Bool, owner: String?, at time: TimeInterval) -> Event? {
        guard enabled else {
            defer { since = nil; reported = false }
            return reported ? .cleared : nil
        }
        let start = since ?? time
        since = start
        guard !reported, time - start >= threshold else { return nil }
        reported = true
        return .blocked(owner: owner)
    }

    /// What to say, with the usual fix.
    public static func message(owner: String?) -> String {
        let app = owner ?? "Another app"
        switch owner?.lowercased() {
        case "terminal", "iterm2", "iterm":
            return "\(app) has Secure Keyboard Entry on, which blocks VoiceParty's shortcuts. Turn it off in the \(app) menu."
        case let name? where name.contains("1password"):
            return "1Password has Secure Keyboard Entry stuck on, which blocks VoiceParty's shortcuts. Quit and reopen 1Password."
        default:
            return "\(app) has Secure Keyboard Entry on, which blocks VoiceParty's shortcuts until it turns off."
        }
    }
}
