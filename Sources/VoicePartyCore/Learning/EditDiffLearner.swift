import CryptoKit
import Foundation

/// Learns dictionary words from the user's corrections: after text is pasted, the app watches the
/// field and hands the before/after text here. A word swapped for a similar-looking word the
/// system doesn't know is a spelling the speech engine got wrong.
public struct EditDiffLearner: Sendable {
    /// Returns true for ordinary words that shouldn't be learned (spell-checker backed in the app).
    public var isCommonWord: @Sendable (String) -> Bool
    public var minSimilarity: Double

    /// Fingerprints (`rejectionKey`) of words the user undid after they were learned: never learned again.
    /// Stored as hashes so the words themselves aren't kept in settings or profile exports.
    public var rejected: Set<String>

    /// A one-way, case-insensitive fingerprint of a word.
    public static func rejectionKey(_ word: String) -> String {
        SHA256.hash(data: Data(word.lowercased().utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// Passwords, addresses and codes: letters mixed with digits, "@", or several symbols. A spoken name is
    /// never shaped like that, and learning one would store a secret.
    static func looksLikeSecret(_ word: String) -> Bool {
        let letters = word.filter(\.isLetter).count, digits = word.filter(\.isNumber).count
        let symbols = word.filter { !$0.isLetter && !$0.isNumber && !$0.isWhitespace && !"'’-.".contains($0) }.count
        return word.contains("@") || (letters > 0 && digits > 0) || symbols >= 2
    }
    /// At most this many words from one edit.
    public var maxWords = 4

    public init(minSimilarity: Double = 0.4, rejected: Set<String> = [], isCommonWord: @escaping @Sendable (String) -> Bool = { _ in false }) {
        self.minSimilarity = minSimilarity
        self.rejected = rejected
        self.isCommonWord = isCommonWord
    }

    public struct Correction: Equatable, Sendable {
        public var from: String
        public var to: String
    }

    /// Word-level substitutions between what was pasted and what the user left in the field.
    public func corrections(pasted: String, edited: String) -> [Correction] {
        let a = TextTools.words(pasted).map { String($0).trimmingCharacters(in: .punctuationCharacters) }.filter { !$0.isEmpty }
        let b = TextTools.words(edited).map { String($0).trimmingCharacters(in: .punctuationCharacters) }.filter { !$0.isEmpty }
        guard !a.isEmpty, !b.isEmpty, a.count < 400, b.count < 800 else { return [] }

        // Align with LCS on lowercased words, then pair up the gaps.
        let la = a.map { $0.lowercased() }, lb = b.map { $0.lowercased() }
        var table = [[Int]](repeating: [Int](repeating: 0, count: lb.count + 1), count: la.count + 1)
        for i in stride(from: la.count - 1, through: 0, by: -1) {
            for j in stride(from: lb.count - 1, through: 0, by: -1) {
                table[i][j] = la[i] == lb[j] ? table[i + 1][j + 1] + 1 : max(table[i + 1][j], table[i][j + 1])
            }
        }
        var result: [Correction] = []
        var i = 0, j = 0
        var gapA: [String] = [], gapB: [String] = []
        func flush() {
            if gapA.count == gapB.count {
                for (x, y) in zip(gapA, gapB) where x != y { result.append(Correction(from: x, to: y)) }
            } else if gapA.count == 1 || gapB.count == 1 {
                // "Mikaela" → "Mick Ayla" or "open ai" → "OpenAI": one phrase. Keep only the part of the longer side
                // that resembles the other ("Loopwize" → "It Loopwise" learns "Loopwise", not "It Loopwise").
                let from = gapA.count == 1 ? gapA : Self.closestSpan(in: gapA, to: gapB.joined())
                let to = gapB.count == 1 ? gapB : Self.closestSpan(in: gapB, to: gapA.joined())
                result.append(Correction(from: from.joined(separator: " "), to: to.joined(separator: " ")))
            }
            gapA.removeAll()
            gapB.removeAll()
        }
        while i < la.count || j < lb.count {
            if i < la.count, j < lb.count, la[i] == lb[j] {
                flush()
                if a[i] != b[j] { result.append(Correction(from: a[i], to: b[j])) } // casing fix
                i += 1; j += 1
            } else if j < lb.count, i == la.count || table[i][j + 1] >= table[i + 1][j] {
                gapB.append(b[j]); j += 1
            } else {
                gapA.append(a[i]); i += 1
            }
        }
        flush()
        return result.filter { !$0.from.isEmpty && !$0.to.isEmpty }
    }

    /// The run of up to three consecutive words that is spelled most like `target` (spaces ignored).
    static func closestSpan(in words: [String], to target: String) -> [String] {
        let goal = target.lowercased()
        var best = words, bestScore = -1.0
        for start in words.indices {
            for end in start..<min(words.count, start + 3) {
                let span = Array(words[start...end])
                let score = TextTools.similarity(span.joined().lowercased(), goal)
                if score > bestScore { best = span; bestScore = score }
            }
        }
        return best
    }

    /// Corrections worth adding to the dictionary.
    public func learnedWords(pasted: String, edited: String) -> [String] {
        var seen = Set<String>()
        return corrections(pasted: pasted, edited: edited).compactMap { c in
            let target = c.to
            guard target.count >= 2, target.count <= 40, target.contains(where: \.isLetter) else { return nil }
            let similar = TextTools.similarity(c.from.lowercased(), target.lowercased()) >= minSimilarity
            let casingOnly = c.from.lowercased() == target.lowercased()
            guard similar || casingOnly else { return nil }
            // "tomorrow" → "tmrw", "please" → "pls": shorthand, not a spelling to learn.
            guard Double(target.count) >= 0.7 * Double(c.from.count) else { return nil }
            // "Q3" → "Q4": a different number, not a different spelling.
            if c.from.filter({ !$0.isNumber }) == target.filter({ !$0.isNumber }) { return nil }
            // "us" → "US" or "it" → "IT" once shouldn't force that casing everywhere.
            if casingOnly && (isCommonWord(target.lowercased()) || CommonWords.contains(target)) { return nil }
            guard !isCommonWord(target) || casingOnly && target.dropFirst().contains(where: \.isUppercase) else { return nil }
            // "Sam's", "don't": a contraction or possessive, not a new word.
            let lower = target.lowercased().replacingOccurrences(of: "’", with: "'")
            guard !["'s", "'t", "'ll", "'ve", "'re", "'d", "'m"].contains(where: { lower.hasSuffix($0) }) else { return nil }
            guard !Self.looksLikeSecret(target), !rejected.contains(Self.rejectionKey(lower)), seen.insert(lower).inserted else { return nil }
            return target
        }.prefix(maxWords).map { $0 }
    }
}
