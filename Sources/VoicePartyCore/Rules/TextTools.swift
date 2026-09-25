import Foundation

/// Small text utilities shared by the rules, learner, and stats.
public enum TextTools {
    public static func words(_ text: String) -> [Substring] {
        text.split { $0.isWhitespace || $0.isNewline }
    }

    public static func wordCount(_ text: String) -> Int {
        words(text).filter { $0.contains(where: { $0.isLetter || $0.isNumber }) }.count
    }

    /// Lowercased word tokens with surrounding punctuation stripped.
    public static func normalizedTokens(_ text: String) -> [String] {
        words(text).map { normalizeWord(String($0)) }.filter { !$0.isEmpty }
    }

    public static func normalizeWord(_ word: String) -> String {
        word.lowercased().trimmingCharacters(in: .punctuationCharacters.union(.symbols))
    }

    /// Lowercase, punctuation removed, whitespace collapsed — for comparing phrases.
    public static func normalizePhrase(_ text: String) -> String {
        normalizedTokens(text).joined(separator: " ")
    }

    public static func levenshtein(_ a: String, _ b: String) -> Int {
        let a = Array(a), b = Array(b)
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var previous = Array(0...b.count)
        var current = [Int](repeating: 0, count: b.count + 1)
        for i in 1...a.count {
            current[0] = i
            for j in 1...b.count {
                current[j] = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1))
            }
            swap(&previous, &current)
        }
        return previous[b.count]
    }

    /// 0…1 similarity based on edit distance.
    public static func similarity(_ a: String, _ b: String) -> Double {
        let longest = max(a.count, b.count)
        guard longest > 0 else { return 1 }
        return 1 - Double(levenshtein(a, b)) / Double(longest)
    }

    /// Length of the longest common subsequence of two token lists.
    public static func lcsLength(_ a: [String], _ b: [String]) -> Int {
        guard !a.isEmpty, !b.isEmpty else { return 0 }
        var previous = [Int](repeating: 0, count: b.count + 1)
        var current = previous
        for i in 1...a.count {
            for j in 1...b.count {
                current[j] = a[i - 1] == b[j - 1] ? previous[j - 1] + 1 : max(previous[j], current[j - 1])
            }
            swap(&previous, &current)
        }
        return previous[b.count]
    }

    /// Regex fragment matching `phrase` as whole words, tolerant of case, spacing and hyphens between words.
    public static func wholePhrasePattern(_ phrase: String) -> String? {
        let parts = words(phrase).map { NSRegularExpression.escapedPattern(for: String($0)) }
        guard !parts.isEmpty else { return nil }
        let body = parts.joined(separator: #"[\s\-]+"#)
        // Whole words only, and never part of an identifier, path, address or domain
        // ("tamaro_client", "/srv/tamaro/", "sam@tamaro.com"); a sentence-ending period is fine.
        return #"(?<![\p{L}\p{N}_/@.\\])"# + body + #"(?![\p{L}\p{N}_/@\\]|\.[\p{L}\p{N}])"#
    }

    private static let cacheLock = NSLock()
    nonisolated(unsafe) private static var cache: [String: NSRegularExpression] = [:]

    /// Compiled once and reused (a dictionary of hundreds of entries used to recompile every dictation).
    public static func regex(_ pattern: String, caseInsensitive: Bool = true) -> NSRegularExpression? {
        let key = (caseInsensitive ? "i:" : "c:") + pattern
        if let cached = cacheLock.withLock({ cache[key] }) { return cached }
        guard let compiled = try? NSRegularExpression(pattern: pattern, options: caseInsensitive ? [.caseInsensitive] : []) else { return nil }
        cacheLock.withLock {
            if cache.count > 5_000 { cache.removeAll() }
            cache[key] = compiled
        }
        return compiled
    }

    /// The capture groups of every match (group 1 onward).
    public static func matches(of pattern: String, in text: String, caseInsensitive: Bool = true) -> [[String]] {
        guard let re = regex(pattern, caseInsensitive: caseInsensitive) else { return [] }
        let ns = text as NSString
        return re.matches(in: text, range: NSRange(location: 0, length: ns.length)).map { match in
            (1..<max(match.numberOfRanges, 1)).map { match.range(at: $0).location == NSNotFound ? "" : ns.substring(with: match.range(at: $0)) }
        }
    }

    public static func replacing(_ text: String, pattern: String, with template: String, caseInsensitive: Bool = true) -> String {
        guard let re = regex(pattern, caseInsensitive: caseInsensitive) else { return text }
        return re.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: template)
    }

    /// Capitalizes the first word only when it's a plain lowercase word — never "iPhone", "macOS",
    /// "3rd", URLs or paths.
    public static func capitalizingFirstLetter(_ text: String) -> String {
        guard let start = text.firstIndex(where: { !$0.isWhitespace && !"\"'“‘(".contains($0) }) else { return text }
        let word = text[start...].prefix { !$0.isWhitespace }
        guard let first = word.first, first.isLetter, first.isLowercase,
              !word.contains(where: \.isUppercase), !word.contains(where: \.isNumber),
              !word.contains("://"), !word.contains("/"), !word.contains("@") else { return text }
        return text.replacingCharacters(in: start...start, with: String(first).uppercased())
    }
}
