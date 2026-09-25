import EventKit
import Foundation
import VoicePartyCore

/// The calendar event a meeting belongs to, read on this Mac (EventKit). Asks for Calendar access the
/// first time; if it's declined, notes just aren't titled from the calendar.
@MainActor
enum CalendarReader {
    private static let store = EKEventStore()

    static func currentMeeting(at now: Date = Date()) async -> CalendarEventInfo? {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .notDetermined:
            guard (try? await store.requestFullAccessToEvents()) == true else { return nil }
        case .fullAccess:
            break
        default:
            return nil
        }
        let window = store.predicateForEvents(withStart: now.addingTimeInterval(-4 * 3600), end: now.addingTimeInterval(3600), calendars: nil)
        let events = store.events(matching: window).map { event in
            let text = [event.location, event.url?.absoluteString, event.notes].compactMap { $0 }.joined(separator: " ")
            let people = (event.attendees ?? []).filter { !$0.isCurrentUser }.compactMap { participant -> String? in
                if let name = participant.name, !name.isEmpty, !name.contains("@") { return name }
                // No display name: the part of the address before the @ ("sam.lee" → "Sam Lee").
                let address = participant.url.absoluteString.replacingOccurrences(of: "mailto:", with: "")
                guard let local = address.split(separator: "@").first, !local.isEmpty else { return nil }
                return local.split(whereSeparator: { ".-_".contains($0) }).map { $0.capitalized }.joined(separator: " ")
            }
            return CalendarEventInfo(title: event.title ?? "", start: event.startDate, end: event.endDate, isAllDay: event.isAllDay,
                                     attendees: people, hasMeetingLink: CalendarMatch.hasMeetingLink(text))
        }
        return CalendarMatch.best(in: events, at: now)
    }

    /// Debug: whether Calendar access works in this build (hardened runtime needs the calendars entitlement).
    /// Counts only; no titles or attendees leave this function.
    static func accessReport() -> [String: Any] {
        let status = EKEventStore.authorizationStatus(for: .event)
        var report: [String: Any] = ["status": String(describing: status.rawValue), "fullAccess": status == .fullAccess]
        if status == .fullAccess {
            let day = store.predicateForEvents(withStart: Date().addingTimeInterval(-7 * 86_400), end: Date().addingTimeInterval(7 * 86_400), calendars: nil)
            report["calendars"] = store.calendars(for: .event).count
            report["eventsThisFortnight"] = store.events(matching: day).count
        }
        return report
    }
}
