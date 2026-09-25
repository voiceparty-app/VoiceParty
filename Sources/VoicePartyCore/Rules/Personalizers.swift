import Foundation

/// Expands spoken snippet triggers. The longest trigger wins; matching ignores case and punctuation.
public struct SnippetExpander: Sendable {
    public var snippets: [Snippet]

    public init(snippets: [Snippet]) {
        self.snippets = snippets.filter { !TextTools.normalizePhrase($0.trigger).isEmpty }
            .sorted { $0.trigger.count > $1.trigger.count }
    }

    /// Small words people add around a trigger said on its own ("insert my email address, please").
    static let looseWords: Set<String> = [
        "um", "uh", "please", "insert", "paste", "type", "add", "snippet", "the", "my", "a", "an", "our", "your", "okay", "ok", "so",
    ]

    /// The snippet when the whole utterance is its trigger: exactly, or with spelling variants
    /// ("organise") and small extra words ("organize my thoughts prompt").
    public func wholeUtteranceMatch(_ text: String) -> Snippet? {
        let normalized = TextTools.normalizePhrase(text)
        if let exact = snippets.first(where: { TextTools.normalizePhrase($0.trigger) == normalized }) { return exact }
        let said = TextTools.normalizedTokens(text)
        return snippets.first { Self.loosely(said: said, trigger: TextTools.normalizedTokens($0.trigger)) }
    }

    /// Every trigger word, in order; anything else said must be a small word.
    static func loosely(said: [String], trigger: [String]) -> Bool {
        guard trigger.count >= 2 else { return false }
        var next = 0
        for word in said {
            if next < trigger.count && sameWord(word, trigger[next]) { next += 1 }
            else if !looseWords.contains(word) { return false }
        }
        return next == trigger.count
    }

    /// The same word, allowing British/American spellings (organise/organize, colour/color, centre/center) —
    /// but not near words ("stats" isn't "status") or plurals ("reports" isn't "report").
    static func sameWord(_ a: String, _ b: String) -> Bool {
        a == b || (min(a.count, b.count) >= 4 && americanSpelling(a) == americanSpelling(b))
    }

    static func americanSpelling(_ word: String) -> String {
        var w = word
        for (british, american) in [("isation", "ization"), ("ise", "ize"), ("ised", "ized"), ("ising", "izing"), ("yse", "yze"),
                                    ("ysed", "yzed"), ("ysing", "yzing"), ("our", "or"), ("ours", "ors"), ("tre", "ter"),
                                    ("tres", "ters"), ("ogue", "og"), ("ogues", "ogs"), ("ence", "ense"), ("lled", "led"),
                                    ("lling", "ling")] where w.hasSuffix(british) {
            w = String(w.dropLast(british.count)) + american
            break
        }
        return w
    }

    public func expand(_ text: String) -> (text: String, used: [UUID]) {
        if let whole = wholeUtteranceMatch(text) { return (whole.expansion, [whole.id]) }
        var out = text
        var used: [UUID] = []
        for snippet in snippets {
            guard let pattern = TextTools.wholePhrasePattern(snippet.trigger), let re = TextTools.regex(pattern) else { continue }
            let range = NSRange(out.startIndex..., in: out)
            if re.firstMatch(in: out, range: range) != nil {
                out = re.stringByReplacingMatches(in: out, range: range, withTemplate: NSRegularExpression.escapedTemplate(for: snippet.expansion))
                used.append(snippet.id)
            } else if let spelled = Self.replaceVariant(of: snippet, in: out) {
                out = spelled
                used.append(snippet.id)
            }
        }
        return (out, used)
    }

