import Foundation

/// Follows one pasted dictation in a text field to see how the user corrected it (the learning half of
/// "Learn words from my corrections"). Only the pasted region counts: the text before and after it at paste time
/// anchor it. The correction is taken when it has settled for a few seconds, when Enter sends it (a
/// trailing newline, or the box empties), when the anchors break, or when the window ends.
/// A heavy rewrite isn't a correction: past a distance limit the last light edit is kept instead.
public struct EditObservation: Equatable, Sendable {
    public enum Decision: Equatable, Sendable {
        case keepWatching
        /// The corrected version of the pasted text.
        case learn(String)
        /// Done, nothing to learn.
        case stop
    }

    public let pasted: String
    public var settle: TimeInterval = 3
    public var window: TimeInterval = 60
    private let prefix: String
    private let suffix: String
    private var lastGood: String
    private var region: String
    private var changedAt: TimeInterval?
    private var finished = false

    /// nil when the pasted text isn't in the field (the app changed it, or focus moved).
    public init?(field: String, pasted: String) {
        let text = pasted.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, let range = field.range(of: text, options: .backwards) else { return nil }
        self.pasted = text
        prefix = String(field[..<range.lowerBound])
        suffix = String(field[range.upperBound...])
        lastGood = text
        region = text
    }

    /// How far a correction may stray from the paste before it counts as a rewrite: generous for a few
    /// words, stricter for long text (≈0.6 for tiny pastes, 0.4 at 30 characters, → 0.2).
    public static func distanceLimit(forLength length: Int) -> Double {
        0.2 + 0.4 / (1 + Double(length) / 30)
    }

    public mutating func observe(_ field: String, at time: TimeInterval) -> Decision {
        guard !finished else { return .stop }
        // The box emptied (message sent) or the text around the paste changed: decide with what we have.
        guard !field.isEmpty, field.hasPrefix(prefix), field.hasSuffix(suffix),
              field.count >= prefix.count + suffix.count else { return finish() }
        var current = String(field.dropFirst(prefix.count).dropLast(suffix.count))
        let sent = current.hasSuffix("\n") && !pasted.hasSuffix("\n")
        current = current.trimmingCharacters(in: .whitespacesAndNewlines)
        if current != region {
            region = current
            changedAt = time
            let distance = 1 - TextTools.similarity(current, pasted)
            if distance <= Self.distanceLimit(forLength: pasted.count) { lastGood = current }
        }
        if sent || time >= window { return finish() }
        if let changedAt, time - changedAt >= settle, lastGood != pasted { return finish() }
        return .keepWatching
    }

    private mutating func finish() -> Decision {
        finished = true
        return lastGood != pasted ? .learn(lastGood) : .stop
    }
}
