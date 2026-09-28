import Foundation

/// The fast cleanup model sometimes leaves out words that carried meaning: a whole clause it took for a false start
/// ("I have to book another pickup slot so I yeah I have to call them first" → "I have to call them first"), a phrase at
/// the end ("does it still have a few question marks?" → "…a few?"), a spoken "em dash" the speaker was talking *about*.
/// This finds those drops so the pipeline can hand the dictation to the strong model instead.
extension DriftGuard {
    /// Spoken retractions: what comes before them may legitimately disappear.
    static let retractionCues = [" actually ", " scratch that ", " no wait ", " wait no ", " i mean ", " sorry ", " make that ", " or rather "]

    /// Whether the speaker retracted something: a retraction phrase, or "rather" as a correction ("to Tamaro, rather
    /// Priya") — not a preference ("I'd rather keep", "rather than").
    static func hasRetraction(_ said: [String]) -> Bool {
        let spoken = " " + said.joined(separator: " ") + " "
        if retractionCues.contains(where: spoken.contains) { return true }
        let preference: Set<String> = ["would", "i'd", "we'd", "you'd", "they'd", "he'd", "she'd", "had", "much"]
        return said.indices.contains { i in
            said[i] == "rather" && (i == 0 || !preference.contains(said[i - 1])) && (i + 1 == said.count || said[i + 1] != "than")
        }
    }

    /// The words of `input` missing from `output` that carried content (empty when nothing meaningful was dropped).
    /// Not counted: fillers and little function words, repeats and stutters, a short false start the speaker
    /// backed up from ("could be a, you can make like a, sticky bar"), and words the output kept in another form
    /// (digits, hyphenation, spelling, a spoken symbol written as the symbol). Skipped when a retraction was spoken.
    public static func droppedContent(input: String, output: String) -> [String] {
        let said = TextTools.normalizedTokens(input), kept = TextTools.normalizedTokens(output)
        guard !said.isEmpty, !kept.isEmpty else { return [] }
        if hasRetraction(said) { return [] }

        var dropped: [String] = []
        let gaps = Self.gaps(said, kept)
        let droppedIndices = Set(gaps.flatMap { Array($0.said) })
        for gap in gaps {
            // A false start: the speaker backed up and re-said the word(s) just before it ("we should, we need to ship"),
            // or started over with words the abandoned attempt began with ("the app should let, the app should allow…").
            // It may lose one word of content ("you can make like a"), and a "no" is the correction's marker
            // ("by tomorrow, no, by Friday").
            let lower = gap.said.lowerBound, upper = gap.said.upperBound
            let restart = (lower > 0 && said[max(0, lower - 2)..<lower].contains(said[upper - 1]))
                || (upper < said.count && gap.said.contains { said[$0] == said[upper] })
            let context = Self.context(of: gap.said, in: said, excluding: droppedIndices)
            let unexplained = gap.said.filter { i in
                !(restart && ["no", "nope", "wait", "oops"].contains(said[i]))
                    && !explained(at: i, in: said, gap: gap, context: context, input: input, output: output)
            }
            if unexplained.count > (restart ? 1 : 0) { dropped += unexplained.map { said[$0] } }
        }
        return dropped
    }

    /// A run of input words the output doesn't have, and the output words written in their place (if any).
    struct Gap {
        var said: Range<Int>
        var added: [String]
    }

    /// Word alignment (longest common subsequence): the runs of input words that didn't make it into the output.
    static func gaps(_ a: [String], _ b: [String]) -> [Gap] {
        // table[i * width + j]: length of the longest common subsequence of a[i...] and b[j...].
        let width = b.count + 1
        var table = [Int](repeating: 0, count: (a.count + 1) * width)
        for i in stride(from: a.count - 1, through: 0, by: -1) {
            for j in stride(from: b.count - 1, through: 0, by: -1) {
                table[i * width + j] = a[i] == b[j] ? table[(i + 1) * width + j + 1] + 1 : max(table[(i + 1) * width + j], table[i * width + j + 1])
            }
        }
        var gaps: [Gap] = []
        var start: Int?, added: [String] = []
        var i = 0, j = 0
        func close() {
            if let s = start { gaps.append(Gap(said: s..<i, added: added)) }
            start = nil
            added = []
        }
        while i < a.count || j < b.count {
            if i < a.count, j < b.count, a[i] == b[j] {
                close()
                i += 1; j += 1
            } else if i < a.count, j == b.count || table[(i + 1) * width + j] >= table[i * width + j + 1] {
                if start == nil { start = i }
                i += 1
            } else {
                added.append(b[j])
                j += 1
            }
        }
        close()
        return gaps
    }

