import Foundation

/// Breaks long dictations into paragraphs: never under ~120 words, paragraphs of a few sentences (~70 words),
/// preferring to break where the speaker changes topic ("Another thing…", "Regarding…", "I also…") and never
/// right before a sentence that continues the last one ("And…", "Because…", "It…"). Deterministic: a small
/// language model placed breaks less reliably than these rules.
public struct Paragrapher: Sendable {
    public var minWords = 120
    public var targetWords = 70
    public var cueWords = 28
    public var maxWords = 130
    /// Don't leave a last paragraph shorter than this.
    public var minTailWords = 18

    public init() {}

    /// Openers that usually start a new topic.
    static let topicShifts = [
        "another thing", "the other thing", "regarding", "as far as", "now for", "i also", "that leads", "essentially what",
        "first of all", "the second", "secondly", "lastly", "finally", "in addition", "on top of that", "additionally",
        "moving on", "separately", "also,", "also ", "one more thing", "the last thing", "by the way", "anyway", "oh and",
        "the reason", "the idea", "for example", "for the", "now,", "now the", "now we", "overall", "in terms of", "with that",
    ]
    /// Openers that continue the previous sentence: never start a paragraph there.
    static let continuations = ["and ", "but ", "because ", "so ", "which ", "or ", "that's why", "then ", "it ", "this ", "that ",
                                "they ", "he ", "she "]

    public func apply(_ text: String) -> String {
        guard TextTools.wordCount(text) >= minWords else { return text }
        guard text.contains("\n") else { return split(text) }
        // A list was asked for: leave that layout alone.
        if let list = TextTools.regex(#"(?m)^\s*(?:[-•*]|\d+[.)])\s+\S"#), list.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil {
            return text
        }
        // Keep the breaks that are there ("new paragraph", or the model's) and split only lines still too long.
        return text.components(separatedBy: "\n").map(split).joined(separator: "\n")
    }

    private func split(_ text: String) -> String {
        guard TextTools.wordCount(text) >= minWords else { return text }
        let sentences = Self.sentences(in: text)
        guard sentences.count >= 4 else { return text }
        let counts = sentences.map(TextTools.wordCount)
        var paragraphs: [[String]] = [[]]
        var words = 0
        for (index, sentence) in sentences.enumerated() {
            if paragraphs[paragraphs.count - 1].count >= 2 {
                let opener = sentence.lowercased().drop { "\"'(“".contains($0) }
                let shift = Self.topicShifts.contains { opener.hasPrefix($0) }
                let continues = Self.continuations.contains { opener.hasPrefix($0) }
                let remaining = counts[index...].reduce(0, +)
                if remaining >= minTailWords,
                   (shift && words >= cueWords) || (words >= targetWords && !continues) || words >= maxWords {
                    paragraphs.append([])
                    words = 0
                }
            }
            paragraphs[paragraphs.count - 1].append(sentence)
            words += counts[index]
        }
        return paragraphs.map { $0.joined(separator: " ") }.joined(separator: "\n\n")
    }

    /// Sentences, ending in . ! or ? followed by a capitalized word (so "e.g. linters" isn't a break).
    public static func sentences(in text: String) -> [String] {
        guard let re = TextTools.regex(#"(?<=[.!?])\s+(?=["'“(]?\p{Lu})"#, caseInsensitive: false) else { return [text] }
        let ns = text as NSString
        var result: [String] = []
        var start = 0
        for match in re.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            // "Dr. Smith", "J. R. Hartley": a title or an initial doesn't end the sentence.
            let before = ns.substring(with: NSRange(location: start, length: match.range.location - start))
            let lastWord = before.split(whereSeparator: \.isWhitespace).last.map(String.init) ?? ""
            if RuleBasedCleaner.abbreviations.contains(lastWord.lowercased())
                || (lastWord.count == 2 && lastWord.first?.isUppercase == true) { continue }
            result.append(ns.substring(with: NSRange(location: start, length: match.range.location - start)))
            start = match.range.location + match.range.length
        }
        result.append(ns.substring(from: start))
        return result.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }
}
