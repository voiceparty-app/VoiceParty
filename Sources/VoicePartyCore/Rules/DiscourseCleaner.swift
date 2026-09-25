import Foundation

/// Removes discourse fillers: sentence-opening "So", "And", "Okay so", "Like", "Basically", plus
/// "you know" / "like" / "basically" when they're set off as fillers. Deterministic, so it works the
/// same after any model (4B models don't follow fine-grained filler rules reliably) or with rules only.
public struct DiscourseCleaner: Sendable {
    public init() {}

    /// Opener → replacement. Checked longest first; `nil` when the next word makes it meaningful.
    static let openers: [(phrase: String, replacement: String)] = [
        ("okay so", ""), ("ok so", ""), ("yeah so", "Yeah, "), ("and so", ""), ("and then", "Then "),
        ("so basically", ""), ("so like", ""), ("basically", ""), ("so", ""), ("like", ""), ("and", ""),
    ]
    /// Words after an opener that make it meaningful ("So far", "So that…", "Like I said", "And yet").
    static let keepAfter: [String: Set<String>] = [
        "so": ["far", "that", "much", "many", "long", "yes", "no", "what", "then", "yeah", "to", "sorry", "glad", "happy", "excited",
               "good", "great", "close", "cool", "nice", "proud", "tired", "busy", "bad", "sure", "grateful", "thankful", "true"],
        "like": ["i", "we", "you", "he", "she", "they", "this", "that", "these", "those", "when", "if", "a", "the"],
        "and": ["yet", "so", "also"],
    ]