    /// The kept words around a gap (a repeat of one of them isn't a loss).
    static func context(of range: Range<Int>, in said: [String], excluding dropped: Set<Int>) -> Set<String> {
        let window = max(0, range.lowerBound - 8)..<min(said.count, range.upperBound + 8)
        var words = Set<String>()
        for i in window where !dropped.contains(i) {
            words.insert(said[i])
            words.formUnion(parts(of: said[i]))
        }
        return words
    }

    static func parts(of token: String) -> [String] {
        token.split(whereSeparator: { !$0.isLetter && !$0.isNumber && $0 != "'" }).map(String.init)
    }

    static func explained(at i: Int, in said: [String], gap: Gap, context: Set<String>, input: String, output: String) -> Bool {
        let word = said[i]
        let previous = i > 0 ? said[i - 1] : "", next = i + 1 < said.count ? said[i + 1] : ""
        if droppableWords.contains(word) { return true }
        // "you know", "I mean", "kind of", "sort of", "I guess"
        if (word == "know" && previous == "you") || (word == "mean" && previous == "i") || (word == "guess" && previous == "i")
            || (["kind", "sort"].contains(word) && next == "of") { return true }
        // Said twice ("the the", "I think I think"), or said again right around here.
        if context.contains(word) || context.contains(where: { $0.count >= 4 && word.count >= 4 && TextTools.similarity($0, word) >= 0.75 }) {
            return true
        }
        let added = gap.added
        let addedDigits = added.contains { $0.contains(where: \.isNumber) }
        // Numbers written as digits ("ten" → "10", "first" → "1.", "fiveg" → "5G", "ones" → "1s").
        if numberWords.contains(word) && (addedDigits || output.contains(where: \.isNumber)) { return true }
        if addedDigits {
            let stems = numberWords.filter { word.hasPrefix($0) && word.count > $0.count }.map { word.dropFirst($0.count) }
            if added.contains(where: { token in stems.contains { token.drop(while: \.isNumber) == $0 } }) { return true }
        }
        // Kept in another form: joined or hyphenated ("left hand" → "left-hand", "u s" → "us"), a spelling or
        // homophone fix ("skew" → "SKU"), an email address or URL ("sam at example dot com").
        for token in added {
            if parts(of: token).contains(word) { return true }
            if word.count >= 3 && (TextTools.similarity(token, word) >= 0.7 || Phonetic.soundsAlike(token, word)) { return true }
            // Another form of the same word ("study" → "studies", "planning" → "plans").
            let shared = zip(token, word).prefix { $0 == $1 }.count
            if shared >= 4 && shared >= min(token.count, word.count) - 2 { return true }
            // Words run together ("code base" → "codebase", "loop wise" → "Loopwise"): a run of the gap covering this word.
            let letters = token.filter { $0.isLetter || $0.isNumber }
            for start in gap.said.lowerBound...i {
                var joined = ""
                for k in start..<gap.said.upperBound {
                    joined += said[k]
                    if joined == letters && k >= i { return true }
                    if joined.count >= letters.count { break }
                }
            }
        }
        // "the billing page slash the settings page" → "…page or the settings page"
        if word == "slash" && added.contains(where: { $0 == "or" || $0 == "and" }) { return true }
        // A spoken symbol the output wrote as the character ("great em dash better" → "great—better") — unless the
        // speaker was talking about the symbol ("the title has an em dash", "a few question marks").
        if let name = spokenSymbol(at: i, in: said) {
            return !isTopic(name, in: said) && name.symbols.contains { count($0, in: output) > count($0, in: input) }
        }
        return false
    }

    /// The spoken symbol name ("comma", "question mark", "em dashes") that the word at `i` belongs to.
    static func spokenSymbol(at i: Int, in said: [String]) -> (range: ClosedRange<Int>, plural: Bool, symbols: [String])? {
        func lookup(_ phrase: String) -> (plural: Bool, symbols: [String])? {
            if let symbols = spokenSymbols[phrase] { return (false, symbols) }
            for suffix in ["es", "s"] where phrase.hasSuffix(suffix) {
                if let symbols = spokenSymbols[String(phrase.dropLast(suffix.count))] { return (true, symbols) }
            }
            return nil
        }
        if i > 0, let found = lookup(said[i - 1] + " " + said[i]) { return (i - 1...i, found.plural, found.symbols) }
        if i + 1 < said.count, let found = lookup(said[i] + " " + said[i + 1]) { return (i...i + 1, found.plural, found.symbols) }
        if let found = lookup(said[i]) { return (i...i, found.plural, found.symbols) }
        return nil
    }

    /// A punctuation name used as a noun is what the speaker is talking about, not a command: "the title has an em
    /// dash", "a plain dash", "a few question marks", "em dashes are…".
    static func isTopic(_ name: (range: ClosedRange<Int>, plural: Bool, symbols: [String]), in said: [String]) -> Bool {
        // Amounts ("sixty dollars" → "$60", "ten percent" → "10%") are written as symbols whatever the grammar.
        if name.symbols.contains(where: { ["$", "€", "£", "%"].contains($0) }) { return false }
        let before = name.range.lowerBound > 0 ? said[name.range.lowerBound - 1] : ""
        let after = name.range.upperBound + 1 < said.count ? said[name.range.upperBound + 1] : ""
        return name.plural || nounLeads.contains(before) || ["is", "are", "was", "were", "looks", "means"].contains(after)
    }

