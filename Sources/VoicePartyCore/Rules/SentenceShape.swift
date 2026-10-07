import Foundation

/// What the recognizer gets wrong at the edges of sentences when a long dictation crosses its 15 s window seam (or just
/// in passing): a question ended with a period ("What can we do to solve this."), and a little word capitalised
/// mid-sentence ("and The results"). Both are fixed by the sentence's shape, conservatively: a statement that merely
/// starts like a question ("What I want is…", "Which is why…") and a name or title ("to Priya", "The Office") stay.
public enum SentenceShape {
    static let questionWords: Set<String> = ["what", "why", "how", "when", "where", "who", "which", "whose", "whom"]
    static let auxiliaries: Set<String> = [
        "is", "are", "was", "were", "am", "do", "does", "did", "can", "could", "would", "should", "will", "shall", "may",
        "might", "has", "have", "had", "isn't", "aren't", "wasn't", "weren't", "don't", "doesn't", "didn't", "can't",
        "couldn't", "won't", "wouldn't", "shouldn't", "haven't", "hasn't",
    ]
    static let subjects: Set<String> = [
        "you", "we", "i", "they", "he", "she", "it", "this", "that", "these", "those", "there", "my", "your", "our", "their",
        "his", "her", "its", "the", "a", "an", "someone", "anyone", "anybody", "somebody", "everyone", "everybody",
        "something", "anything", "any", "some", "all", "y'all",
    ]
    /// Leading words that don't change what kind of sentence follows ("So, should we…").
    static let openers: Set<String> = ["so", "and", "but", "okay", "ok", "also", "then", "well", "now", "alright", "hey", "oh", "actually", "anyway"]
    /// "What's important is…": a statement about the thing, not a question.
    static let statementAdjectives: Set<String> = [
        "important", "interesting", "weird", "funny", "nice", "great", "cool", "crazy", "wild", "more", "worse", "better", "best",
        "good", "bad", "annoying", "strange", "odd", "clear", "obvious", "tricky", "hard", "key", "missing", "left", "next",
    ]
    static let tags = [", right", ", correct", ", isn't it", ", aren't they", ", aren't we", ", don't you think", ", doesn't it",
                       ", won't it", ", wouldn't it", ", don't we", ", can't we", ", shouldn't we", ", yeah"]

    /// Short questions without a verb up front.
    static let shortQuestions: Set<String> = [
        "why not", "what else", "what exactly", "anything else", "any thoughts", "thoughts", "any updates", "any update",
        "any questions", "how so", "like what", "which one", "what for", "how come", "since when",
    ]

    /// Whether a sentence (without its final punctuation) is a direct question: by its start, or by a clause after a
    /// comma ("If the orders are already in, does that make sense", "Okay, regarding the news, how does that work").
    static func isQuestion(_ sentence: String) -> Bool {
        let lower = sentence.lowercased().replacingOccurrences(of: "’", with: "'")
        if tags.contains(where: { lower.hasSuffix($0) }) { return true }
        // A piece that starts lowercase continues an earlier sentence ("…version 4. is the default now"): not a question.
        guard let initial = sentence.first(where: { $0.isLetter }), initial.isUppercase else { return false }
        let whole = lower.trimmingCharacters(in: .whitespaces)
        if shortQuestions.contains(whole) { return true }
        let clauses = lower.split(separator: ",").map(String.init)
        if isQuestionClause(clauses[0]) { return true }
        return clauses.dropFirst().contains(where: isLaterQuestionClause)
    }

    /// Pronoun subjects: after a comma only these make a question ("…, does that make sense", "…, can you"), not "a" or
    /// "the" ("…, is a list of…").
    static let pronounSubjects: Set<String> = [
        "you", "we", "i", "they", "he", "she", "it", "there", "that", "this", "anyone", "anybody", "someone", "somebody",
        "everyone", "everybody", "y'all",
    ]

