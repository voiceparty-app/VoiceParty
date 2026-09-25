import Foundation

/// Numbers for the Home stats card and the Insights tab, computed from history.
public struct UsageStats: Sendable, Equatable {
    public var totalWords: Int
    public var wordsPerMinute: Int
    public var dayStreak: Int
    public var longestStreak: Int
    public var wordsCorrected: Int
    public var dictionaryFixes: Int
    public var dictationCount: Int
    public var wordsByCategory: [AppCategory: Int]
    public var countByCategory: [AppCategory: Int]
    public var appsUsed: Int
    /// Words per calendar day (start of day → words), for the streak heatmap.
    public var wordsByDay: [Date: Int]

    public static func compute(from history: [HistoryItem], now: Date = Date(), calendar: Calendar = .current) -> UsageStats {
        let items = history.filter { $0.status != .cancelled && $0.status != .empty && $0.wordCount > 0 }

        // WPM: last 100 dictations under 400 s, words over speaking time.
        let recent = items.sorted { $0.createdAt > $1.createdAt }.filter { $0.duration < 400 && $0.speechDuration > 0.5 }.prefix(100)
        let words = recent.reduce(0) { $0 + $1.wordCount }
        let minutes = recent.reduce(0.0) { $0 + $1.speechDuration } / 60
        let wpm = minutes > 0 ? Int((Double(words) / minutes).rounded()) : 0

        var byDay: [Date: Int] = [:]
        var byCategory: [AppCategory: Int] = [:]
        var countByCategory: [AppCategory: Int] = [:]
        for item in items {
            byDay[calendar.startOfDay(for: item.createdAt), default: 0] += item.wordCount
            byCategory[item.category, default: 0] += item.wordCount
            countByCategory[item.category, default: 0] += 1
        }

        return UsageStats(
            totalWords: items.reduce(0) { $0 + $1.wordCount },
            wordsPerMinute: wpm,
            dayStreak: currentStreak(days: Set(byDay.keys), now: now, calendar: calendar),
            longestStreak: longestStreak(days: Set(byDay.keys), calendar: calendar),
            wordsCorrected: items.reduce(0) { $0 + $1.wordsCorrected },
            dictionaryFixes: items.reduce(0) { $0 + $1.dictionaryReplacements },
            dictationCount: items.count,
            wordsByCategory: byCategory,
            countByCategory: countByCategory,
            appsUsed: Set(items.compactMap(\.appBundleID)).count,
            wordsByDay: byDay
        )
    }

    /// Consecutive days ending today (or yesterday, so the streak survives until you dictate today).
    static func currentStreak(days: Set<Date>, now: Date, calendar: Calendar) -> Int {
        var day = calendar.startOfDay(for: now)
        if !days.contains(day) {
            guard let yesterday = calendar.date(byAdding: .day, value: -1, to: day), days.contains(yesterday) else { return 0 }
            day = yesterday
        }
        var streak = 0
        while days.contains(day) {
            streak += 1
            guard let previous = calendar.date(byAdding: .day, value: -1, to: day) else { break }
            day = previous
        }
        return streak
    }

    static func longestStreak(days: Set<Date>, calendar: Calendar) -> Int {
        var longest = 0
        for day in days {
            guard let previous = calendar.date(byAdding: .day, value: -1, to: day), !days.contains(previous) else { continue }
            var length = 1
            var next = calendar.date(byAdding: .day, value: 1, to: day)
            while let n = next, days.contains(n) {
                length += 1
                next = calendar.date(byAdding: .day, value: 1, to: n)
            }
            longest = max(longest, length)
        }
        return longest
    }
}
