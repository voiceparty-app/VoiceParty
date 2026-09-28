import Foundation

/// Applies the per-category writing style after cleanup.
public struct StyleFormatter: Sendable {
    /// Words that must keep their capitalization (dictionary words, names).
    public var protectedWords: Set<String>

    public init(protectedWords: Set<String> = []) {
        self.protectedWords = protectedWords
    }

    public func apply(_ style: WritingStyle, to text: String, addTerminalPunctuation: Bool = true) -> String {
        guard !text.isEmpty else { return text }
        switch style {
        case .formal:
            let capitalized = TextTools.capitalizingFirstLetter(text)
            return addTerminalPunctuation ? ensureTerminalPunctuation(capitalized) : capitalized
        case .casual:
            return dropTrailingPeriod(TextTools.capitalizingFirstLetter(text))
        case .veryCasual:
            return dropTrailingPeriod(lowercaseSentenceStarts(text))
        case .excited:
            var out = TextTools.capitalizingFirstLetter(text)
            if out.hasSuffix(".") && !out.hasSuffix("..") { out.removeLast(); out += "!" }
            return out
        }
    }

    func ensureTerminalPunctuation(_ text: String) -> String {
        guard let last = text.last else { return text }
        let lastLine = text.split(separator: "\n").last.map(String.init) ?? text
        let isListItem = lastLine.range(of: #"^\s*(?:[-•*]|\d+[.)])\s"#, options: .regularExpression) != nil
        if isListItem || ".!?:;…)\"'`".contains(last) || last.isEmoji || lastLine.contains("://") { return text }
        guard last.isLetter || last.isNumber else { return text }
        if Self.isSignature(lastLine, in: text) { return text }
        return text + "."
    }

    /// A name on its own line under a sign-off ("Thanks,\nPriya") or alone after a blank line ("…\n\nSam"): no period.
    static func isSignature(_ lastLine: String, in text: String) -> Bool {
        let words = lastLine.split(separator: " ")
        guard (1...3).contains(words.count), words.allSatisfy({ $0.first?.isUppercase == true && $0.allSatisfy { $0.isLetter || "'’-".contains($0) } })
        else { return false }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).dropLast()
        guard let previous = lines.last else { return false }
        if previous.trimmingCharacters(in: .whitespaces).isEmpty { return words.count == 1 }
        return previous.hasSuffix(",")
    }

    func dropTrailingPeriod(_ text: String) -> String {
        guard text.hasSuffix("."), !text.hasSuffix("..") else { return text }
        let lastWord = TextTools.words(text).last.map(String.init) ?? ""
        // Keep periods that belong to abbreviations like "etc." or "U.S.".
        if ["etc.", "e.g.", "i.e.", "vs."].contains(lastWord.lowercased()) || lastWord.dropLast().contains(".") { return text }
        return String(text.dropLast())
    }

    func lowercaseSentenceStarts(_ text: String) -> String {
        guard let re = TextTools.regex(#"(^|[.!?]\s+|\n\s*)(\p{Lu})([\p{L}'’]*)"#, caseInsensitive: false) else { return text }
        let ns = text as NSString
        var out = text
        for match in re.matches(in: text, range: NSRange(location: 0, length: ns.length)).reversed() {
            let first = ns.substring(with: match.range(at: 2))
            let rest = ns.substring(with: match.range(at: 3))
            let word = first + rest
            let isPronounI = word == "I" || word.hasPrefix("I'") || word.hasPrefix("I’")
            let isAcronym = word.count > 1 && word == word.uppercased()
            let hasInnerCaps = rest.contains(where: \.isUppercase)
            if isPronounI || isAcronym || hasInnerCaps || protectedWords.contains(word) { continue }
            if let range = Range(match.range(at: 2), in: out) {
                out.replaceSubrange(range, with: first.lowercased())
            }
        }
        return out
    }
}

extension Character {
    var isEmoji: Bool {
        unicodeScalars.contains { $0.properties.isEmojiPresentation || ($0.properties.isEmoji && $0.value > 0x238C) }
    }
}
