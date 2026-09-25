import Foundation

/// Builds the meeting transcript from the two sides.
public enum NoteTranscript {
    /// Interleaves both sides by time. On laptop speakers the mic also hears the other side, so a line of
    /// "You" that repeats an overlapping line of "Others" is an echo and dropped. Back-to-back lines from the
    /// same speaker (a pause under 2 s) are joined.
    public static func merge(mine: [NoteSegment], others: [NoteSegment]) -> [NoteSegment] {
        let own = mine.filter { segment in
            !others.contains { other in
                other.start < segment.end + 2 && segment.start < other.end + 2 && isEcho(segment, of: other)
            }
        }
        var merged: [NoteSegment] = []
        for segment in (own + others).sorted(by: { $0.start < $1.start }) where !segment.text.isEmpty {
            if var last = merged.last, last.speaker == segment.speaker, segment.start - last.end < 2 {
                last.text += " " + segment.text
                last.end = max(last.end, segment.end)
                merged[merged.count - 1] = last
            } else {
                merged.append(segment)
            }
        }
        return merged
    }

    /// Mostly the same words, in order, as what the others said at that moment. Only the part of their turn
    /// around the same time counts: a short "I think so" isn't an echo just because they said it earlier.
    static func isEcho(_ segment: NoteSegment, of other: NoteSegment) -> Bool {
        let a = TextTools.normalizedTokens(segment.text), all = TextTools.normalizedTokens(other.text)
        guard a.count >= 3, !all.isEmpty else { return false }
        let duration = max(other.end - other.start, 0.1)
        let perSecond = Double(all.count) / duration
        let from = max(0, Int(((segment.start - other.start - 2) * perSecond).rounded(.down)))
        let to = min(all.count, Int(((segment.end - other.start + 2) * perSecond).rounded(.up)))
        guard from < to else { return false }
        let b = Array(all[from..<to])
        return Double(TextTools.lcsLength(a, b)) / Double(a.count) >= 0.6
    }

    /// Plain text for the summarizer: one line per turn.
    public static func plainText(_ segments: [NoteSegment]) -> String {
        segments.map { "\($0.speaker.label): \($0.text)" }.joined(separator: "\n")
    }
}
