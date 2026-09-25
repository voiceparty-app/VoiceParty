import Foundation

/// A calendar event, reduced to what the Notetaker needs (read on this Mac through EventKit).
public struct CalendarEventInfo: Equatable, Sendable {
    public var title: String
    public var start: Date
    public var end: Date
    public var isAllDay: Bool
    public var attendees: [String]
    /// A Zoom/Meet/Teams/Webex link in the location, URL or notes.
    public var hasMeetingLink: Bool

    public init(title: String, start: Date, end: Date, isAllDay: Bool, attendees: [String], hasMeetingLink: Bool) {
        self.title = title
        self.start = start
        self.end = end
        self.isAllDay = isAllDay
        self.attendees = attendees
        self.hasMeetingLink = hasMeetingLink
    }
}

/// Which calendar event a meeting that's starting now belongs to.
public enum CalendarMatch {
    /// Timed events running now, or starting within `soon` (people join a few minutes early), preferring real
    /// calls (attendees, a meeting link) over blocks like "Focus time", then the one that started closest to now.
    public static func best(in events: [CalendarEventInfo], at now: Date, soon: TimeInterval = 300) -> CalendarEventInfo? {
        events
            .filter { !$0.isAllDay && $0.start <= now.addingTimeInterval(soon) && $0.end > now && !$0.title.isEmpty }
            .max { score($0, now) < score($1, now) }
    }

    static func score(_ event: CalendarEventInfo, _ now: Date) -> Double {
        var score = 0.0
        if !event.attendees.isEmpty { score += 2 }
        if event.hasMeetingLink { score += 2 }
        score -= abs(event.start.timeIntervalSince(now)) / 3600 // closer start wins
        return score
    }

    /// Whether text contains a video-call link.
    public static func hasMeetingLink(_ text: String) -> Bool {
        let lower = text.lowercased()
        return ["zoom.us/", "meet.google.com/", "teams.microsoft.com/", "teams.live.com/", "webex.com/", "facetime.apple.com/", "whereby.com/"]
            .contains { lower.contains($0) }
    }
}
