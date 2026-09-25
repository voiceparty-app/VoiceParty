import Foundation

/// Compares a cleanup result with the expected text (used by the quality benchmarks).
public struct CleanupScore: Sendable, Equatable {
    /// 1 − word error rate over lowercased, punctuation-free words.
    public var wordAccuracy: Double
    /// Character similarity including case, punctuation and line breaks.
    public var formatSimilarity: Double

    public init(output: String, expected: String) {
        let hyp = TextTools.normalizedTokens(output), ref = TextTools.normalizedTokens(expected)
        wordAccuracy = max(0, 1 - Double(Self.editDistance(ref, hyp)) / Double(max(ref.count, 1)))
        formatSimilarity = TextTools.similarity(output.trimmingCharacters(in: .whitespacesAndNewlines),
                                                expected.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    static func editDistance(_ a: [String], _ b: [String]) -> Int {
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var previous = Array(0...b.count)
        for i in 1...a.count {
            var current = [i] + [Int](repeating: 0, count: b.count)
            for j in 1...b.count {
                current[j] = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1))
            }
            previous = current
        }
        return previous[b.count]
    }
}
