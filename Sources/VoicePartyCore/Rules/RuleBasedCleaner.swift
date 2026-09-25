import Foundation

/// Deterministic cleanup. Runs when the language model is off, unavailable, rejected by the drift
/// guard, or the utterance is too short to be worth it. Also tidies language-model output.
public struct RuleBasedCleaner: Sendable {
    public init() {}

    /// Spoken commands that apply at every cleanup level: "new line", "new paragraph", "scratch that".
    /// `resolveRetractions: false` leaves "actually no" / "scratch that" for a language model, which
    /// keeps what the speaker still meant ("send the report to John, actually no, Jane" → "the report to Jane").
    public func applyVoiceCommands(_ text: String, resolveRetractions: Bool = true) -> String {
        var out = text
        out = SpokenQuotes.apply(out)
        out = Self.shortenEtCetera(out)
        out = replaceBreakCommand(out, spoken: "paragraph", with: "\n\n")
        out = replaceBreakCommand(out, spoken: "line", with: "\n")
        if resolveRetractions { out = removeRetractions(out) }
        out = capitalizeLineStarts(out)
        return out
    }

    public func clean(_ text: String, level: CleanupLevel) -> String {
        var out = text
        if level != .none {
            out = removeFillers(out)
            out = collapseStutters(out)
            out = formatSpokenList(out)
        }
        out = tidyWhitespaceAndPunctuation(out)
        if level != .none {
            out = TextTools.capitalizingFirstLetter(out)
        }
        return out
    }

    // MARK: - Rules

    /// "et cetera" → "etc." (never the other way round).
    public static func shortenEtCetera(_ text: String) -> String {
        TextTools.replacing(text, pattern: #"\bet[ \t-]?cetera\b\.?"#, with: "etc.")
    }

    /// "new line" / "new paragraph" as commands — but not "a new line of shoes".
    func replaceBreakCommand(_ text: String, spoken: String, with replacement: String) -> String {
        guard let re = TextTools.regex(#"[ \t]*[,;:]?[ \t]*\bnew[ \t]+"# + spoken + #"\b[,.;:!?]?[ \t]*"#) else { return text }
        let ns = text as NSString
        var out = text
        for match in re.matches(in: text, range: NSRange(location: 0, length: ns.length)).reversed() {
            let before = ns.substring(to: match.range.location)
            let previousWord = before.split(whereSeparator: { $0.isWhitespace }).last.map { $0.lowercased() } ?? ""
            let after = ns.substring(from: match.range.location + match.range.length).lowercased()
            let determiners: Set<String> = ["a", "the", "another", "our", "their", "this", "that", "these", "those", "your", "my",
                                            "every", "each", "any", "some", "his", "her", "its", "per", "no", "added", "add", "strip",
                                            "remove", "insert", "with", "without"]
            // "new line items", "new line characters": part of a noun, not a command.
            let nouns = ["item", "character", "char", "break", "manager", "feed", "ending", "separator", "delimiter", "number", "code", "symbol"]
            let nextWord = after.split(whereSeparator: { $0.isWhitespace }).first.map(String.init) ?? ""
            if determiners.contains(previousWord) || after.hasPrefix("of ") || after.hasPrefix("in ")
                || nouns.contains(where: { nextWord.hasPrefix($0) }) { continue }
            if let range = Range(match.range, in: out) { out.replaceSubrange(range, with: replacement) }
        }
        return out
    }

    /// Phrases that retract what came just before. Plain "actually" or "no" are too common to trust.
    static let retractionPattern = #"[,;]?\s*\b(?:scratch that|delete that|actually no|no actually|no wait|wait no)\b(?=\s*[.,!;:]|\s*$)[.,!;:]?\s*"#

    /// Deletes what a retraction phrase cancels: the previous sentence when the phrase starts a sentence
    /// ("Meet at five. Actually no, six."), or the clause before it in the same sentence ("Call Mike, no wait, call Priya").
    /// The phrase must be followed by punctuation or the end, so "I actually no longer work there" is untouched.
    /// Words right before "delete that" / "no wait" that make them ordinary speech ("I'll delete that",
    /// "there was no wait", "told him to delete that").
    static let nonCommandLeads: Set<String> = ["to", "i'll", "ill", "i", "we", "you", "they", "he", "she", "will", "can", "could",
                                               "should", "would", "please", "was", "is", "there", "no", "just", "don't", "didn't",
                                               "not", "let's", "gonna", "must", "might", "we'll", "you'll", "i'd", "we'd"]
    /// A reply after "Actually no," ("we're on track") answers something; it doesn't replace it.
    static let pronounStarts: Set<String> = ["i", "we", "you", "he", "she", "they", "it", "i'm", "we're", "you're", "they're", "it's",
                                             "that's", "there's", "we've", "i've", "that", "this", "there"]

    func removeRetractions(_ text: String) -> String {
        guard let re = TextTools.regex(Self.retractionPattern) else { return text }
        var out = text
        var searchFrom = out.startIndex
        while let match = re.firstMatch(in: out, range: NSRange(searchFrom..., in: out)),
              let range = Range(match.range, in: out) {
            let suffixWords = out[range.upperBound...].split(whereSeparator: { $0.isWhitespace || ".,!?;:".contains($0) })
            let leadWord = out[..<range.lowerBound].split(whereSeparator: { $0.isWhitespace || ",;".contains($0) }).last
                .map { $0.lowercased().replacingOccurrences(of: "’", with: "'") } ?? ""
            let firstSuffix = suffixWords.first.map { $0.lowercased().replacingOccurrences(of: "’", with: "'") } ?? ""
            // Only a correction when the phrase is used as a command, and (except "scratch that", which always is
            // one) something replaces what was retracted.
            let phrase = String(out[range]).lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ",;.!?: \t"))
            let needsReplacement = !phrase.hasPrefix("scratch that")
            if (needsReplacement && suffixWords.isEmpty) || Self.nonCommandLeads.contains(leadWord)
                || (needsReplacement && Self.pronounStarts.contains(firstSuffix)) {
                searchFrom = range.upperBound
                continue
            }
            let before = out[..<range.lowerBound]
            var end = before.endIndex
            while end > before.startIndex, " \t,;.!?".contains(before[before.index(before: end)]) {
                end = before.index(before: end)
            }
            let core = before[..<end]
            let sentenceStart = core.lastIndex(where: { ".!?\n".contains($0) }).map { core.index(after: $0) } ?? before.startIndex
            let prefix = out[..<sentenceStart]
            let suffix = out[range.upperBound...]
            let joiner = prefix.isEmpty || prefix.last?.isNewline == true || suffix.isEmpty ? "" : " "
            let kept = String(prefix).trimmingCharacters(in: .whitespaces) + joiner
            out = kept + suffix
            searchFrom = out.index(out.startIndex, offsetBy: kept.count)
        }
        return TextTools.capitalizingFirstLetter(out.trimmingCharacters(in: .whitespaces))
    }

