import Foundation

/// Picks the cheapest cleanup that will do the job, so most dictations stay fast:
/// `.skip` (rules only) when the text is already clean, `.fast` (a tiny cleanup model) for ordinary
/// disfluent speech, `.strong` (a general instruction model) when dictionary terms, code, email
/// layout, prompts to AI apps or heavier editing are involved.
public enum PolishRouter {
    public enum Route: Equatable, Sendable { case skip, fast, strong }

    static let fillers: Set<String> = ["um", "uh", "umm", "uhm", "erm", "er", "hmm", "mm", "ah"]
    static let cuePhrases = [
        "actually", "no wait", "wait no", "scratch that", "i mean", "you know", "sorry", "make that", "rather",
        "first", "second", "third", "comma", "period", "question mark", "new line", "like",
    ]
    /// Spoken quantities worth normalizing ("forty five thousand", "seven thirty", "ten percent").
    static let numberWords: Set<String> = [
        "hundred", "thousand", "million", "billion", "percent", "dollars", "thirty", "fifteen", "forty-five", "o'clock",
    ]

    public static func route(text: String, category: AppCategory, level: CleanupLevel, relevantVocabulary: [String]) -> Route {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .skip }
        if needsStrong(category: category, level: level, relevantVocabulary: relevantVocabulary) || hasCorrection(trimmed) {
            return needsWork(trimmed) || category == .email || level == .medium || !relevantVocabulary.isEmpty ? .strong : .skip
        }
        return needsWork(trimmed) ? .fast : .skip
    }

    static func needsStrong(category: AppCategory, level: CleanupLevel, relevantVocabulary: [String]) -> Bool {
        level == .medium || !relevantVocabulary.isEmpty || [.email, .code].contains(category)
    }

    /// Spoken self-corrections: the strong model resolves these much more reliably (fixtures: backtrack cases).
    static func hasCorrection(_ text: String) -> Bool {
        let spaced = " " + TextTools.normalizedTokens(text).joined(separator: " ") + " "
        return [" actually ", " scratch that ", " no wait ", " wait no ", " i mean ", " make that ", " sorry "].contains { spaced.contains($0) }
    }

    /// Whether anything in the text looks like it needs a model: fillers, corrections, repeats,
    /// spoken lists/numbers/punctuation, or a long unpunctuated run.
    static func needsWork(_ text: String) -> Bool {
        let tokens = TextTools.normalizedTokens(text)
        guard !tokens.isEmpty else { return false }
        if tokens.contains(where: fillers.contains) { return true }
        for i in 1..<max(tokens.count, 1) where tokens[i] == tokens[i - 1] { return true }
        let spaced = " " + tokens.joined(separator: " ") + " "
        if cuePhrases.contains(where: { spaced.contains(" \($0) ") }) { return true }
        if tokens.contains(where: numberWords.contains) { return true }
        // Unpunctuated: the engine gave no sentence punctuation for a multi-word utterance.
        let punctuation = text.filter { ".,?!;:".contains($0) }.count
        if tokens.count >= 5 && punctuation == 0 { return true }
        // Long sentences without commas are usually run-ons the recognizer didn't break up.
        let sentences = text.split(whereSeparator: { ".?!".contains($0) })
        if sentences.contains(where: { TextTools.wordCount(String($0)) >= 18 && !$0.contains(",") }) { return true }
        return false
    }
}

/// The input contract of Superwhisper's S1-mini cleanup model (system prompt + control line, verbatim).
public enum S1MiniFormat {
    public static let systemPrompt = "You are a text normalizer for speech-to-text transcripts. The input begins with a control line specifying the styling, structure, and context settings; clean the transcript to match those settings and output only the cleaned text."

    public static func controlLine(style: WritingStyle, category: AppCategory, transcript: String = "") -> String {
        let styling: String
        switch style {
        case .formal, .excited, .casual: styling = "semi-formal"
        case .veryCasual: styling = "semi-casual"
        }
        let context = category == .email ? "email" : "general"
        // Only spoken enumerations become lists; "grab milk, eggs and bread" stays a sentence.
        let tokens = Set(TextTools.normalizedTokens(transcript))
        let structure = tokens.contains("first") && tokens.contains("second") ? "lists" : "prose"
        return "[Styling: \(styling)] [Structure: \(structure)] [Context: \(context)]"
    }

    public static func userMessage(transcript: String, style: WritingStyle, category: AppCategory) -> String {
        controlLine(style: style, category: category, transcript: transcript) + "\n" + transcript
    }

    /// S1-mini writes Markdown bullets; spoken ordinals ("first… second…") read better as a numbered list.
    public static func postProcess(_ output: String, raw: String) -> String {
        let rawTokens = Set(TextTools.normalizedTokens(raw))
        guard rawTokens.contains("first"), rawTokens.contains("second") else { return output }
        var number = 0
        return output.split(separator: "\n", omittingEmptySubsequences: false).map { line -> String in
            let trimmed = line.drop { $0 == " " }
            if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") || trimmed.hasPrefix("• ") {
                number += 1
                return "\(number). " + trimmed.dropFirst(2)
            }
            return String(line)
        }.joined(separator: "\n")
    }
}
