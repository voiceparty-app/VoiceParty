import Foundation

/// Splits long dictations into pieces a cleanup model handles well: whole sentences, at most `maxWords`
/// words each. Chunks keep their trailing whitespace, so `chunks.joined()` is the original text.
public enum TextChunker {
    public static func split(_ text: String, maxWords: Int) -> [String] {
        guard TextTools.wordCount(text) > maxWords else { return [text] }
        var chunks: [String] = []
        var current = ""
        for piece in sentences(in: text).flatMap({ wordRuns($0, maxWords: maxWords) }) {
            if !current.isEmpty && TextTools.wordCount(current) + TextTools.wordCount(piece) > maxWords {
                chunks.append(current)
                current = ""
            }
            current += piece
        }
        if !current.isEmpty { chunks.append(current) }
        return chunks
    }

    /// Sentences (ending in . ! ? or a line break) with the whitespace that follows them.
    static func sentences(in text: String) -> [String] {
        guard let re = TextTools.regex(#"[^.!?\n]*(?:[.!?]+|\n|$)\s*"#) else { return [text] }
        let ns = text as NSString
        return re.matches(in: text, range: NSRange(location: 0, length: ns.length))
            .filter { $0.range.length > 0 }
            .map { ns.substring(with: $0.range) }
    }

    /// A sentence longer than `maxWords` (usually unpunctuated speech) is cut between words.
    static func wordRuns(_ sentence: String, maxWords: Int) -> [String] {
        guard TextTools.wordCount(sentence) > maxWords, let re = TextTools.regex(#"\S+\s*"#) else { return [sentence] }
        let ns = sentence as NSString
        let words = re.matches(in: sentence, range: NSRange(location: 0, length: ns.length)).map { ns.substring(with: $0.range) }
        let leading = String(sentence.prefix { $0.isWhitespace })
        var runs = stride(from: 0, to: words.count, by: maxWords).map { words[$0..<min($0 + maxWords, words.count)].joined() }
        if !leading.isEmpty, !runs.isEmpty { runs[0] = leading + runs[0] }
        return runs
    }
}

/// One dictation records for at most 20 minutes, with a warning a minute before.
public enum RecordingLimit {
    public static let maximum: Duration = .seconds(20 * 60)
    public static let warning: Duration = .seconds(19 * 60)

    /// How long to wait for the recognizer to finish: long recordings take longer to transcribe in one pass.
    public static func transcriptionTimeout(forSeconds seconds: TimeInterval) -> Duration {
        .seconds(max(15, Int((seconds / 10).rounded(.up))))
    }
}
