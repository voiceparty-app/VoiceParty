import Foundation

/// Which local cleanup models a dictation can use, decided when it starts from what's known then (mode, the app's
/// category, settings), so only those are loaded and warmed while you speak. Which one actually runs depends on the
/// transcript (`PolishRouter`), known only at key-up, so every model the router could pick here is warmed.
public enum ModelWarmup {
    public struct Plan: Equatable, Sendable {
        public var fast: Bool
        public var strong: Bool

        public init(fast: Bool, strong: Bool) {
            self.fast = fast
            self.strong = strong
        }

        public static let none = Plan(fast: false, strong: false)
    }

    /// - Parameters:
    ///   - useModel: AI cleanup is on (off: no model runs at all, Command Mode included).
    ///   - autoTransform: a transform is applied to every dictation (it runs on the strongest model).
    ///   - strongInstalled: without the strong model, the fast one stands in for it.
    public static func plan(mode: DictationMode, category: AppCategory, level: CleanupLevel, useModel: Bool, secondLanguage: Bool,
                            autoTransform: Bool, strongInstalled: Bool) -> Plan {
        guard useModel else { return .none }
        var plan: Plan
        if mode == .command {
            plan = Plan(fast: false, strong: true) // transforms and answers use the strongest model
        } else if level == .none {
            plan = Plan(fast: false, strong: autoTransform)
        } else if secondLanguage || PolishRouter.needsStrong(category: category, level: level, relevantVocabulary: []) {
            plan = Plan(fast: false, strong: true) // the router picks the strong model or none here
        } else {
            plan = Plan(fast: true, strong: true) // skip, fast or strong: the transcript decides
        }
        if autoTransform { plan.strong = true }
        if !strongInstalled && plan.strong { plan = Plan(fast: true, strong: false) }
        return plan
    }
}
