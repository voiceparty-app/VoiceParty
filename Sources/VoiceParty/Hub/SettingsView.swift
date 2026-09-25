import SwiftUI
import UniformTypeIdentifiers
import VoicePartyCore
import VoicePartyEngines

struct SettingsView: View {
    @Bindable var app: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var section: Section
    @State private var showingShortcuts = false

    init(app: AppModel, section: Section = .general) {
        self.app = app
        _section = State(initialValue: section)
    }

    enum Section: String, CaseIterable {
        case general = "General", system = "System", vibeCoding = "Vibe coding", experimental = "Experimental"
        case privacy = "Privacy", backup = "Backup & Sync"

        var symbol: String {
            switch self {
            case .general: "slider.horizontal.3"
            case .system: "laptopcomputer"
            case .vibeCoding: "number"
            case .experimental: "flask"
            case .privacy: "lock.shield"
            case .backup: "arrow.up.arrow.down.circle"
            }
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                Text("SETTINGS").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary).padding(.bottom, 8).padding(.leading, 8)
                ForEach(Section.allCases, id: \.self) { s in
                    Button { section = s } label: {
                        HStack(spacing: 8) {
                            Image(systemName: s.symbol).frame(width: 20)
                            Text(s.rawValue)
                        }
                            .font(.system(size: 13, weight: section == s ? .semibold : .regular))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 8).frame(height: 30)
                            .background(RoundedRectangle(cornerRadius: 7).fill(section == s ? Theme.selection : .clear))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                Spacer()
                Text("VoiceParty \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev")")
                    .font(.system(size: 11)).foregroundStyle(.secondary).padding(8)
            }
            .padding(14)
            .frame(width: 200)
            .background(Theme.canvas)

            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text(section.rawValue).font(Theme.display(26))
                    Spacer()
                    Button { dismiss() } label: { Image(systemName: "xmark").font(.system(size: 13)) }.buttonStyle(.plain).keyboardShortcut(.cancelAction)
                }
                .padding(.bottom, 18)
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) { page }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(OverlayScrollers())
                }
            }
            .padding(28)
            .background(Theme.card)
        }
        .frame(width: 820, height: 600)
        .sheet(isPresented: $showingShortcuts) {
            ShortcutsView(app: app) { showingShortcuts = false }
        }
    }

    @ViewBuilder private var page: some View {
        switch section {
        case .general: general
        case .system: system
        case .vibeCoding: vibeCoding
        case .experimental: experimental
        case .privacy: privacy
        case .backup: backup
        }
    }

    // MARK: Pages

    private var general: some View {
        VStack(alignment: .leading, spacing: 20) {
            SettingsGroup {
                SettingsRow(title: "Shortcuts", detail: "Hold \(app.pushToTalkName) and speak.") {
                    Button("Change") { showingShortcuts = true }.buttonStyle(SecondaryButtonStyle())
                }
                SettingsRow(title: "Microphone", detail: currentMicName) {
                    Picker("", selection: $app.settings.microphoneUID) {
                        let devices = MicrophoneManager.inputDevices()
                        Text("System default").tag(String?.none)
                        ForEach(devices.filter { !$0.isVirtual }) { d in
                            Text(d.name + (d.isBuiltIn ? " (recommended)" : "")).tag(String?.some(d.uid))
                        }
                        if devices.contains(where: \.isVirtual) {
                            SwiftUI.Section("Other devices") {
                                ForEach(devices.filter(\.isVirtual)) { d in Text(d.name).tag(String?.some(d.uid)) }
                            }
                        }
                    }
                    .labelsHidden().fixedSize()
                }
                SettingsRow(title: "Speech engine", detail: engineDetail) {
                    Picker("", selection: $app.settings.engine) {
                        ForEach(engineOptions) { Text($0.name).tag($0.id) }
                    }
                    .labelsHidden().fixedSize()
                }
                SettingsRow(title: "Dictation language", detail: "English (United States)", showDivider: false) {
                    Text("More languages later").font(.system(size: 12)).foregroundStyle(.secondary)
                }
            }
            SettingsGroup {
                SettingsRow(title: "AI cleanup",
                            detail: app.localCleanupSummary.map { "Using \($0.prefix(1).lowercased() + $0.dropFirst()). They load when you start dictating." }
                                ?? app.dictation.polisher.unavailableReason
                                ?? "Using \(app.cleanupSummary). Add faster local models under Enhancements.",
                            showDivider: false) {
                    Toggle("", isOn: $app.settings.useLanguageModel).toggleStyle(.switch).labelsHidden()
                }
            }
            SettingsGroup {
                SettingsRow(title: "Updates", detail: updateDetail) {
                    HStack(spacing: 10) {
                        Toggle("", isOn: $app.settings.checkForUpdates).toggleStyle(.switch).labelsHidden()
                        Button(updateButtonTitle) {
                            if case .available = app.updater.state { Task { await app.updater.install() } }
                            else { Task { await app.updater.check(userInitiated: true) } }
                        }
                        .buttonStyle(SecondaryButtonStyle())
                        .disabled(Updater.repository == nil || app.updater.state == .checking || app.updater.state == .installing)
                    }
                }
                .help("Checks GitHub once a day for a newer version. Only the version number is fetched; nothing about you is sent.")
            }
            SettingsGroup {
                SettingsRow(title: "Model memory",
                            detail: "Downloaded AI models use about 1–3 GB while loaded. \"Load when I dictate\" frees it after 5 idle minutes; models reload in about a second when you start talking.",
                            showDivider: false) {
                    Picker("", selection: $app.settings.modelMemory) {
                        ForEach(ModelMemoryPolicy.allCases, id: \.self) { Text($0.displayName).tag($0) }
                    }
                    .labelsHidden().fixedSize()
                }
            }
        }
    }

    private var updateDetail: String {
        let current = "Version \(Updater.currentVersion)."
        switch app.updater.state {
        case .available(let version): return current + " Version \(version) is ready to install."
        case .checking: return current + " Checking…"
        case .installing: return current + " Installing…"
        case .failed(let message): return current + " Last update failed: \(message)."
        case .idle:
            return current + (Updater.repository == nil ? " This build has no update source." : " Checked automatically once a day.")
        }
    }

    private var updateButtonTitle: String {
        if case .available = app.updater.state { return "Install" }
        return "Check Now"
    }

    private var engineOptions: [EngineFactory.Option] {
        (app.enhancements.isInstalled(EnhancementID.parakeetUnified) ? [EngineFactory.parakeetUnifiedOption] : [])
            + (app.enhancements.isInstalled(EnhancementID.parakeet) ? [EngineFactory.parakeetOption] : [])
            + EngineFactory.options
    }

    private var currentMicName: String {
        guard let uid = app.settings.microphoneUID else { return "System default input" }
        return MicrophoneManager.inputDevices().first { $0.uid == uid }?.name ?? "Unavailable — using system default"
    }

    private var engineDetail: String {
        if let status = app.engineStatus { return status }
        if let error = app.engineError { return error }
        return engineOptions.first { $0.id == app.settings.engine }?.detail ?? ""
    }

    private var system: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("App settings").font(.system(size: 13, weight: .semibold))
            SettingsGroup {
                toggleRow("Open at login", $app.settings.launchAtLogin)
                toggleRow("Always show the dictation bar", $app.settings.showBarAlways, detail: "A small bar at the bottom of the screen you can click to dictate.")
                toggleRow("Show in the Dock", $app.settings.showInDock, last: true)
            }
            Text("Sound").font(.system(size: 13, weight: .semibold))
            SettingsGroup {
                toggleRow("Dictation sounds", $app.settings.soundsEnabled)
                toggleRow("Silence other audio while dictating", $app.settings.muteMediaWhileDictating, detail: "Silences your speakers while the mic is on.", last: true)
            }
            Text("Notetaker").font(.system(size: 13, weight: .semibold))
            SettingsGroup {
                toggleRow("Offer notes when a call starts", $app.settings.suggestNotesForCalls,
                          detail: "When Zoom, Teams, FaceTime, Webex, Slack or a browser call uses your mic, VoiceParty offers to take notes, and stops when the call ends.")
                toggleRow("Name notes from your calendar", $app.settings.useCalendarForNotes,
                          detail: "Titles notes after the event you're in and spells attendees' names right. Asks for Calendar access once; your calendar is read on this Mac only.")
                toggleRow("Open the notepad", $app.settings.showNotepad,
                          detail: "A small window for your own notes while the Notetaker records. What you write leads the summary.", last: true)
            }
            Text("Extras").font(.system(size: 13, weight: .semibold))
            SettingsGroup {
                toggleRow("Learn words from my corrections", $app.settings.autoLearnWords, detail: "Adds words you correct right after dictating.", last: true)
            }
        }
    }

    private var vibeCoding: some View {
        VStack(alignment: .leading, spacing: 20) {
            SettingsGroup {
                toggleRow("Spell code names (VS Code, Cursor, Windsurf, Xcode)", $app.settings.variableRecognition,
                          detail: "Reads identifiers and file names from your editor so they're spelled in code form. In VS Code-based editors, turn on “editor.accessibilitySupport”.")
                toggleRow("Tag files in AI chats (Cursor, Windsurf)", $app.settings.fileTagging,
                          detail: "Say a file name and it's written as @file.tsx.", last: true)
            }
        }
    }

    private var experimental: some View {
        VStack(alignment: .leading, spacing: 20) {
            SettingsGroup {
                SettingsRow(title: "Command Mode", detail: "Select text, hold \(commandName) and say how to change it — or ask a question with nothing selected.") {
                    Text("Always on").font(.system(size: 12)).foregroundStyle(.secondary)
                }
                toggleRow("“Press enter” voice command", $app.settings.pressEnterCommand, detail: "Say “press enter” at the end of a dictation to send it.", last: true)
            }
            Text("Bulk import").font(.system(size: 13, weight: .semibold))
            SettingsGroup {
                SettingsRow(title: "Dictionary from CSV", detail: "One entry per line: word, or word,replacement.") {
                    Button("Choose…") { importCSV() }.buttonStyle(SecondaryButtonStyle())
                }
                SettingsRow(title: "Snippets from JSON", detail: "An array of {\"name\": trigger, \"text\": expansion}.", showDivider: false) {
                    Button("Choose…") { importSnippets() }.buttonStyle(SecondaryButtonStyle())
                }
            }
        }
    }

    private var commandName: String {
        app.settings.shortcuts.combos(for: .commandMode).first.map(KeyNames.display) ?? "the Command Mode shortcut"
    }

    private var privacy: some View {
        VStack(alignment: .leading, spacing: 20) {
            Card {
                Label {
                    Text("VoiceParty has no servers. Audio, transcripts and screen context are processed on this Mac and never uploaded. The only network use is Apple's speech model (fetched once by macOS), Enhancements you choose to install, and a daily check of GitHub for a newer VoiceParty (only the version number is fetched; you can turn it off in General).")
                        .font(.system(size: 13))
                } icon: { Image(systemName: "lock.shield").foregroundStyle(Theme.accent) }
            }
            SettingsGroup {
                toggleRow("Context awareness", $app.settings.contextAwareness,
                          detail: "Reads a little text around your cursor (locally) to spell names right and match what you're writing. Password fields are always skipped.")
                SettingsRow(title: "Read the screen", detail: screenReadingDetail) {
                    Toggle("", isOn: Binding(get: { app.settings.screenOCR }, set: { on in
                        app.settings.screenOCR = on
                        // macOS asks for Screen Recording the first time.
                        if on && !ScreenOCR.hasPermission { ScreenOCR.requestPermission() }
                    }))
                    .toggleStyle(.switch).labelsHidden()
                }
                SettingsRow(title: "Dictation history", detail: "How long your dictation history is kept on this Mac.") {
                    Picker("", selection: $app.settings.historyRetention) {
                        ForEach(HistoryRetention.allCases, id: \.self) { Text($0.displayName).tag($0) }
                    }
                    .labelsHidden().fixedSize()
                }
                SettingsRow(title: "Keep audio recordings", detail: "Used for Retry and playback in history.") {
                    Picker("", selection: $app.settings.keepAudioDays) {
                        Text("Don't keep").tag(0); Text("1 day").tag(1); Text("7 days").tag(7); Text("14 days").tag(14); Text("30 days").tag(30)
                    }
                    .labelsHidden().fixedSize()
                }
                SettingsRow(title: "Delete all history", detail: "Removes every dictation, meeting note and recording.", showDivider: false) {
                    Button("Delete…", role: .destructive) { confirmDeleteAll() }.buttonStyle(SecondaryButtonStyle())
                }
            }
        }
    }

    private var screenReadingDetail: String {
        let base = "Also reads the text in the window you're dictating into, on this Mac, so names you can see are spelled right. Nothing is saved."
        guard app.settings.screenOCR, !ScreenOCR.hasPermission else { return base }
        return base + " Needs Screen Recording: System Settings → Privacy & Security → Screen & System Audio Recording → VoiceParty."
    }

    @State private var includeShortcuts = false

    private var backup: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Move your dictionary, snippets, transforms and preferences to another Mac with a single file — no account or cloud needed.")
                .font(.system(size: 13)).foregroundStyle(.secondary)
            SettingsGroup {
                SettingsRow(title: "Export profile", detail: "Saves voiceparty-profile.json.") {
                    Button("Export…") { exportProfile() }.buttonStyle(SecondaryButtonStyle())
                }
                SettingsRow(title: "Import profile", detail: "Merges a profile into this Mac; nothing is deleted.") {
                    Button("Import…") { importProfile() }.buttonStyle(SecondaryButtonStyle())
                }
                toggleRow("Include shortcuts in exports", $includeShortcuts, detail: "Off by default, since keyboards differ between Macs.", last: true)
            }
            SettingsGroup {
                SettingsRow(title: "Import from Wispr Flow",
                            detail: "Copies your Wispr Flow dictionary, replacements and snippets from this Mac. Wispr Flow's files aren't changed.",
                            showDivider: false) {
                    Button("Import") { importWispr() }.buttonStyle(SecondaryButtonStyle())
                }
            }
        }
    }

    private func toggleRow(_ title: String, _ binding: Binding<Bool>, detail: String? = nil, last: Bool = false) -> some View {
        SettingsRow(title: title, detail: detail, showDivider: !last) {
            Toggle("", isOn: binding).toggleStyle(.switch).labelsHidden()
        }
    }

    // MARK: Actions

    private func confirmDeleteAll() {
        let alert = NSAlert()
        alert.messageText = "Delete all history?"
        alert.informativeText = "This removes every dictation, meeting note, transcript and recording from this Mac. Your dictionary, snippets and settings stay. It can't be undone."
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.hasDestructiveAction = true
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        app.deleteAllHistory()
    }

    private func exportProfile() {
        var settings = app.settings
        if !includeShortcuts { settings.shortcuts = .defaults() }
        let profile = VoicePartyProfile(dictionary: app.dictionary, snippets: app.snippets, transforms: app.transforms, settings: settings)
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "voiceparty-profile.json"
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try profile.encoded().write(to: url, options: .atomic)
            app.dictationBar.toast("Profile exported", duration: 2)
        } catch {
            app.dictationBar.toast("Export failed: \(error.localizedDescription)", style: .error)
        }
    }

    private func importProfile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let profile = try VoicePartyProfile.decode(Data(contentsOf: url))
            let summary = try ProfileMerger.merge(dictionary: profile.dictionary, snippets: profile.snippets, transforms: profile.transforms, into: app.store)
            if let incoming = profile.settings {
                app.settings = app.settings.importing(incoming, includeShortcuts: includeShortcuts)
            }
            app.reloadPersonalization()
            app.dictationBar.toast("Imported: \(summary.description)", duration: 5)
        } catch {
            app.dictationBar.toast("Import failed: \(error.localizedDescription)", style: .error, duration: 5)
        }
    }

    private func importWispr() {
        do {
            let data = try WisprFlowImporter.read()
            let summary = try ProfileMerger.merge(dictionary: data.dictionary, snippets: data.snippets, into: app.store)
            app.reloadPersonalization()
            app.dictationBar.toast("Imported from Wispr Flow: \(summary.description)", duration: 5)
        } catch {
            app.dictationBar.toast(error.localizedDescription, style: .error, duration: 5)
        }
    }

    private func importCSV() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.commaSeparatedText, .plainText]
        guard panel.runModal() == .OK, let url = panel.url, let text = try? String(contentsOf: url, encoding: .utf8) else { return }
        let summary = try? ProfileMerger.merge(dictionary: BulkImport.dictionary(csv: text), snippets: [], into: app.store)
        app.reloadPersonalization()
        app.dictationBar.toast("Imported: \(summary?.description ?? "nothing")", duration: 4)
    }

    private func importSnippets() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url, let data = try? Data(contentsOf: url),
              let snippets = try? BulkImport.snippets(json: data) else { return }
        let summary = try? ProfileMerger.merge(dictionary: [], snippets: snippets, into: app.store)
        app.reloadPersonalization()
        app.dictationBar.toast("Imported: \(summary?.description ?? "nothing")", duration: 4)
    }
}