    /// A clause after a comma that asks: an inverted question with a pronoun subject. Relative clauses ("…, which is the
    /// first stop"), lists ("what was done, what wasn't done") and "X, is that…" statements don't count.
    static func isLaterQuestionClause(_ clause: String) -> Bool {
        var words = clause.split(whereSeparator: { $0 == " " || $0 == "\t" }).map { $0.trimmingCharacters(in: CharacterSet(charactersIn: ";:\"“”()")) }
            .filter { !$0.isEmpty }
        while let first = words.first, openers.contains(first), words.count > 2 { words.removeFirst() }
        guard words.count >= 3 else { return false }
        var start = 0
        if ["what", "why", "how", "when", "where", "who"].contains(words[0]) { start = 1 } // "…, how does that work"
        guard words.count > start + 1, auxiliaries.contains(words[start]), pronounSubjects.contains(words[start + 1]) else { return false }
        if ["is", "was"].contains(words[start]) && words[start + 1] == "that" && words.count > 4 { return false } // "…, is that we have…"
        if start == 0 && ["do", "have"].contains(words[0]) && ["that", "this", "it"].contains(words[1]) { return false } // "…, but do it in…"
        return true
    }

    static func isQuestionClause(_ clause: String, minimumWords: Int = 2) -> Bool {
        var words = clause.split(whereSeparator: { $0 == " " || $0 == "\t" }).map { $0.trimmingCharacters(in: CharacterSet(charactersIn: ";:\"“”()")) }
            .filter { !$0.isEmpty }
        while let first = words.first, openers.contains(first), words.count > 2 { words.removeFirst() }
        guard words.count >= minimumWords else { return false }
        let first = words[0], second = words[1], third = words.count > 2 ? words[2] : ""
        let laterCopula = words.dropFirst(3).contains { $0 == "is" || $0 == "was" } // "What is weird is that…"
        if questionWords.contains(first) {
            // "Which is a little distracting…" continues the last sentence; "Which one…", "Which is better…" ask.
            if first == "which" {
                return ["one", "ones", "of", "option", "options", "way", "version", "file", "do", "does", "did", "should", "would",
                        "can", "could", "will", "are"].contains(second)
                    || (["is", "was"].contains(second) && ["better", "best", "faster", "easier", "cheaper", "more", "the", "right", "correct"].contains(third))
            }
            // "What would end up happening is that…", "What would make it defensible is…": a statement (a later "is"),
            // unless a subject follows the verb, as questions do ("What do you think is best").
            if auxiliaries.contains(second) {
                if laterCopula && (["is", "was"].contains(second) || !subjects.contains(third)) { return false }
                return true
            }
            if first == "how" && ["much", "many", "long", "often", "far", "soon", "come", "about"].contains(second) { return true }
            if (first == "what" && second == "about") || (first == "why" && second == "not") { return true }
            if first == "what" && ["type", "kind", "sort", "time", "day", "version", "size", "color", "colour"].contains(second) && third == "of" {
                return true
            }
            return false
        }
        for contraction in ["what's", "how's", "where's", "who's", "why's", "when's"] where first == contraction {
            return !statementAdjectives.contains(second) && !laterCopula
        }
        if auxiliaries.contains(first) && subjects.contains(second) {
            // "Do the migration first", "Have a look at this": requests, not questions.
            if ["do", "have"].contains(first) && ["a", "an", "the", "some", "this", "that", "it", "any", "all"].contains(second) { return false }
            return words.count >= 3
        }
        return false
    }

    /// Questions whose sentence ends with a period (or, for the last sentence, with nothing) get a question mark.
    public static func addQuestionMarks(_ text: String) -> String {
        var out = ""
        var sentence = ""
        let abbreviations = ["etc", "e.g", "i.e", "vs", "mr", "mrs", "ms", "dr", "st", "no"]
        var characters = Array(text)
        var index = 0
        func closeSentence(with terminal: Character?, asIs: Bool = false) {
            if !asIs, terminal == "." || (terminal == nil && index >= characters.count), !sentence.trimmingCharacters(in: .whitespaces).isEmpty,
               isQuestion(sentence) {
                out += sentence + "?"
            } else {
                out += sentence + (terminal.map(String.init) ?? "")
            }
            sentence = ""
        }
        while index < characters.count {
            let character = characters[index]
            let next: Character? = index + 1 < characters.count ? characters[index + 1] : nil
            if character == "." || character == "?" || character == "!" {
                let lastWord = sentence.split(whereSeparator: { $0 == " " }).last.map { $0.lowercased() } ?? ""
                let ends = next == nil || next == " " || next == "\n" || next == "\""
                // "…or is that just... I don't know.": an ellipsis ends the trailing-off sentence as it is.
                if ends && character == "." && (sentence.hasSuffix(".") || sentence.hasSuffix("…")) {
                    index += 1
                    closeSentence(with: character, asIs: true)
                    continue
                }
                if ends && !(character == "." && abbreviations.contains(lastWord)) {
                    index += 1
                    closeSentence(with: character)
                    continue
                }
            }
            if character == "\n" {
                out += sentence + "\n" // a line without final punctuation (a list item, a heading) is left alone
                sentence = ""
                index += 1
                continue
            }
            sentence.append(character)
            index += 1
        }
        characters = []
        if !sentence.isEmpty { closeSentence(with: nil) }
        return out
    }

