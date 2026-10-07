@preconcurrency import AVFoundation
import SwiftUI
import VoicePartyCore

struct HomeView: View {
    @Bindable var app: AppModel
    @State private var headerWidth: CGFloat = 800
    @State private var search = ""
    @State private var searching = false

    private var firstName: String {
        NSFullUserName().split(separator: " ").first.map(String.init) ?? ""
    }

    /// Grouped once per history change (in AppModel); only regrouped while searching.
    private var days: [HistoryDay] {
        guard !search.isEmpty else { return app.historyDays }
        return HistoryDay.group(app.history.filter {
            $0.pastedText.localizedCaseInsensitiveContains(search) || $0.rawText.localizedCaseInsensitiveContains(search)
        })
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 24) {
                PageHeader(title: firstName.isEmpty ? "Welcome back" : "Welcome back, \(firstName)") { EmptyView() }

                StatusBanners(app: app)

                // Hero and stats share top and bottom edges; in a narrow window the stats go in a row under the hero.
                Group {
                    if headerWidth >= 660 {
                        HStack(alignment: .top, spacing: 18) {
                            HeroCard(hotkey: app.pushToTalkName, showsWaveform: headerWidth - 268 >= 480)
                                .frame(maxHeight: .infinity)
                            StatsCard(stats: app.stats)
                                .frame(width: 250)
                                .frame(maxHeight: .infinity)
                        }
                        .fixedSize(horizontal: false, vertical: true)
                    } else {
                        VStack(spacing: 14) {
                            HeroCard(hotkey: app.pushToTalkName, showsWaveform: headerWidth >= 480)
                            StatsCard(stats: app.stats, inRow: true)
                        }
                    }
                }
                .frame(maxWidth: .infinity)
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { headerWidth = $0 }

                HStack {
                    Text(searching ? "SEARCH" : (days.first?.label ?? "TODAY"))
                        .font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary).tracking(0.6)
                    Spacer()
                    if searching {
                        SearchField(text: $search, prompt: "Search your dictations")
                    }
                    Button {
                        searching.toggle()
                        if !searching { search = "" }
                    } label: {
                        Image(systemName: searching ? "xmark" : "magnifyingglass").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Search your dictations")
                }

                if app.history.isEmpty {
                    EmptyHistory(hotkey: app.pushToTalkName)
                } else {
                    ForEach(days) { day in
                        if day.id != days.first?.id {
                            Text(day.label).font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary).tracking(0.6)
                        }
                        LazyVStack(spacing: 0) {
                            ForEach(day.items) { item in
                                HistoryRow(app: app, item: item, isLast: item.id == day.items.last?.id)
                            }
                        }
                        .background(RoundedRectangle(cornerRadius: 12).fill(Theme.card))
                        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.hairline))
                    }
                }
            }
            .hubPageLayout()
        }
    }
}

private struct StatusBanners: View {
    @Bindable var app: AppModel

    private var isEmpty: Bool {
        app.permissions.accessibility && app.permissions.microphone == .authorized && app.engineStatus == nil && app.engineError == nil
    }

    var body: some View {
        if !isEmpty { banners }
    }

    private var banners: some View {
        VStack(spacing: 10) {
            if !app.permissions.accessibility {
                Banner(symbol: "hand.raised", title: "Allow Accessibility access",
                       detail: "Needed for the global hotkey and to paste text into other apps.", button: "Open Settings") {
                    Permissions.promptAccessibility()
                    Permissions.openAccessibilitySettings()
                }
            }
            if app.permissions.microphone != .authorized {
                Banner(symbol: "mic.slash", title: "Allow microphone access", detail: "VoiceParty can't hear you yet.", button: "Allow") {
                    Task {
                        if await Permissions.requestMicrophone() == false { Permissions.openMicrophoneSettings() }
                        app.permissions = .current()
                    }
                }
            }
            if let status = app.engineStatus {
                Banner(symbol: "arrow.down.circle", title: status, detail: "One-time download from Apple; recognition then runs fully offline.", button: nil, action: {})
            }
            if let error = app.engineError {
                Banner(symbol: "exclamationmark.triangle", title: "Speech model problem", detail: error, button: "Retry") { app.prepareEngine() }
            }
        }
    }
}

private struct Banner: View {
    var symbol: String
    var title: String
    var detail: String
    var button: String?
    var action: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: symbol).font(.system(size: 18)).foregroundStyle(Theme.highlight).frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13, weight: .semibold))
                Text(detail).font(.system(size: 12)).foregroundStyle(.secondary)
            }
            Spacer()
            if let button { Button(button, action: action).buttonStyle(PrimaryButtonStyle()) }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 12).fill(Theme.highlight.opacity(0.1)))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.highlight.opacity(0.35)))
    }
}