    public func clean(_ text: String) -> String {
        var out = removeHesitations(text)
        out = removeSetOffFillers(out)
        out = removeSentenceOpeners(out)
        out = TextTools.replacing(out, pattern: #"[ \t]{2,}"#, with: " ")
        out = TextTools.replacing(out, pattern: #"\s+([,.!?;:])(?=\s|$)"#, with: "$1")
        out = TextTools.replacing(out, pattern: #",\s*([.!?])"#, with: "$1")
        return out.trimmingCharacters(in: .whitespaces)
    }

    /// Words before a bare "m" that make it a real letter or size ("plan m", "the letter m", "size m").
    static let letterContexts: Set<String> = ["letter", "plan", "vitamin", "size", "option", "type", "grade", "class",
                                              "section", "model", "row", "column", "key", "button", "shift", "command"]

    /// Words a hesitation "m" typically follows ("the m apps", "like m missing"). After anything else a bare
    /// "m" is more likely meant: a variable ("set m to"), a unit ("ten mm"), a letter.
    static let hesitationLeads: Set<String> = ["the", "a", "an", "like", "is", "was", "uh", "um", "and", "but", "so", "of", "this",
                                               "that", "it's", "i", "we", "you", "they", "just", "maybe", "kind", "sort", "some", "my"]

    /// Parakeet writes a drawn-out "mmm" as a bare "m" ("the m uh apps"); "hm"/"mhm" are hesitations too.
    /// Lowercase only (an uppercase M is an initial); never part of a flag, path or hyphenated word ("-m", "mm-hmm").
    func removeHesitations(_ text: String) -> String {
        guard let re = TextTools.regex(#"(?<![\p{L}\p{N}'’&.\-_/])(?:m{1,3}|[hH]m+|[mM]h+m+)(?![\p{L}\p{N}'’&\-_/])[,]?[ \t]*"#, caseInsensitive: false)
        else { return text }
        let ns = text as NSString
        var out = text
        for match in re.matches(in: text, range: NSRange(location: 0, length: ns.length)).reversed() {
            let token = ns.substring(with: match.range).trimmingCharacters(in: CharacterSet(charactersIn: ", \t"))
            let before = ns.substring(to: match.range.location).split(whereSeparator: { $0 == " " || $0 == "\t" }).last.map(String.init) ?? ""
            if token.first == "m", token.allSatisfy({ $0 == "m" }) {
                // A bare m is a hesitation only after a word it typically follows (or when set off by a comma).
                let setOff = ns.substring(with: match.range).contains(",")
                let lead = before.lowercased().trimmingCharacters(in: .punctuationCharacters)
                if before.last?.isNumber == true || Self.letterContexts.contains(lead) { continue }
                if !setOff && !Self.hesitationLeads.contains(lead) { continue }
            }
            // "Hm, that's odd." → "That's odd."
            let atStart = match.range.location == 0 || before.last.map { ".!?\n".contains($0) } == true
            guard let range = Range(match.range, in: out) else { continue }
            out.replaceSubrange(range, with: "")
            if atStart, let first = out[range.lowerBound...].first, first.isLowercase {
                out.replaceSubrange(range.lowerBound...range.lowerBound, with: String(first).uppercased())
            }
        }
        return out
    }

    /// "are, you know, too narrow" → "are too narrow"; "done, you know." → "done."; "basically done" → "done".
    func removeSetOffFillers(_ text: String) -> String {
        var out = text
        for filler in ["you know", "like", "basically", "I mean"] {
            // Between commas: drop the filler and both commas.
            out = TextTools.replacing(out, pattern: #",\s*\b"# + filler + #"\b\s*,\s*"#, with: " ")
            // Trailing: ", you know." → "." — but "…, you know?" is a real question, and "If you know, you know." is
            // a saying.
            out = TextTools.replacing(out, pattern: #"(?<!if you know),\s*\b"# + filler + #"\b(?=\s*[.!]|\s*$)"#, with: "")
        }
        // "basically" is almost never meaningful mid-sentence.
        out = TextTools.replacing(out, pattern: #"(?<=\w)\s+basically\s+(?=\w)"#, with: " ")
        out = TextTools.replacing(out, pattern: #"\blike,?\s+like\b(?!-)"#, with: "like")
        return out
    }

    func removeSentenceOpeners(_ text: String) -> String {
        guard let re = TextTools.regex(#"(^|[.!?]\s+|\n\s*)([^\n]*?)(?=[.!?](?:\s|$)|\n|$)"#) else { return text }
        let ns = text as NSString
        var out = text
        for match in re.matches(in: text, range: NSRange(location: 0, length: ns.length)).reversed() {
            let sentenceRange = match.range(at: 2)
            guard sentenceRange.length > 0, let range = Range(sentenceRange, in: out) else { continue }
            out.replaceSubrange(range, with: stripOpener(String(out[range])))
        }
        return out
    }

    func stripOpener(_ sentence: String) -> String {
        var current = sentence
        // Several fillers can stack ("Okay so basically …").
        for _ in 0..<3 {
            let lower = current.lowercased()
            var changed = false
            for (phrase, replacement) in Self.openers {
                guard lower.hasPrefix(phrase) else { continue }
                var rest = current.dropFirst(phrase.count)
                guard let first = rest.first, first == " " || first == "," else { continue }
                let setOffByComma = first == ","
                rest = rest.drop { $0 == "," || $0 == " " }
                let restWords = rest.split(separator: " ")
                guard restWords.count >= 2 else { continue } // "I think so." / short replies stay
                let nextWord = restWords.first.map { $0.lowercased().trimmingCharacters(in: .punctuationCharacters) } ?? ""
                if !setOffByComma, Self.keepAfter[phrase]?.contains(nextWord) == true { continue }
                // "Like most people…", "Like button…": only a comma marks "Like" as a filler.
                if phrase == "like" && !setOffByComma { continue }
                if phrase == "you know" || nextWord == "what" { continue }
                let body = TextTools.capitalizingFirstLetter(String(rest))
                current = replacement.isEmpty ? body : replacement + lowercaseFirst(body)
                changed = true
                break
            }
            if !changed { break }
        }
        return current
    }

    private func lowercaseFirst(_ text: String) -> String {
        guard let first = text.first, first.isUppercase else { return text }
        let word = text.prefix { !$0.isWhitespace }
        // Keep "I", acronyms and names-like words capitalized.
        if word == "I" || word.hasPrefix("I'") || word.hasPrefix("I’") || word.dropFirst().contains(where: \.isUppercase) { return text }
        return first.lowercased() + text.dropFirst()
    }
}
