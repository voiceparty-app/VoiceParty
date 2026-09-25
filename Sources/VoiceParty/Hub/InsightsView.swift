import SwiftUI
import VoicePartyCore

struct InsightsView: View {
    @Bindable var app: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                PageHeader(title: "Insights", subtitle: "Computed from your local history.")

                HStack(alignment: .top, spacing: 16) {
                    Card(fillsHeight: true) {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("\(app.stats.wordsPerMinute)").font(Theme.display(34))
                            Text("WORDS PER MINUTE").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary).tracking(0.5)
                            SpeedGauge(wpm: app.stats.wordsPerMinute)
                                .frame(height: 70)
                        }
                    }
                    Card(fillsHeight: true) {
                        VStack(alignment: .leading, spacing: 10) {
                            Text((app.stats.wordsCorrected + app.stats.dictionaryFixes).formatted()).font(Theme.display(34))
                            Text("FIXES MADE").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary).tracking(0.5)
                            Divider()
                            fixRow("words cleaned up", app.stats.wordsCorrected)
                            fixRow("dictionary fixes", app.stats.dictionaryFixes)
                        }
                    }
                    Card(fillsHeight: true) {
                        VStack(alignment: .leading, spacing: 10) {
                            Text(app.stats.totalWords.formatted()).font(Theme.display(34))
                            Text("WORDS DICTATED").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary).tracking(0.5)
                            Divider()
                            Text(milestone(app.stats.totalWords)).font(.system(size: 13)).foregroundStyle(.secondary)
                            Text("\(app.stats.dictationCount.formatted()) dictations").font(.system(size: 13)).foregroundStyle(.secondary)
                        }
                    }
                }
                .fixedSize(horizontal: false, vertical: true)

                HStack(alignment: .top, spacing: 16) {
                    Card(fillsHeight: true) {
                        VStack(alignment: .leading, spacing: 14) {
                            HStack {
                                Text("Usage by app").font(Theme.display(22))
                                Spacer()
                                Text("APPS USED | \(app.stats.appsUsed)").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                            }
                            CategoryBars(stats: app.stats)
                        }
                    }
                    Card(fillsHeight: true) {
                        VStack(alignment: .leading, spacing: 14) {
                            HStack {
                                Text("\(app.stats.dayStreak) day streak").font(Theme.display(22))
                                Spacer()
                                Text("LONGEST | \(app.stats.longestStreak) DAYS").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                            }
                            StreakHeatmap(wordsByDay: app.stats.wordsByDay)
                        }
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
            }
            .hubPageLayout()
        }
    }

    private func fixRow(_ label: String, _ value: Int) -> some View {
        HStack {
            Text("\(value.formatted()) \(label)").font(.system(size: 13))
            Spacer()
        }
    }

    private func milestone(_ words: Int) -> String {
        switch words {
        case ..<500: "Keep going — your first page is \(500 - words) words away."
        case ..<50_000: "That's about \(words / 250) pages of writing."
        default: "That's \(words / 60_000) complete books!"
        }
    }
}

private struct SpeedGauge: View {
    var wpm: Int
    var body: some View {
        GeometryReader { geo in
            let fraction = min(1, Double(wpm) / 200)
            ZStack {
                Circle().trim(from: 0.5, to: 1).stroke(Theme.well, style: StrokeStyle(lineWidth: 12, lineCap: .round))
                Circle().trim(from: 0.5, to: 0.5 + fraction / 2).stroke(Theme.accent, style: StrokeStyle(lineWidth: 12, lineCap: .round))
                Text(wpm >= 100 ? "3× typing" : wpm > 0 ? "vs ~40 typing" : "—")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .offset(y: geo.size.width * 0.12)
            }
            .frame(width: geo.size.height * 2, height: geo.size.height * 2)
            .offset(y: geo.size.height / 2)
            .frame(maxWidth: .infinity)
        }
        .clipped()
    }
}

private struct CategoryBars: View {
    var stats: UsageStats

    var body: some View {
        let total = max(1, stats.countByCategory.values.reduce(0, +))
        let rows = AppCategory.allCases.map { ($0, stats.countByCategory[$0] ?? 0) }.sorted { $0.1 > $1.1 }
        VStack(spacing: 10) {
            ForEach(rows, id: \.0) { category, count in
                HStack(spacing: 10) {
                    let pct = Int((Double(count) / Double(total) * 100).rounded())
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 4).fill(Theme.accentSoft).frame(width: 150, height: 22)
                        RoundedRectangle(cornerRadius: 4).fill(Theme.accent).frame(width: max(30, 150 * Double(count) / Double(total)), height: 22)
                        Text("\(pct)%").font(.system(size: 11, weight: .semibold)).foregroundStyle(.white).padding(.leading, 6)
                    }
                    Text("\(count.formatted()) \(category.displayName.uppercased())").font(.system(size: 12, weight: .medium))
                    Spacer()
                }
            }
        }
    }
}

private struct StreakHeatmap: View {
    var wordsByDay: [Date: Int]
    private let cell: CGFloat = 14, gap: CGFloat = 3, labelWidth: CGFloat = 26

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // As many weeks as fit, so the grid spans the card's full width.
            GeometryReader { geometry in
                grid(weeks: max(4, Int((geometry.size.width - labelWidth) / (cell + gap))))
            }
            .frame(height: 7 * cell + 6 * gap)
            HStack(spacing: 4) {
                Text("Less").font(.system(size: 10)).foregroundStyle(.secondary)
                ForEach([0.0, 0.35, 0.65, 1.0], id: \.self) { o in
                    RoundedRectangle(cornerRadius: 2).fill(o == 0 ? Theme.well : Theme.accent.opacity(o)).frame(width: 10, height: 10)
                }
                Text("More").font(.system(size: 10)).foregroundStyle(.secondary)
            }
        }
    }

    private func grid(weeks: Int) -> some View {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let weekday = calendar.component(.weekday, from: today) - 1
        let start = calendar.date(byAdding: .day, value: -(weeks - 1) * 7 - weekday, to: today)!
        let maxWords = max(1, wordsByDay.values.max() ?? 1)
        return HStack(alignment: .top, spacing: gap) {
            VStack(alignment: .leading, spacing: gap) {
                ForEach(["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"], id: \.self) {
                    Text($0).font(.system(size: 9)).foregroundStyle(.secondary).frame(width: labelWidth - gap, height: cell, alignment: .leading)
                }
            }
            ForEach(0..<weeks, id: \.self) { week in
                VStack(spacing: gap) {
                    ForEach(0..<7, id: \.self) { day in
                        let date = calendar.date(byAdding: .day, value: week * 7 + day, to: start)!
                        let words = wordsByDay[date] ?? 0
                        RoundedRectangle(cornerRadius: 3)
                            .fill(date > today ? Color.clear : words == 0 ? Theme.well : Theme.accent.opacity(0.3 + 0.7 * Double(words) / Double(maxWords)))
                            .frame(width: cell, height: cell)
                            .help(words > 0 ? "\(words) words · \(date.formatted(date: .abbreviated, time: .omitted))" : "")
                    }
                }
            }
        }
    }
}
