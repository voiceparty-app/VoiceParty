import Foundation

/// Word-level diff for the "view changes" window after a Transform.
public enum WordDiff {
    public struct Segment: Equatable, Sendable {
        public enum Kind: Sendable { case same, removed, added }
        public var kind: Kind
        public var text: String
    }

    /// Splits into words keeping their trailing whitespace, so segments re-join into the original text.
    static func tokens(_ text: String) -> [String] {
        var result: [String] = []
        var current = ""
        var inSpace = false
        for ch in text {
            let isSpace = ch.isWhitespace
            if !isSpace && inSpace {
                result.append(current)
                current = ""
            }
            current.append(ch)
            inSpace = isSpace
        }
        if !current.isEmpty { result.append(current) }
        return result
    }

    public static func diff(_ before: String, _ after: String) -> [Segment] {
        let a = tokens(before), b = tokens(after)
        let ka = a.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        let kb = b.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        var table = [[Int]](repeating: [Int](repeating: 0, count: b.count + 1), count: a.count + 1)
        if !a.isEmpty && !b.isEmpty {
            for i in stride(from: a.count - 1, through: 0, by: -1) {
                for j in stride(from: b.count - 1, through: 0, by: -1) {
                    table[i][j] = ka[i] == kb[j] ? table[i + 1][j + 1] + 1 : max(table[i + 1][j], table[i][j + 1])
                }
            }
        }
        var segments: [Segment] = []
        func push(_ kind: Segment.Kind, _ text: String) {
            if let last = segments.last, last.kind == kind {
                segments[segments.count - 1].text += text
            } else {
                segments.append(Segment(kind: kind, text: text))
            }
        }
        var i = 0, j = 0
        while i < a.count || j < b.count {
            if i < a.count, j < b.count, ka[i] == kb[j] {
                push(.same, b[j]); i += 1; j += 1
            } else if i < a.count, j == b.count || table[i + 1][j] >= table[i][j + 1] {
                push(.removed, a[i]); i += 1
            } else {
                push(.added, b[j]); j += 1
            }
        }
        return segments
    }
}