private struct HeroCard: View {
    var hotkey: String
    /// The decorative waveform, when the card is wide enough that the text doesn't have to squeeze past it.
    var showsWaveform = true

    var body: some View {
        ZStack(alignment: .leading) {
            LinearGradient(colors: [Color(red: 0.07, green: 0.09, blue: 0.09), Color(red: 0.12, green: 0.24, blue: 0.23)],
                           startPoint: .leading, endPoint: .trailing)
            HStack {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Speak, and it's \(Text("written").italic())")
                        .font(Theme.display(28))
                        .foregroundStyle(.white)
                    Text("Hold \(hotkey) and talk in any app. Double-tap for hands-free. It's all processed on this Mac.")
                        .font(.system(size: 13))
                        .foregroundStyle(.white.opacity(0.75))
                }
                Spacer(minLength: 0)
                if showsWaveform {
                    Image(systemName: "waveform")
                        .font(.system(size: 72, weight: .ultraLight))
                        .foregroundStyle(.white.opacity(0.25))
                }
            }
            .padding(28)
        }
        .frame(minHeight: 170)
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }
}

struct StatsCard: View {
    var stats: UsageStats
    /// Side by side in one row (under the hero in a narrow window) instead of stacked.
    var inRow = false

    var body: some View {
        let layout = inRow ? AnyLayout(HStackLayout(alignment: .firstTextBaseline, spacing: 28)) : AnyLayout(VStackLayout(alignment: .leading, spacing: 16))
        layout {
            stat(stats.totalWords.formatted(.number.notation(.compactName)), "total words")
            stat("\(stats.wordsPerMinute)", "wpm")
            stat("\(stats.dayStreak)", stats.dayStreak == 1 ? "day streak" : "day streak")
        }
        .padding(inRow ? 18 : 22)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 16).fill(Theme.well))
    }

    private func stat(_ value: String, _ label: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(value).font(Theme.display(26))
            Text(label).font(.system(size: 14)).foregroundStyle(.secondary)
        }
    }
}

private struct EmptyHistory: View {
    var hotkey: String
    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 8) {
                Text("No dictations yet").font(.system(size: 14, weight: .semibold))
                Text("Click into any text field, hold \(hotkey), and start talking. Your transcripts will show up here.")
                    .font(.system(size: 13)).foregroundStyle(.secondary)
            }
        }
    }
}

#if VOICEPARTY_DEBUG_URLS
/// Debug snapshots: draw this history row as if the pointer were over it.
@MainActor enum HistoryRowDebug { static var hovered: UUID? }
#endif

/// Kept cheap for smooth scrolling: fixed height regardless of hover, no per-row SwiftUI Menu
/// (actions are built only when the popover/context menu opens), no selectable-text view.
/// The actions live in a gutter on the right that the text never enters (reserved even when hidden, so hovering doesn't
/// reflow the row): play, copy and "…" (the details and the other actions).
private struct HistoryRow: View {
    let app: AppModel
    let item: HistoryItem
    let isLast: Bool
    @State private var hovering = false
    @State private var showingActions = false
    @State private var player: AVAudioPlayer?
    @State private var playing = false
    @State private var copied = false

    private static let timeFormat = Date.FormatStyle(date: .omitted, time: .shortened)
    private static let gutterWidth: CGFloat = 92
    private var showsActions: Bool {
        #if VOICEPARTY_DEBUG_URLS
        if HistoryRowDebug.hovered == item.id { return true }
        #endif
        return hovering || showingActions
    }

