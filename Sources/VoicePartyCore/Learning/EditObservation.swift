import Foundation

/// Follows one pasted dictation in a text field to see how the user corrected it (the learning half of
/// "Learn words from my corrections"). Only the pasted region counts: the text before and after it at paste time
/// anchor it. The correction is taken when it has settled for a few seconds, when Enter sends it (a
/// trailing newline, or the box empties), when the anchors break, when the watch is ended early (focus moved, the
/// next dictation started) or when the window ends.
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
        let text = Self.normalize(pasted).trimmingCharacters(in: .whitespacesAndNewlines)
        let field = Self.normalize(field)
        guard !text.isEmpty, let range = field.range(of: text, options: .backwards) else { return nil }
        self.pasted = text
        prefix = String(field[..<range.lowerBound])
        suffix = String(field[range.upperBound...])
        lastGood = text
        region = text
    }

    /// Text as editors hand it back, in one shape for comparing: web editors keep paragraphs as blocks (read back
    /// with a single "\n" between them, and one after the last), type non-breaking spaces, and some use other line
    /// separators. A run of line breaks (with the spaces around it) becomes one "\n", other spaces a plain space;
    /// invisible marks are dropped.
    public static func normalize(_ text: String) -> String {
        var out = String.UnicodeScalarView()
        var pendingBreak = false
        var pendingSpaces = String.UnicodeScalarView()
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\n", "\r", "\u{2028}", "\u{2029}", "\u{0B}", "\u{0C}":
                pendingBreak = true
                pendingSpaces.removeAll()
            case " ", "\t", "\u{00A0}", "\u{2007}", "\u{2009}", "\u{200A}", "\u{202F}":
                if !pendingBreak { pendingSpaces.append(scalar == "\t" ? "\t" : " ") }
            case "\u{200B}", "\u{2060}", "\u{FEFF}":
                continue
            default:
                if pendingBreak { out.append("\n") } else { out.append(contentsOf: pendingSpaces) }
                pendingBreak = false
                pendingSpaces.removeAll()
                out.append(scalar)
            }
        }
        if pendingBreak { out.append("\n") } else { out.append(contentsOf: pendingSpaces) }
        return String(out)
    }

    /// How far a correction may stray from the paste before it counts as a rewrite: generous for a few
    /// words, stricter for long text (≈0.6 for tiny pastes, 0.4 at 30 characters, → 0.2).
    public static func distanceLimit(forLength length: Int) -> Double {
        0.2 + 0.4 / (1 + Double(length) / 30)
    }

    public mutating func observe(_ field: String, at time: TimeInterval) -> Decision {
        guard !finished else { return .stop }
        let field = Self.normalize(field)
        // The box emptied (the message was sent: a web editor's empty box reads "\n") or the text around the paste
        // changed: decide with what we have.
        guard !field.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, field.hasPrefix(prefix), field.hasSuffix(suffix),
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

    /// The corrected paste so far (nil while it's as dictated).
    public var correction: String? { lastGood != pasted ? lastGood : nil }

    /// Decide now with what was seen (focus moved, or a new dictation started).
    public mutating func end() -> Decision {
        guard !finished else { return .stop }
        return finish()
    }

    private mutating func finish() -> Decision {
        finished = true
        return lastGood != pasted ? .learn(lastGood) : .stop
    }
}