    /// "first X second Y and third Z" → a numbered list (needs first, second and third, in order).
    func formatSpokenList(_ text: String) -> String {
        let ordinals = ["first", "second", "third", "fourth", "fifth", "sixth"]
        guard let re = TextTools.regex(#"(?<![\p{L}])(first|second|third|fourth|fifth|sixth)(?:ly)?\b[,:]?\s*"#) else { return text }
        let ns = text as NSString
        let matches = re.matches(in: text, range: NSRange(location: 0, length: ns.length))
        var sequence: [NSTextCheckingResult] = []
        let determiners: Set<String> = ["my", "the", "a", "his", "her", "our", "their", "your", "its", "this", "that", "at"]
        for match in matches {
            let word = ns.substring(with: match.range(at: 1)).lowercased()
            let previous = ns.substring(to: match.range.location).split(whereSeparator: { $0.isWhitespace || $0 == "," }).last
                .map { $0.lowercased() } ?? ""
            let next = ns.substring(from: match.range.location + match.range.length).split(separator: " ").first
                .map { $0.lowercased().trimmingCharacters(in: .punctuationCharacters) } ?? ""
            // "my first job", "the second time", "first of all" are prose, not list markers.
            if determiners.contains(previous) || ["time", "place", "of", "one", "half"].contains(next) { continue }
            if word == ordinals[sequence.count] { sequence.append(match) }
            if sequence.count == ordinals.count { break }
        }
        guard sequence.count >= 3 else { return text }
        let intro = ns.substring(to: sequence[0].range.location)
            .trimmingCharacters(in: CharacterSet(charactersIn: " \t,;:"))
        var items: [String] = []
        for (i, match) in sequence.enumerated() {
            let start = match.range.location + match.range.length
            let end = i + 1 < sequence.count ? sequence[i + 1].range.location : ns.length
            var item = ns.substring(with: NSRange(location: start, length: end - start))
                .trimmingCharacters(in: CharacterSet(charactersIn: " \t,;.!"))
            if item.lowercased().hasSuffix(" and") { item = String(item.dropLast(4)) }
            item = item.trimmingCharacters(in: CharacterSet(charactersIn: " \t,;."))
            guard !item.isEmpty else { return text }
            items.append(TextTools.capitalizingFirstLetter(item))
        }
        let list = items.enumerated().map { "\($0.offset + 1). \($0.element)" }.joined(separator: "\n")
        return intro.isEmpty ? list : TextTools.capitalizingFirstLetter(intro) + ":\n" + list
    }

    static let abbreviations: Set<String> = ["vs.", "etc.", "mr.", "mrs.", "ms.", "dr.", "st.", "approx.", "no.", "jr.", "sr.", "inc.", "co."]

    func removeFillers(_ text: String) -> String {
        let fillers = #"(?:u+m+|u+h+m*|e+r+m+|hmm+)"#
        var out = text
        // A filler that opened a sentence: the next word now starts it ("week. Um this" → "week. This").
        if let re = TextTools.regex(#"(?<=[.!?][ \t])(?-i:(?!UM|UH|ERM|HMM))"# + fillers + #"(?![\p{L}\p{N}'\-])[,]?[ \t]*(\p{Ll})"#, caseInsensitive: true) {
            let ns = out as NSString
            for match in re.matches(in: out, range: NSRange(location: 0, length: ns.length)).reversed() {
                // "e.g. um tools" / "vs. uh them": the period ended an abbreviation, not a sentence.
                let before = ns.substring(to: match.range.location).split(whereSeparator: \.isWhitespace).last.map(String.init) ?? ""
                if before.dropLast().contains(".") || Self.abbreviations.contains(before.lowercased()) { continue }
                let letter = ns.substring(with: match.range(at: 1)).uppercased()
                if let range = Range(match.range, in: out) { out.replaceSubrange(range, with: letter) }
            }
        }
        // Filler with its trailing comma, anywhere in the text — but not part of a hyphenated word ("uh-oh",
        // "mm-hmm") and not an acronym in capitals ("ERM", "HMM", "UM").
        if let re = TextTools.regex(#"(?<![\p{L}\p{N}'\-])"# + fillers + #"(?![\p{L}\p{N}'\-])[,]?[ \t]*"#) {
            let ns = out as NSString
            for match in re.matches(in: out, range: NSRange(location: 0, length: ns.length)).reversed() {
                let word = ns.substring(with: match.range).trimmingCharacters(in: CharacterSet(charactersIn: ", \t"))
                if word.count >= 2 && word == word.uppercased() { continue }
                if let range = Range(match.range, in: out) { out.replaceSubrange(range, with: "") }
            }
        }
        // A comma left dangling before end-of-sentence punctuation.
        out = TextTools.replacing(out, pattern: #",\s*([.!?])"#, with: "$1")
        return Self.removeFalseStartLetters(out)
    }

    /// A word cut off after its first sound, written as a lone letter: "launch a s sub agent" → "launch a sub agent".
    /// Only right after a little word ("a", "to", "the"…), so "type c cable", "vitamin c", "plan b" stay.
    static func removeFalseStartLetters(_ text: String) -> String {
        TextTools.replacing(text, pattern: #"(?<![\p{L}\p{N}\-])((?i:a|an|the|to|of|for|and|or|but|that|this|some|my|your|our|in|on|with))[ \t]+([b-hj-z])[ \t]+(?=\2\p{L})"#,
                            with: "$1 ", caseInsensitive: false)
    }

    /// Short function words that only repeat by accident ("the the", "I I think"). Content words are left
    /// alone: "testing testing", "very very" and "no no no" are usually intentional.
    static let stutterWords: Set<String> = [
        "the", "a", "an", "i", "to", "and", "of", "for", "we", "you", "it", "my", "our", "your",
        "but", "so", "with", "be", "this", "they", "he", "she", "or", "if", "as", "just", "was", "are",
    ]

    /// "the the" → "the", for accidental repeats of function words only.
    func collapseStutters(_ text: String) -> String {
        // Same case only ("option A, a cheaper plan" is two different words), and a comma only between longer words.
        guard let re = TextTools.regex(#"\b([\p{L}']+)(?:[ \t]*,?[ \t]+\1\b)+"#, caseInsensitive: false) else { return text }
        let ns = text as NSString
        var out = text
        for match in re.matches(in: text, range: NSRange(location: 0, length: ns.length)).reversed() {
            let word = ns.substring(with: match.range(at: 1))
            guard Self.stutterWords.contains(word.lowercased()) else { continue }
            if word.count == 1 && ns.substring(with: match.range).contains(",") { continue }
            if let range = Range(match.range, in: out) {
                out.replaceSubrange(range, with: word)
            }
        }
        return out
    }

    func tidyWhitespaceAndPunctuation(_ text: String) -> String {
        var out = text
        out = TextTools.replacing(out, pattern: #"[ \t]{2,}"#, with: " ")
        out = TextTools.replacing(out, pattern: #"[ \t]+([,.!?;:])(?=\s|$)"#, with: "$1")
        out = TextTools.replacing(out, pattern: #",\s*,"#, with: ",")
        out = TextTools.replacing(out, pattern: #",\."#, with: ".")
        out = TextTools.replacing(out, pattern: #"^[\s,;:]+"#, with: "")
        out = TextTools.replacing(out, pattern: #"[ \t]+\n"#, with: "\n")
        out = TextTools.replacing(out, pattern: #"\n[ \t]+"#, with: "\n")
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func capitalizeLineStarts(_ text: String) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: false)
            .map { TextTools.capitalizingFirstLetter(String($0)) }
            .joined(separator: "\n")
    }
}
