import Foundation

/// A meeting recorded by the Notetaker: who said what (you on the mic, everyone else from the computer's
/// audio), plus the notes written from it. Stored locally like everything else.
public struct MeetingNote: Codable, Hashable, Sendable, Identifiable {
    public enum Status: String, Codable, Sendable {
        case recording, transcribing, summarizing, ready, failed
    }

    /// VoiceParty quit or crashed before this note was finished: transcribe it again from its audio.
    public var needsRecovery: Bool { [.recording, .transcribing, .summarizing].contains(status) }

    public var id: UUID
    public var title: String
    public var startedAt: Date
    public var endedAt: Date?
    /// The meeting app, when one was detected (Zoom, Teams, FaceTime…).
    public var appName: String?
    public var status: Status
    public var segments: [NoteSegment]
    /// Markdown bullets.
    public var summary: String?
    public var decisions: [String]
    public var actionItems: [String]
    public var micAudioPath: String?
    public var systemAudioPath: String?
    /// People on the calendar invite (helps spell names; shown with the notes).
    public var attendees: [String]
    /// What you typed in the notepad during the meeting.
    public var userNotes: String?

    public init(id: UUID = UUID(), title: String, startedAt: Date, status: Status = .recording) {
        self.id = id
        self.title = title
        self.startedAt = startedAt
        self.status = status
        segments = []
        decisions = []
        actionItems = []
        attendees = []
    }

    public var duration: TimeInterval { (endedAt ?? Date()).timeIntervalSince(startedAt) }
    public var wordCount: Int { segments.reduce(0) { $0 + TextTools.wordCount($1.text) } }

    /// The whole note as Markdown (for copying into a doc, an email, or an AI chat).
    public func markdown(timeZone: TimeZone = .current) -> String {
        var date = Date.FormatStyle(date: .abbreviated, time: .shortened)
        date.timeZone = timeZone
        var lines = ["# \(title)", "", "\(startedAt.formatted(date)) · \(Self.minutes(duration))"]
        if !attendees.isEmpty { lines.append("With \(attendees.joined(separator: ", "))") }
        if let summary, !summary.isEmpty { lines += ["", "## Summary", summary] }
        if !decisions.isEmpty { lines += ["", "## Decisions"] + decisions.map { "- \($0)" } }
        if !actionItems.isEmpty { lines += ["", "## Action items"] + actionItems.map { "- [ ] \($0)" } }
        if let userNotes, !userNotes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            lines += ["", "## Your notes", userNotes.trimmingCharacters(in: .whitespacesAndNewlines)]
        }
        if !segments.isEmpty {
            lines += ["", "## Transcript"] + segments.map { "**\($0.speaker.label)** (\(Self.clock($0.start))): \($0.text)" }
        }
        return lines.joined(separator: "\n")
    }

    static func minutes(_ seconds: TimeInterval) -> String {
        let m = Int((seconds / 60).rounded())
        return m < 1 ? "under a minute" : m < 60 ? "\(m) min" : "\(m / 60) h \(m % 60) min"
    }

    static func clock(_ seconds: TimeInterval) -> String {
        let s = Int(seconds)
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60) : String(format: "%02d:%02d", s / 60, s % 60)
    }
}

public struct NoteSegment: Codable, Hashable, Sendable {
    public enum Speaker: String, Codable, Sendable {
        /// The microphone: the person using VoiceParty.
        case me
        /// The computer's audio: everyone else on the call.
        case others

        public var label: String { self == .me ? "You" : "Others" }
    }

    public var speaker: Speaker
    /// Seconds from the start of the meeting.
    public var start: TimeInterval
    public var end: TimeInterval
    public var text: String

    public init(speaker: Speaker, start: TimeInterval, end: TimeInterval, text: String) {
        self.speaker = speaker
        self.start = start
        self.end = end
        self.text = text
    }
}
