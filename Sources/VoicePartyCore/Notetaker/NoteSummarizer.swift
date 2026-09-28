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

    /// An action item line of the reply, whole meeting or part.
    static let actionItem = #"- <Owner: task, with a due date if one was said ("You: …" for the note taker's own); or "None">"#

    static let format = """
    Reply in exactly this format:
    Title: <a short title for the meeting, 3-7 words>
    Summary:
    - <the key points, one per line, specific: names, numbers, dates>
    Decisions:
    - <each decision made, or "None">
    Action items:
    \(actionItem)
    """

    /// Who "You" and "Others" are and whose tasks are whose; every call ends its instructions with it (parts and the
    /// combine too). Without it every model tried gave the note taker's own "I'll do the screenshots" to whoever spoke
    /// just before. The example line and "Keep owners' names exactly as said" each helped Qwen3-4B, and it works best
    /// after the other instructions (first, the notes lost facts; right before the transcript, they dropped tasks).
    static let speakers = """
    Speakers: "You" is the person taking these notes; every "You:" line is them, so "I'll…" on a "You:" line is \
    a task for "You", even right after someone else spoke: after "Others: This is <name>. We need <X>." the line \
    "You: I'll do <X>." gives "You: <X>". "Others:" lines are the other people; there "I" is whoever is speaking \
    (the name they give, as in "This is <name>", or the person "You" just asked), never "You". Keep owners' names \
    exactly as said.
    """

    public static let instructions = """
    This is a meeting transcript. Write useful meeting notes. Use only what the transcript says; don't invent names, \
    dates or tasks. Be concise. \(speakers)
    """ + "\n" + format

    /// Part notes keep the reply's sections, so the combine still sees which bullets are decisions and whose tasks are whose.
    static let partInstructions = """
    This is one part of a longer meeting transcript. Note its key points, decisions and action items as short \
    bullets. Use only what the transcript says. \(speakers)
    Reply in this format:
    Key points:
    - <specific: names, numbers, dates>
    Decisions:
    - <each decision made, or "None">
    Action items:
    \(actionItem)
    """

    static let combineInstructions = """
    These are notes from consecutive parts of one meeting. Combine them into the notes for the whole meeting, \
    merging duplicates and keeping each task's owner. Use only what the notes say. \(speakers)
    """ + "\n" + format

    /// The meeting's calendar title, attendees and the note taker's own notes, put ahead of the transcript.
    public static func context(title: String?, attendees: [String], userNotes: String?) -> String? {
        var lines: [String] = []
        if let title, !title.isEmpty { lines.append("Meeting: \(title)") }
        // You're never among them (CalendarReader leaves out the current user); under a bare "Attendees:" the model
        // took "You" for one of them and gave them your tasks.
        if !attendees.isEmpty {
            lines.append(#"Other attendees (on the "Others:" lines; "You" is the note taker): "# + attendees.joined(separator: ", "))
        }
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
        var owner: String? // "- You:" on a line of its own, with that person's tasks listed under it
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
            case "action items", "action items / next steps", "next steps", "to-dos", "todos": section = .actions; owner = nil; continue
            default: break
            }
            guard !line.isEmpty else { continue }
            let item = line.replacingOccurrences(of: #"^(?:[-*•]\s*)?(?:\[[ xX]?\]\s*)?(?:\d+[.)]\s+)?"#, with: "", options: .regularExpression)
            let named = owned(item)
            // "None", or "Others: None" (someone with nothing to do).
            let isNone = (named?.task ?? item).lowercased().trimmingCharacters(in: .punctuationCharacters) == "none"
            switch section {
            case .summary: summary.append("- " + item)
            case .decisions: if !isNone { decisions.append(item) }
            case .actions:
                if let heading = ownerHeading(item) { owner = heading; continue }
                if let named { owner = nil; if !isNone { actions.append("\(named.owner): \(named.task)") }; continue }
                if !isNone { actions.append(owner.map { "\($0): \(item)" } ?? item) }
            case .none: summary.append("- " + item) // no headings at all: treat it all as the summary
            }
        }
        return Notes(title: title?.isEmpty == false ? title : nil, summary: summary.joined(separator: "\n"),
                     decisions: decisions, actionItems: actions)
    }

    /// "Priya: look into the login timeout" (or "**Priya:** …") → ("Priya", "look into the login timeout"); a name
    /// is 1–4 words, and a space follows the colon ("at 10:30" has no owner).
    static func owned(_ item: String) -> (owner: String, task: String)? {
        guard let colon = item.firstIndex(of: ":") else { return nil }
        let name = item[..<colon].trimmingCharacters(in: CharacterSet(charactersIn: "* "))
        let rest = item[item.index(after: colon)...].drop { $0 == "*" }
        let task = rest.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, !task.isEmpty, rest.first?.isWhitespace == true, TextTools.wordCount(name) <= 4 else { return nil }
        return (name, task)
    }

    /// "You:" or "**Lena:**" alone on a line: the tasks below it are theirs.
    static func ownerHeading(_ item: String) -> String? {
        let text = item.trimmingCharacters(in: CharacterSet(charactersIn: "* "))
        guard text.hasSuffix(":") else { return nil }
        let name = text.dropLast().trimmingCharacters(in: CharacterSet(charactersIn: "* "))
        return !name.isEmpty && TextTools.wordCount(name) <= 4 ? name : nil
    }

    /// "Started by mistake?": hardly anything was said.
    public static func isTooShortToKeep(words: Int) -> Bool { words < 20 }
}