    /// Words that continue a sentence: a capital on them is always the recognizer's mistake ("merchant To", "or Password").
    static let continuingWords: Set<String> = ["to", "of", "in", "on", "at", "for", "with", "as", "from", "by", "into", "about", "than", "or", "because"]
    /// Little words that start sentences. After a word that can end one, the capital marks a sentence the recognizer
    /// didn't end (Wispr's transcripts of the same audio had a break there 13 times in 16: "have. And", "issue? If",
    /// "dashboard? You"); after one that can't ("to", "the"), it's a stray capital ("the The", "to Potentially").
    static let startingWords: Set<String> = [
        "and", "but", "if", "then", "now", "also", "just", "maybe", "really", "actually", "basically", "probably", "potentially",
        "like", "meaning", "the", "an", "my", "our", "your", "their", "his", "her", "its", "this", "these", "those", "there",
        "here", "it", "it's", "you", "we", "they", "he", "she", "what", "how", "why", "who", "when", "where", "no", "yes", "yeah",
        "okay", "let's", "please", "can", "could", "would", "should", "do", "does", "did", "is", "are", "was", "were", "be", "not",
        "you're", "we're", "they're", "there's", "that's", "what's",
        // review of 60 dictations: more words that start the sentence after a missed break ("…narrow windows Either we…")
        "either", "neither", "however", "otherwise", "anyway", "plus", "again", "finally", "lastly", "overall",
        "honestly", "obviously", "unfortunately", "hopefully", "personally", "regarding", "although", "though", "unless",
        "since", "once", "while", "before", "after", "meanwhile", "besides", "note", "instead",
    ]
    /// "…the editor Which means…", "…Central So we…": a comma, as Wispr writes them.
    static let commaWords: Set<String> = ["which", "so"]
    /// Words after which a sentence can't end, so a capital that follows is mid-sentence.
    /// ("do", "have" and modals can end a clause: "…the changes we should do. And this is…", "what we have. And").
    static let cannotEnd: Set<String> = [
        "to", "the", "a", "an", "of", "in", "on", "at", "for", "with", "and", "or", "but", "as", "if", "because", "from", "by",
        "into", "about", "my", "your", "our", "their", "his", "her", "its", "is", "are", "was", "were", "be", "been", "very",
        "than", "whether", "let's", "please",
    ]
    /// Words that can end a sentence but usually don't ("you'll see that It's…"): treated like `cannotEnd`.
    static let seldomEnd: Set<String> = ["that", "this", "which", "what", "like", "so", "just", "then", "now", "also", "really", "actually", "basically", "where", "when", "how", "who"]
    /// Common verbs: lowercased in a verb slot ("…what can we do to Solve this problem", "let's Consolidate them"; after
    /// "to" only when an object follows); after a word that can end a sentence they start one ("…the page Read the docs").
    static let commonVerbs: Set<String> = [
        "solve", "fix", "make", "build", "run", "check", "see", "get", "find", "use", "add", "remove", "update", "change", "create",
        "test", "try", "help", "keep", "start", "stop", "move", "send", "show", "look", "work", "write", "read", "set", "put",
        "take", "give", "ask", "tell", "call", "open", "close", "clean", "handle", "improve", "reduce", "avoid", "consolidate",
        "simplify", "figure", "understand", "know", "think", "say", "need", "want", "speed", "load", "save", "delete", "merge",
        "deploy", "ship", "review", "explain", "describe", "compare", "replace", "rename", "refactor", "debug", "install",
        "investigate", "research", "verify", "confirm", "list", "push", "pull",
    ]
    static let verbSlots: Set<String> = ["can", "could", "would", "should", "will", "must", "might", "let's", "please", "cannot", "can't",
                                          "won't", "don't", "didn't", "doesn't", "to"]
    static let objects: Set<String> = [
        "this", "that", "the", "a", "an", "it", "them", "these", "those", "my", "your", "our", "their", "his", "her", "its", "some",
        "all", "any", "more", "up", "out", "everything", "something", "anything", "both", "each", "every", "what", "how", "why",
    ]

