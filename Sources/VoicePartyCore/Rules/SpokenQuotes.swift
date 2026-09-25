import Foundation

/// Quotation marks said out loud: "quote unquote fixing" → "fixing" in quotes, and "quote … end quote"
/// (or "open quote … close quote", "quote … unquote") around a phrase. "Quote" as a word ("send me a quote",
/// "I'll quote you") is left alone: only the paired forms are commands.
public enum SpokenQuotes {
    /// Longest phrase between "quote" and "end quote" (a missing "end quote" shouldn't quote half the dictation).
    static let maxWords = 12

    public static func apply(_ text: String) -> String {
        var out = text
        // "quote unquote X" / "quote, unquote, X" / "quote-unquote X": the next word (hyphenated words count as one).
        out = TextTools.replacing(out, pattern: #"\bquote[,]?[ \t-]+unquote\b[,]?[ \t]+([\p{L}\p{N}][\p{L}\p{N}'’]*(?:-[\p{L}\p{N}]+)*)"#,
                                  with: "\"$1\"")
        // "(open) quote … end quote / close quote / unquote", unless "quote" is the noun ("a quote", "the quote").
        let determiners = #"(?<!\ba )(?<!\ban )(?<!\bthe )(?<!\bthis )(?<!\bthat )(?<!\bhis )(?<!\bher )(?<!\bmy )(?<!\byour )(?<!\bour )(?<!\btheir )"#
        let pattern = determiners + #"\b(?:open[ \t]+)?quote[,:]?[ \t]+((?:[^ \t\n"]+[ \t]+){0,"# + String(maxWords - 1)
            + #"}?[^ \t\n"]+?)[,]?[ \t]+(?:end[ \t]+quote|close[ \t]+quote|unquote)\b"#
        out = TextTools.replacing(out, pattern: pattern, with: "\"$1\"")
        return out
    }
}