    static func count(_ symbol: String, in text: String) -> Int {
        text.components(separatedBy: symbol).count - 1
    }

    /// Words before a noun: after these, "dash" / "comma" / "question mark" is a thing, not punctuation to insert.
    static let nounLeads: Set<String> = [
        "a", "an", "the", "this", "that", "these", "those", "than", "no", "any", "every", "each", "some", "one", "two", "of", "regular",
        "normal", "plain", "real", "double", "single", "extra", "many", "more", "fewer", "less", "with", "without", "my", "your",
        "his", "her", "their", "our", "its", "genuine", "open", "big", "long", "short", "use", "using", "uses",
    ]

    /// Spoken punctuation and symbols a model may legitimately turn into the character.
    static let spokenSymbols: [String: [String]] = [
        "comma": [","], "period": ["."], "full stop": ["."], "dot": ["."], "point": ["."], "question mark": ["?"],
        "exclamation mark": ["!"], "exclamation point": ["!"], "colon": [":"], "semicolon": [";"], "dash": ["—", "–", "-"],
        "em dash": ["—", "–", "-"], "en dash": ["–", "—", "-"], "hyphen": ["-"], "ellipsis": ["…", "..."], "slash": ["/"],
        "backslash": ["\\"], "underscore": ["_"], "ampersand": ["&"], "percent": ["%"], "dollar": ["$"], "buck": ["$"],
        "euro": ["€"], "pound": ["£", "#"], "hashtag": ["#"], "hash": ["#"], "asterisk": ["*"], "plus": ["+"], "equals": ["="],
        "at": ["@"], "paren": ["(", ")"], "parenthesis": ["(", ")"], "parentheses": ["(", ")"], "bracket": ["[", "]"],
        "quote": ["\"", "“", "”"],
    ]

    static let numberWords: Set<String> = [
        "zero", "oh", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten", "eleven", "twelve", "thirteen",
        "fourteen", "fifteen", "sixteen", "seventeen", "eighteen", "nineteen", "twenty", "thirty", "forty", "fifty", "sixty", "seventy",
        "eighty", "ninety", "hundred", "thousand", "million", "billion", "ones", "twos", "first", "second", "third", "fourth", "fifth",
        "sixth", "seventh", "eighth", "ninth", "tenth", "half", "quarter", "dozen", "point", "o'clock",
    ]

    /// Fillers, discourse words and function words: a model may drop or swap these without changing what was said.
    /// Negations ("not", "didn't", "never") are content: dropping one flips the meaning.
    static let droppableWords: Set<String> = [
        // fillers and discourse markers
        "um", "uh", "umm", "uhm", "erm", "er", "hmm", "mm", "mhm", "ah", "oh", "okay", "ok", "well", "yeah", "yep", "yes", "right",
        "so", "like", "just", "actually", "basically", "literally", "really", "very", "totally", "pretty", "anyway", "anyways",
        "alright", "also", "though", "then", "now", "there", "here", "even", "still", "too", "else",
        // articles, determiners, pronouns
        "a", "an", "the", "this", "that", "these", "those", "some", "any", "each", "every", "either", "neither", "both", "all",
        "another", "other", "such", "what", "which", "whatever", "i", "me", "my", "mine", "myself", "you", "your", "yours", "yourself",
        "he", "him", "his", "himself", "she", "her", "hers", "herself", "it", "its", "itself", "we", "us", "our", "ours", "ourselves",
        "they", "them", "their", "theirs", "themselves", "one", "who", "whom", "whose",
        // contractions (without negation) and colloquial forms
        "i'm", "i've", "i'll", "i'd", "you're", "you've", "you'll", "you'd", "he's", "she's", "it's", "we're", "we've", "we'll", "we'd",
        "they're", "they've", "they'll", "they'd", "that's", "there's", "here's", "what's", "let's", "who's", "gonna", "wanna", "gotta",
        "kinda", "sorta", "lemme", "gimme", "y'all", "cause",
        // auxiliaries and modals
        "be", "am", "is", "are", "was", "were", "been", "being", "do", "does", "did", "have", "has", "had", "having", "will", "would",
        "shall", "should", "can", "could", "may", "might", "must", "get", "got",
        // prepositions and conjunctions
        "of", "in", "on", "at", "to", "for", "from", "by", "with", "about", "into", "onto", "over", "under", "up", "down", "out", "off",
        "through", "as", "than", "if", "but", "and", "or", "nor", "because", "while", "when", "where", "how", "why", "whether", "etc",
    ]
}