    /// Inside a sentence: the trigger's words in a row with spelling variants allowed ("the organise thoughts
    /// prompt"), never across sentence punctuation and never with extra words.
    static func replaceVariant(of snippet: Snippet, in text: String) -> String? {
        let trigger = TextTools.normalizedTokens(snippet.trigger)
        guard trigger.count >= 2, let re = TextTools.regex(#"[\p{L}\p{N}']+"#) else { return nil }
        let ns = text as NSString
        let words = re.matches(in: text, range: NSRange(location: 0, length: ns.length)).map(\.range)
        guard words.count >= trigger.count else { return nil }
        var out = text
        for start in stride(from: words.count - trigger.count, through: 0, by: -1) {
            let window = words[start..<(start + trigger.count)]
            let matches = zip(window, trigger).allSatisfy { sameWord(ns.substring(with: $0.0).lowercased(), $0.1) }
            let joined = zip(window.dropLast(), window.dropFirst()).allSatisfy { a, b in
                ns.substring(with: NSRange(location: a.upperBound, length: b.location - a.upperBound)).allSatisfy { $0 == " " || $0 == "," }
            }
            guard matches, joined, let first = window.first, let last = window.last,
                  let range = Range(NSRange(location: first.location, length: last.upperBound - first.location), in: out) else { continue }
            out.replaceSubrange(range, with: snippet.expansion)
            return out
        }
        return nil
    }
}

/// Applies dictionary replacement rules (`btw → by the way`) and restores the exact spelling of
/// dictionary words that carry special casing (`linkedin → LinkedIn`).
public struct DictionaryApplier: Sendable {
    public var entries: [DictionaryEntry]
    /// Names eligible for sound-alike correction (worked out once; the check isn't free). Words learned
    /// automatically don't qualify: a learned typo must never rewrite the correct word ("Anthropc").
    let soundAlikeEntries: [DictionaryEntry]
    /// Ordinary English (the app passes Apple's vocabulary; otherwise the built-in common-word list).
    let isEnglishWord: @Sendable (String) -> Bool

    /// Phrases that are ordinary English as two words: never joined into a product name.
    static let commonSplitPhrases: Set<String> = ["linked in", "face time", "drop box", "log in", "sign in", "check in", "set up",
                                                  "look up", "work out", "work day", "home work", "air drop", "note book"]

    /// Little words that make a phrase with the word before them.
    static let functionWords: Set<String> = ["a", "an", "as", "at", "by", "i", "in", "is", "it", "me", "no", "of", "on", "or", "so",
                                             "to", "up", "us", "we", "he", "do", "go", "if"]

    public init(entries: [DictionaryEntry], isEnglishWord: (@Sendable (String) -> Bool)? = nil) {
        self.entries = entries.sorted { $0.phrase.count > $1.phrase.count }
        self.isEnglishWord = isEnglishWord ?? { CommonWords.contains($0.lowercased()) }
        soundAlikeEntries = self.entries.filter { $0.replacement == nil && $0.source != .learned && SoundAlikeNames.isCandidate($0.phrase) }
    }

