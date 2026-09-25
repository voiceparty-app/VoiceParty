import Foundation

/// Turns a meeting transcript into notes with whichever on-device model is available (the caller passes a
/// `transform(text, instructions)`, e.g. the local Qwen server or Apple Intelligence). Long meetings are
/// summarized a part at a time, then the part notes are combined, so any context window works.
public enum NoteSummarizer {
    public struct Notes: Equatable, Sendable {
        public var title: String?
        public var summary: String
        public var decisions: [String]
        public var actionItems: [String]
    }

    static let format = """
    Reply in exactly this format:
    Title: <a short title for the meeting, 3-7 words>
    Summary:
    - <the key points, one per line, specific: names, numbers, dates>
    Decisions:
    - <each decision made, or "None">
    Action items:
    - <Owner: task, with a due date if one was said; or "None">
    """

    public static let instructions = """
    This is a meeting transcript. Lines starting "You:" were said by the person taking the notes; lines \
    starting "Others:" were said by the other people on the call. Write useful meeting notes. Attribute \
    proposals and tasks to whoever actually said or took them ("You" or the named person). Use only what the \
    transcript says; don't invent names, dates or tasks. Be concise.
    """ + "\n" + format

    static let partInstructions = """
    This is one part of a longer meeting transcript. "You" is the note taker; "Others" is everyone else. List \
    the key points, decisions and action items (with owners) from this part as short bullets. Use only what \
    the transcript says.
    """

    static let combineInstructions = """
    These are notes from consecutive parts of one meeting. Combine them into the notes for the whole meeting, \
    merging duplicates. Use only what the notes say.
    """ + "\n" + format

    /// The meeting's calendar title, attendees and the note taker's own notes, put ahead of the transcript.
    public static func context(title: String?, attendees: [String], userNotes: String?) -> String? {
        var lines: [String] = []
        if let title, !title.isEmpty { lines.append("Meeting: \(title)") }
        if !attendees.isEmpty { lines.append("Attendees: \(attendees.joined(separator: ", "))") }
        if let notes = userNotes?.trimmingCharacters(in: .whitespacesAndNewlines), !notes.isEmpty {
            lines.append("The note taker's own notes (most important):\n\(notes)")
        }
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }

    /// Summarizes `transcript`; `partWords` bounds each model call's input. `context` (see `context(…)`) goes
    /// first, so names are spelled like the invite and the note taker's own notes shape the result.
    public static func summarize(transcript: String, context: String? = nil, partWords: Int = 1_600,
                                 transform: @Sendable (String, String) async throws -> String) async throws -> Notes {
        func withContext(_ body: String, label: String) -> String {
            guard let context else { return body }
            return context + "\n\n" + label + ":\n" + body
        }
        let parts = split(transcript, maxWords: partWords)
        if parts.count <= 1 {
            return parse(try await transform(withContext(transcript, label: "Transcript"), instructions))
        }
        var partNotes: [String] = []
        for part in parts { partNotes.append(try await transform(part, partInstructions)) }
        return parse(try await transform(withContext(partNotes.joined(separator: "\n\n"), label: "Notes from each part"), combineInstructions))
    }

    /// The calendar's title wins (it's what the meeting is called), then the model's, then a fallback.
    public static func finalTitle(calendar: String?, model: String?, fallback: String) -> String {
        [calendar, model].compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }.first { !$0.isEmpty } ?? fallback
    }

    /// Splits at line (turn) boundaries into pieces of at most `maxWords` words.
    static func split(_ transcript: String, maxWords: Int) -> [String] {
        var parts: [String] = [], current: [String] = [], words = 0
        for line in transcript.components(separatedBy: "\n") where !line.isEmpty {
            let count = TextTools.wordCount(line)
            if words + count > maxWords && !current.isEmpty {
                parts.append(current.joined(separator: "\n"))
                current = []
                words = 0
            }
            current.append(line)
            words += count
        }
        if !current.isEmpty { parts.append(current.joined(separator: "\n")) }
        return parts
    }

    /// Reads the model's reply; tolerant of Markdown headings, bold labels and missing sections.
    public static func parse(_ reply: String) -> Notes {
        enum Section { case none, summary, decisions, actions }
        var title: String?, section = Section.none
        var summary: [String] = [], decisions: [String] = [], actions: [String] = []
        for raw in reply.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            let label = line.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "#*: "))
            if label.hasPrefix("title") && line.contains(":") {
                title = line.split(separator: ":", maxSplits: 1).last.map { $0.trimmingCharacters(in: CharacterSet(charactersIn: " *#")) }
                continue
            }
            switch label {
            case "summary", "key points": section = .summary; continue
            case "decisions": section = .decisions; continue
            case "action items", "action items / next steps", "next steps", "to-dos", "todos": section = .actions; continue
            default: break
            }
            guard !line.isEmpty else { continue }
            let item = line.replacingOccurrences(of: #"^(?:[-*•]\s*)?(?:\[[ xX]?\]\s*)?(?:\d+[.)]\s+)?"#, with: "", options: .regularExpression)
            let isNone = item.lowercased().trimmingCharacters(in: .punctuationCharacters) == "none"
            switch section {
            case .summary: summary.append("- " + item)
            case .decisions: if !isNone { decisions.append(item) }
            case .actions: if !isNone { actions.append(item) }
            case .none: summary.append("- " + item) // no headings at all: treat it all as the summary
            }
        }
        return Notes(title: title?.isEmpty == false ? title : nil, summary: summary.joined(separator: "\n"),
                     decisions: decisions, actionItems: actions)
    }

    /// "Started by mistake?": hardly anything was said.
    public static func isTooShortToKeep(words: Int) -> Bool { words < 20 }
}