    /// Fixes a word the recognizer capitalised without a sentence break before it: lowercased when the sentence clearly
    /// goes on, or given back the period (or comma) it lost when the word before can end a sentence. Never touches a word
    /// after punctuation or a line break, one followed by another capitalised word (a title: "watched The Office"), or
    /// anything outside the word lists (names: "for Amazon", "like Claude", "YouTube").
    public static func repairCapitals(_ text: String) -> String {
        // The previous word is read from the text before the match (a lookbehind must have a bounded length).
        guard let pattern = TextTools.regex(#"(?<=[\p{L}\p{N}'’])([ \t]+)([A-Z][a-z]*(?:['’][a-z]+)?)(?![\p{L}\p{N}]|[.'’-][\p{L}])(?=([ \t]+[^\s]+)?)"#,
                                            caseInsensitive: false) else { return text }
        let ns = text as NSString
        var out = text
        for match in pattern.matches(in: text, range: NSRange(location: 0, length: ns.length)).reversed() {
            let word = ns.substring(with: match.range(at: 2))
            let lower = word.lowercased().replacingOccurrences(of: "’", with: "'")
            let gapStart = match.range(at: 1).location
            let previous = ns.substring(to: gapStart).split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\n" }).last.map {
                $0.lowercased().replacingOccurrences(of: "’", with: "'")
            } ?? ""
            let followingRaw = match.range(at: 3).location != NSNotFound ? ns.substring(with: match.range(at: 3)).trimmingCharacters(in: .whitespaces) : ""
            let following = followingRaw.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ".,;:!?\"”"))
            if let initial = followingRaw.first, initial.isUppercase { continue } // a title or a name of several words
            let goesOn = cannotEnd.contains(previous) || seldomEnd.contains(previous)
            // "TanStack Start", "Counts Fix": a verb after a capitalised word is part of a name, not a new sentence.
            let previousIsName = ns.substring(to: gapStart).split(whereSeparator: { $0 == " " || $0 == "\t" }).last?.first?.isUppercase == true
            enum Fix { case lowercase, period, comma }
            let fix: Fix?
            if continuingWords.contains(lower) || (lower == "instead" && following == "of") { // "…timeline Instead of the card"
                fix = .lowercase
            } else if commaWords.contains(lower) {
                fix = goesOn ? .lowercase : (previousIsName ? nil : .comma)
            } else if startingWords.contains(lower) {
                // After a name only a pronoun or "And"/"But" starts a sentence; "Vite Plus", "English What you said" stay.
                if goesOn { fix = .lowercase }
                else if previousIsName && !["it", "it's", "you", "we", "they", "he", "she", "and", "but"].contains(lower) { fix = nil }
                else { fix = .period }
            } else if commonVerbs.contains(lower) {
                if verbSlots.contains(previous) { fix = previous != "to" || objects.contains(following) ? .lowercase : nil }
                else { fix = goesOn || previousIsName ? nil : .period }
            } else {
                fix = nil
            }
            switch fix {
            case .lowercase:
                if let range = Range(match.range(at: 2), in: out) { out.replaceSubrange(range, with: word.lowercased()) }
            case .period, .comma:
                let lowered = fix == .comma ? word.lowercased() : word
                if let range = Range(NSRange(location: gapStart, length: match.range(at: 2).upperBound - gapStart), in: out) {
                    out.replaceSubrange(range, with: (fix == .comma ? "," : ".") + ns.substring(with: match.range(at: 1)) + lowered)
                }
            case nil:
                continue
            }
        }
        return out
    }
}