    private var audioPath: String? {
        item.audioPath.flatMap { FileManager.default.fileExists(atPath: $0) ? $0 : nil }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 14) {
                HStack(spacing: 8) {
                    AppIconView(bundleID: item.appBundleID)
                    Text(item.createdAt.formatted(Self.timeFormat).lowercased())
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }
                .frame(width: 92, alignment: .leading)
                .padding(.top, 1)
                Text(item.pastedText.isEmpty ? "(empty)" : item.pastedText)
                    .font(.system(size: 14))
                    .frame(maxWidth: .infinity, alignment: .leading)
                actionButtons
                    .frame(width: Self.gutterWidth, alignment: .trailing)
                    .padding(.top, -3)
                    .opacity(showsActions ? 1 : 0)
                    .allowsHitTesting(showsActions)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 14)
            .background(Theme.selection.opacity(showsActions ? 0.45 : 0))
            .contentShape(Rectangle())
            .animation(.easeOut(duration: 0.15), value: hovering)
            .onHover { hovering = $0 }
            .contextMenu {
                ForEach(actions(includeIconActions: true), id: \.title) { action in
                    Button(action.title, role: action.destructive ? .destructive : nil) { action.run() }
                }
            }
            if !isLast { Divider().opacity(0.6) }
        }
    }

    private var actionButtons: some View {
        HStack(spacing: 2) {
            if let path = audioPath {
                iconButton(playing ? "stop.fill" : "play.fill", help: playing ? "Stop" : "Play audio") {
                    playing ? stop() : play(path)
                }
            }
            iconButton(copied ? "checkmark" : "doc.on.doc", help: "Copy") { copy() }
            iconButton("ellipsis", help: "More") { showingActions = true }
                .popover(isPresented: $showingActions, arrowEdge: .trailing) { moreMenu }
        }
    }

    private func iconButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 28, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
    }

    /// The details (app, length, cleanup) and the actions that aren't icons.
    private var moreMenu: some View {
        VStack(alignment: .leading, spacing: 2) {
            details
                .padding(.horizontal, 10).padding(.top, 4).padding(.bottom, 6)
            Divider().padding(.bottom, 2)
            ForEach(actions(includeIconActions: false), id: \.title) { action in
                Button {
                    showingActions = false
                    action.run()
                } label: {
                    Text(action.title)
                        .foregroundStyle(action.destructive ? Color.red : Color.primary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 10).frame(height: 26)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(6)
        .frame(width: 220)
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text([item.appName, "\(item.wordCount) words", item.latencyMs > 0 ? "\(item.latencyMs) ms" : nil]
                .compactMap { $0 }.joined(separator: " · "))
            if item.revertedAI { Text("AI edit undone") }
            else if item.status == .formatted { Label("AI cleaned", systemImage: "sparkles") }
        }
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
        .lineLimit(1)
    }

    private struct RowAction {
        var title: String
        var destructive = false
        var run: () -> Void
    }

    /// `includeIconActions`: also Copy and Play audio (the right-click menu has everything; "…" leaves out the icons).
    private func actions(includeIconActions: Bool) -> [RowAction] {
        var list: [RowAction] = []
        if includeIconActions { list.append(RowAction(title: "Copy") { copy() }) }
        list.append(RowAction(title: "Paste") { Task { await app.dictation.inserter.insert(item.pastedText) } })
        if item.status == .formatted && item.rawText != item.pastedText && !item.revertedAI {
            list.append(RowAction(title: "Restore what you said") { undoAIEdit() })
        }
        if let path = audioPath {
            if includeIconActions { list.append(RowAction(title: "Play audio") { play(path) }) }
            list.append(RowAction(title: "Retry transcript") { retry(path) })
        }
        list.append(RowAction(title: "Delete", destructive: true) {
            try? app.store.deleteHistory(id: item.id)
            if let path = item.audioPath { try? FileManager.default.removeItem(atPath: path) }
            app.reloadHistory()
        })
        return list
    }

    private func undoAIEdit() {
        var updated = item
        updated.pastedText = item.rawText
        updated.revertedAI = true
        try? app.store.save(updated)
        app.dictation.inserter.copy(item.rawText)
        app.dictationBar.toast("Original transcript copied to clipboard", duration: 2.5)
        app.reloadHistory()
    }

    private func copy() {
        app.dictation.inserter.copy(item.pastedText)
        copied = true
        Task { try? await Task.sleep(for: .seconds(1.2)); copied = false }
    }

    private func play(_ path: String) {
        guard let audio = try? AVAudioPlayer(contentsOf: URL(fileURLWithPath: path)) else { return }
        player = audio
        audio.play()
        playing = true
        Task { // back to "play" when it ends (unless another play or a stop came first)
            try? await Task.sleep(for: .seconds(audio.duration + 0.2))
            if player === audio { playing = false }
        }
    }

    private func stop() {
        player?.stop()
        player = nil
        playing = false
    }

    private func retry(_ path: String) {
        Task { await app.dictation.retry(item) }
    }

}

/// Tiny icon of the app a dictation went into. Icons are cached, so scrolling stays smooth.
private struct AppIconView: View {
    let bundleID: String?

    var body: some View {
        Group {
            if let image = AppIconCache.shared.icon(for: bundleID) {
                Image(nsImage: image).resizable().interpolation(.high)
            } else {
                Image(systemName: "app.dashed").resizable().foregroundStyle(.tertiary)
            }
        }
        .frame(width: 16, height: 16)
    }
}

@MainActor
final class AppIconCache {
    static let shared = AppIconCache()
    private var icons: [String: NSImage] = [:]
    private var missing: Set<String> = []

    func icon(for bundleID: String?) -> NSImage? {
        guard let bundleID, !missing.contains(bundleID) else { return nil }
        if let cached = icons[bundleID] { return cached }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            missing.insert(bundleID)
            return nil
        }
        let full = NSWorkspace.shared.icon(forFile: url.path)
        // Downscale once so rows don't redraw a 1024 px icon while scrolling.
        let small = NSImage(size: NSSize(width: 32, height: 32), flipped: false) { rect in
            full.draw(in: rect)
            return true
        }
        icons[bundleID] = small
        return small
    }
}