    public func apply(_ text: String) -> (text: String, replacements: Int, usedIDs: [UUID]) {
        var out = text
        var count = 0
        var used: [UUID] = []
        for entry in entries where entry.replacement == nil {
            // Rejoin a word the engine split in two ("loop wise" → "Loopwise").
            let letters = Array(entry.phrase)
            guard letters.count >= 4, letters.allSatisfy({ $0.isLetter || $0.isNumber }) else { continue }
            let body = letters.map { NSRegularExpression.escapedPattern(for: String($0)) }.joined(separator: #"\s?"#)
            guard let re = TextTools.regex(#"(?<![\p{L}\p{N}_/@.\\])"# + body + #"(?![\p{L}\p{N}_/@\\]|\.[\p{L}\p{N}])"#) else { continue }
            let ns = out as NSString
            let splits = re.matches(in: out, range: NSRange(location: 0, length: ns.length)).filter { match in
                let found = ns.substring(with: match.range)
                // "loop wise" → Loopwise, but not "work day" → Workday: all-common-word pairs stay apart —
                // unless the word's inner capital says it's two words written as one (VoiceParty, PowerPoint).
                let camelCase = entry.phrase.dropFirst().contains(where: \.isUppercase)
                let spaced = found.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ")
                if Self.commonSplitPhrases.contains(spaced) { return false } // "linked in the ticket"
                let parts = found.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
                // A word plus a little word ("brand on", "dust in", "west on") is a phrase, not Brandon/Dustin/Weston.
                if !camelCase && parts.contains(where: Self.functionWords.contains) { return false }
                return found.contains(" ") && (camelCase || !parts.allSatisfy(CommonWords.contains))
            }
            guard !splits.isEmpty else { continue }
            for match in splits.reversed() {
                if let range = Range(match.range, in: out) { out.replaceSubrange(range, with: entry.phrase) }
            }
            count += splits.count
            used.append(entry.id)
        }
        // A name the recognizer spelled as letters ("TMRO" → "Tamaro").
        let spelled = SpelledOutNames.apply(out, terms: entries.filter { $0.replacement == nil && $0.source != .learned }.map(\.phrase))
        if !spelled.replaced.isEmpty {
            out = spelled.text
            count += spelled.replaced.count
            used += entries.filter { spelled.replaced.contains($0.phrase) }.map(\.id)
        }
        // A name heard as ordinary words or a near spelling ("loop wize" / "Loopwize" → "Loopwise").
        for entry in soundAlikeEntries {
            let fixed = SoundAlikeNames.apply(out, term: entry.phrase, isEnglishWord: isEnglishWord)
            if fixed.count > 0 {
                out = fixed.text
                count += fixed.count
                used.append(entry.id)
            }
        }
        for entry in entries {
            guard let pattern = TextTools.wholePhrasePattern(entry.phrase), let re = TextTools.regex(pattern) else { continue }
            let target = entry.replacement ?? entry.phrase
            // Force a name's spelling only when its casing can't be inferred, or it isn't also an ordinary word:
            // "Tamaro", "iPhone" yes; "Grant", "Summer", "Frank" (a grant, this summer, to be frank) no.
            if entry.replacement == nil && (!entry.phrase.contains(where: \.isUppercase) || CommonWords.isNearCommon(entry.phrase)
                || (!Self.hasSpecialCasing(entry.phrase) && isEnglishWord(entry.phrase.lowercased()))) { continue }
            let ns = out as NSString
            let matches = re.matches(in: out, range: NSRange(location: 0, length: ns.length)).filter { ns.substring(with: $0.range) != target }
            guard !matches.isEmpty else { continue }
            for match in matches.reversed() {
                let found = ns.substring(with: match.range)
                var replacement = target
                // Keep a sentence-initial capital: "Btw," → "By the way,".
                if entry.replacement != nil, found.first?.isUppercase == true, replacement.first?.isLowercase == true {
                    replacement = replacement.prefix(1).uppercased() + replacement.dropFirst()
                }
                if let range = Range(match.range, in: out) { out.replaceSubrange(range, with: replacement) }
            }
            count += matches.count
            used.append(entry.id)
        }
        return (out, count, used)
    }

    /// Only words whose casing can't be inferred get forced: inner capitals, all caps, digits, multi-word names.
    static func hasSpecialCasing(_ phrase: String) -> Bool {
        let letters = phrase.filter(\.isLetter)
        guard !letters.isEmpty else { return false }
        let innerCaps = phrase.dropFirst().contains(where: \.isUppercase)
        let multiWordName = phrase.contains(" ") && phrase.first?.isUppercase == true
        return innerCaps || phrase.contains(where: \.isNumber) || multiWordName
    }
}

/// Chooses up to `limit` phrases to bias the speech engine: starred first, then most used, then on-screen terms.
public enum VocabularyBuilder {
    /// Order: starred words, then what's on screen right now, then the rest of the dictionary by use.
    public static func build(dictionary: [DictionaryEntry], contextTerms: [String], limit: Int = 100) -> [String] {
        let words = dictionary.filter { $0.replacement == nil }
        let starred = words.filter(\.isStarred).map(\.phrase)
        let rest = words.filter { !$0.isStarred }.sorted {
            if $0.useCount != $1.useCount { return $0.useCount > $1.useCount }
            return $0.createdAt > $1.createdAt
        }.map(\.phrase)
        var seen = Set<String>()
        var result: [String] = []
        for phrase in starred + contextTerms + rest {
            let key = phrase.lowercased()
            guard !phrase.isEmpty, !seen.contains(key) else { continue }
            seen.insert(key)
            result.append(phrase)
            if result.count == limit { break }
        }
        return result
    }

    /// Hints for the speech recognizer. Unstarred words that are (nearly) common English words are left
    /// out: hinting "deta" makes the recognizer hear "deta" whenever you say "data".
    public static func engineHints(dictionary: [DictionaryEntry], contextTerms: [String], limit: Int = 100) -> [String] {
        let starred = Set(dictionary.filter(\.isStarred).map { $0.phrase.lowercased() })
        return build(dictionary: dictionary, contextTerms: contextTerms, limit: limit * 2).filter { phrase in
            starred.contains(phrase.lowercased()) || phrase.contains(" ") || !CommonWords.isNearCommon(phrase)
        }.prefix(limit).map { $0 }
    }

    /// The terms that plausibly occur in `transcript` (exactly, split across words like "deal co" →
    /// "Loopwise", or misspelled). Only these go into a language-model prompt: a short list keeps the
    /// prompt fast and stops small models from echoing the whole glossary back.
    public static func relevant(_ terms: [String], to transcript: String) -> [String] {
        let tokens = TextTools.normalizedTokens(transcript)
        guard !tokens.isEmpty else { return [] }
        var candidates = Set(tokens)
        for i in 0..<tokens.count {
            if i + 1 < tokens.count { candidates.insert(tokens[i] + tokens[i + 1]) }
            if i + 2 < tokens.count { candidates.insert(tokens[i] + tokens[i + 1] + tokens[i + 2]) }
        }
        let capitals = SpelledOutNames.capitalTokens(in: transcript).map(\.token)
        return terms.filter { term in
            if capitals.contains(where: { SpelledOutNames.matches($0, term: term) }) && SpelledOutNames.isCandidate(term) { return true }
            let termTokens = TextTools.normalizedTokens(term)
            guard !termTokens.isEmpty else { return false }
            let joined = termTokens.joined()
            if candidates.contains(joined) { return true }
            if termTokens.contains(where: { $0.count >= 3 && candidates.contains($0) }) { return true }
            let probes = [joined] + termTokens.filter { $0.count >= 4 }
            return probes.contains { probe in
                probe.count >= 4 && candidates.contains { candidate in
                    guard candidate.count >= 3 else { return false }
                    let similarity = TextTools.similarity(candidate, probe)
                    // Close spelling, or same sound with moderately close spelling ("katherine" ~ "kathryn", not "catering").
                    return similarity >= 0.75 || (similarity >= 0.6 && Phonetic.soundsAlike(candidate, probe) && !CommonWords.contains(candidate))
                }
            }
        }
    }
}

/// Rejects language-model output that drifted from what was said (answered the text, refused,
/// hallucinated, or dropped content). On rejection the pipeline falls back to rule-based cleanup.
public enum DriftGuard {
    public static func accepts(input: String, output: String, level: CleanupLevel, vocabulary: [String] = []) -> Bool {
        let out = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !out.isEmpty else { return false }

        let inTokens = TextTools.normalizedTokens(input)
        let outTokens = TextTools.normalizedTokens(out)
        guard !inTokens.isEmpty else { return true }
        guard !outTokens.isEmpty else { return false }

        let refusalMarkers = ["i can't", "i cannot", "i'm sorry", "i am sorry", "as an ai", "i'm unable", "i apologize"]
        let lowerOut = out.lowercased(), lowerIn = input.lowercased()
        if refusalMarkers.contains(where: { lowerOut.contains($0) && !lowerIn.contains($0) }) { return false }

        // A question must stay a question, not get answered ("what time is it in Tokyo" → "It is 3 PM in Tokyo").
        let questionWords: Set<String> = ["what", "when", "where", "who", "whom", "whose", "why", "how", "which"]
        if let first = inTokens.first, questionWords.contains(first), !outTokens.prefix(3).contains(first) {
            let spoken = " " + inTokens.joined(separator: " ") + " "
            if ![" actually ", " scratch that ", " no wait ", " i mean "].contains(where: spoken.contains) { return false }
        }

        // Cleanup removes words; it may add a few (list numbers, a greeting comma's worth), never many.
        let growth = outTokens.count - inTokens.count
        if growth > max(3, inTokens.count / 3) { return false }
        let ratio = Double(outTokens.count) / Double(inTokens.count)
        // A spoken retraction legitimately throws away most of what came before it.
        let spokenInput = " " + inTokens.joined(separator: " ") + " "
        let retracted = [" actually ", " scratch that ", " no wait ", " i mean ", " sorry ", " make that ", " rather "].contains { spokenInput.contains($0) }
        let minRatio = retracted ? 0.15 : level == .medium ? 0.3 : 0.45
        // Short inputs can legitimately shrink a lot ("um, uh, yes" → "Yes.").
        if inTokens.count >= 8 && ratio < minRatio { return false }

        // Output words must come from what was said: the words themselves, words run together
        // ("loop wise" → "loopwise"), close spellings, or dictionary terms that match something said.
        var known = Set(inTokens)
        for i in 0..<(inTokens.count - 1) { known.insert(inTokens[i] + inTokens[i + 1]) }
        for term in VocabularyBuilder.relevant(vocabulary, to: input) {
            known.formUnion(TextTools.normalizedTokens(term))
        }
        let novel = outTokens.filter { token in
            guard !known.contains(token) else { return false }
            if token.allSatisfy(\.isNumber) { return false } // "ten" → "10", list numbering
            // "sam at example dot com" → "sam@example.com": every part was said.
            let parts = token.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
            if parts.count > 1 && parts.allSatisfy(known.contains) { return false }
            return !known.contains { $0.count >= 3 && TextTools.similarity($0, token) >= 0.75 }
        }.count
        let novelty = Double(novel) / Double(outTokens.count)
        let maxNovelty = level == .medium ? 0.45 : 0.3
        if outTokens.count < 4 {
            // A short output from a longer input must be made only of spoken words ("Paris." answering a question).
            guard novel == 0 || (inTokens.count < 4 && novel <= 1) else { return false }
        } else if novelty > maxNovelty {
            return false
        }

        // A glossary term showing up more often than it was said means the model echoed the glossary.
        for term in VocabularyBuilder.relevant(vocabulary, to: input) {
            let termTokens = TextTools.normalizedTokens(term)
            let spelledOut = SpelledOutNames.capitalTokens(in: input).filter { SpelledOutNames.matches($0.token, term: term) }.count
            if occurrences(of: termTokens, in: outTokens) > occurrences(of: termTokens, in: inTokens) + spelledOut { return false }
        }
        return true
    }

    /// Counts a term in a token list, including when it was split ("deal co") or run together.
    static func occurrences(of term: [String], in tokens: [String]) -> Int {
        guard !term.isEmpty, !tokens.isEmpty else { return 0 }
        let joined = term.joined()
        var count = 0
        var i = 0
        while i < tokens.count {
            if i + term.count <= tokens.count, Array(tokens[i..<(i + term.count)]) == term {
                count += 1; i += term.count; continue
            }
            var matched = false
            for width in 1...3 where i + width <= tokens.count {
                if tokens[i..<(i + width)].joined() == joined {
                    count += 1; i += width; matched = true; break
                }
            }
            if !matched { i += 1 }
        }
        return count
    }
}

/// Terms seen around the cursor (Accessibility) and, when enabled, on screen (OCR), for one dictation.
public enum ContextTerms {
    /// Cursor terms first (most relevant), then on-screen ones; case-insensitive duplicates dropped, capped.
    public static func merge(cursor: [String], screen: [String], limit: Int = 60) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for term in cursor + screen where seen.insert(term.lowercased()).inserted {
            result.append(term)
            if result.count == limit { break }
        }
        return result
    }
}

/// Word shapes that mark names and identifiers ("GitHub", "iPhone", "macOS"), as opposed to OCR noise
/// with a stray capital ("btW", "ooO").
public enum TermShape {
    public static func isCamelCase(_ word: String) -> Bool {
        let letters = Array(word)
        guard letters.count >= 3, word.contains(where: \.isLowercase) else { return false }
        for i in 1..<letters.count where letters[i].isUppercase {
            // A capital followed by lowercase: a new word part ("Wipe|Smith", "i|Phone").
            if i + 1 < letters.count, letters[i + 1].isLowercase { return true }
        }
        // Or a trailing acronym of 2+ capitals after lowercase ("deal|OS", "mac|OS").
        let trailingCaps = letters.reversed().prefix { $0.isUppercase }.count
        return trailingCaps >= 2 && trailingCaps < letters.count && letters[letters.count - trailingCaps - 1].isLowercase
    }
}
