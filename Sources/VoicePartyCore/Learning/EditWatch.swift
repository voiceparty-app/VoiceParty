import Foundation

/// Follows one paste in a text field until `EditObservation` decides. First it looks for the pasted text — the paste
/// lands a moment after ⌘V, and a Chromium app builds its accessibility tree only once asked — then it reads the field
/// every `interval` (the app also wakes it as soon as the field says its text changed) until the correction settles,
/// is sent, focus moves, the window ends or the watch is cancelled (the next dictation started): every ending decides
/// with what was seen, none drops a correction. AppKit-free: the app passes the field reads in.
public struct EditWatch: Sendable {
    public enum Read: Equatable, Sendable {
        case text(String)
        /// The focused element has no readable text (some apps don't expose it).
        case unreadable
        /// Another app (or nothing) has focus.
        case focusLost
    }

    /// Why a watch never started (kept for diagnostics; no text).
    public enum NotFound: String, Equatable, Sendable {
        /// The field's text can't be read.
        case unreadable
        /// The text is readable, but the paste never showed up in it.
        case textMissing
        /// Focus left the app before the paste was found.
        case focusLost
    }

    public enum Outcome: Equatable, Sendable {
        /// The paste (as the field shows it) and the user's corrected version.
        case corrected(pasted: String, edited: String)
        case unchanged
        case notFound(NotFound)
    }

    /// Between reads when the field says nothing (it usually wakes the watch itself on each change).
    public var interval: Duration = .milliseconds(500)
    /// How long to look for the pasted text before giving up.
    public var findWithin: TimeInterval = 3
    public var settle: TimeInterval = 3
    public var window: TimeInterval = 60

    public init() {}

    public func run(pasted: String, read: @Sendable () async -> Read, wait: @Sendable (Duration) async -> Void,
                    now: @Sendable () -> TimeInterval) async -> Outcome {
        let start = now()
        var found: EditObservation?
        var miss = NotFound.unreadable
        while found == nil {
            switch await read() {
            case .text(let field):
                found = EditObservation(field: field, pasted: pasted)
                miss = .textMissing
            case .unreadable:
                if miss != .textMissing { miss = .unreadable }
            case .focusLost:
                miss = .focusLost
            }
            if found == nil {
                if Task.isCancelled || now() - start >= findWithin { return .notFound(miss) }
                await wait(interval)
            }
        }
        guard var observation = found else { return .notFound(miss) }
        observation.settle = settle
        observation.window = window
        while true {
            await wait(interval)
            let decision: EditObservation.Decision
            if Task.isCancelled {
                decision = observation.end()
            } else {
                switch await read() {
                case .text(let field): decision = observation.observe(field, at: now() - start)
                case .unreadable, .focusLost: decision = observation.end()
                }
            }
            switch decision {
            case .keepWatching: continue
            case .learn(let edited): return .corrected(pasted: observation.pasted, edited: edited)
            case .stop: return .unchanged
            }
        }
    }
}
