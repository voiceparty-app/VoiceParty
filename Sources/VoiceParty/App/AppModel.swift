import AppKit
import Carbon
import Observation
import ServiceManagement
import VoicePartyCore
import VoicePartyEngines

/// App-wide state: settings, personalization data, history, and the controllers that act on them.
@MainActor
@Observable
final class AppModel {
    var settings: AppSettings {
        didSet {
            guard settings != oldValue else { return }
            SettingsFile.save(settings)
            applySettings(old: oldValue)
        }
    }

    let store: VoicePartyStore
    let dictationBar = DictationBarModel()

    var history: [HistoryItem] = []
    /// `history` grouped by day, computed once per reload (the Home list reads this).
    var historyDays: [HistoryDay] = []
    @ObservationIgnored private var historyGeneration = 0
    var dictionary: [DictionaryEntry] = []
    var snippets: [Snippet] = []
    var transforms: [TransformDefinition] = []
    var stats = UsageStats.compute(from: [])
    /// Meeting notes (Notetaker), newest first.
    var notes: [MeetingNote] = []

    var lastTranscript: String?
    var lastTransformRun: TransformRun? {
        didSet { if (oldValue == nil) != (lastTransformRun == nil) { refreshShortcutAvailability() } }
    }
    var engineStatus: String?
    var engineError: String?
    var permissions = Permissions.State.current()
    /// While the Shortcuts dialog is recording, key events go here instead of triggering actions.
    var shortcutRecorder: ShortcutRecorder?

    @ObservationIgnored private(set) var dictation: DictationController!
    @ObservationIgnored let eventTap = EventTapMonitor()
    @ObservationIgnored private var hotkeys: HotkeyStateMachine
    @ObservationIgnored var windows: WindowCoordinator!
    /// Observed (not ignored) so views show recording state.
    private(set) var notetaker: NotetakerController!
    private(set) var updater: Updater!
    let enhancements = EnhancementManager()
    @ObservationIgnored let modelServer = LocalModelServer()
    /// Bumped when local models start/stop so views showing the cleanup engine refresh.
    var modelServerVersion = 0

    /// Installed local cleanup models (nil when none or AI cleanup is off), even while unloaded between dictations.
    var localCleanupSummary: String? {
        _ = modelServerVersion
        guard settings.useLanguageModel else { return nil }
        switch (enhancements.isInstalled(EnhancementID.fastCleanup), enhancements.isInstalled(EnhancementID.strongCleanup)) {
        case (true, true): return "Local models (fast + smart)"
        case (true, false): return "Local fast model"
        case (false, true): return "Local smart model"
        default: return nil
        }
    }

    /// Shared menu pieces (menu-bar icon, app menu bar, dictation bar right-click).
    @ObservationIgnored lazy var menus = MenuActions(app: self)
    @ObservationIgnored private var dictationBarHiddenUntil: Date?

    /// "Hide for 1 hour" from the dictation bar's menu: the resting bar comes back on its own.
    func hideDictationBar(for seconds: TimeInterval) {
        dictationBarHiddenUntil = Date().addingTimeInterval(seconds)
        applyRestingBar()
        Timer.scheduledTimer(withTimeInterval: seconds + 1, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.applyRestingBar() }
        }
    }

    private func applyRestingBar() {
        let hidden = dictationBarHiddenUntil.map { $0 > Date() } ?? false
        dictationBar.showRestingBar = settings.showBarAlways && !hidden
        if dictationBar.phase == .hidden || dictationBar.phase == .resting { dictationBar.hide() }
    }

    /// Imports the user's own dictionary, replacements and snippets from Wispr Flow's local database (read-only).
    func importFromWisprFlow() {
        do {
            let data = try WisprFlowImporter.read()
            let summary = try ProfileMerger.merge(dictionary: data.dictionary, snippets: data.snippets, into: store)
            reloadPersonalization()
            dictationBar.toast("Imported from Wispr Flow: \(summary.description)", duration: 5)
        } catch {
            dictationBar.toast(error.localizedDescription, style: .error, duration: 5)
        }
    }

    /// What cleans up dictations right now, for status text.
    var cleanupSummary: String {
        localCleanupSummary ?? dictation.polisher.summary
    }

    init() throws {
        if let parakeet = EnhancementCatalog.enhancement(EnhancementID.parakeet)?.external {
            EngineFactory.parakeetDirectory = EnhancementManager.root.appending(path: parakeet.folder)
        }
        var settings = SettingsFile.load()
        // Older versions kept undone words in plain text: keep only their fingerprints.
        settings.rejectedLearnedWords = settings.rejectedLearnedWords.map {
            $0.count == 64 && $0.allSatisfy(\.isHexDigit) ? $0 : EditDiffLearner.rejectionKey($0)
        }
        self.settings = settings
        if !FileManager.default.fileExists(atPath: Paths.settings.path) { SettingsFile.save(settings) }
        store = try VoicePartyStore(url: Paths.database)
        hotkeys = HotkeyStateMachine(settings: settings.shortcuts, holdThreshold: settings.holdThreshold,
                                     doubleTapWindow: settings.doubleTapWindow)
        dictation = DictationController(app: self)
        dictation.onSessionEnded = { [weak self] in self?.hotkeys.sessionEnded() }
        windows = WindowCoordinator(app: self)
        notetaker = NotetakerController(app: self)
        updater = Updater(app: self)
        wireDictationBar()
        reloadAll()
        purgeOldHistory()
    }

    // MARK: - Startup

    func start() {
        applySettings(old: nil)
        startHotkeys()
        prepareEngine()
        enhancements.onChange = { [weak self] in
            self?.syncModelServers()
            self?.syncSpeechEngineWithEnhancements()
        }
        modelServer.onChange = { [weak self] in self?.modelServerVersion += 1 }
        modelServer.onIntegrityFailure = { [weak self] id in
            let name = EnhancementCatalog.enhancement(id)?.name ?? "A cleanup model"
            self?.dictationBar.toast("\(name)'s files changed on disk, so VoiceParty won't run them. Reinstall it in Enhancements.",
                                style: .error, duration: 8)
        }
        syncModelServers()
        // Enforce history retention while running, not only at launch.
        Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.purgeOldHistory() }
        }
        watchSecureInput()
        notetaker.watchForCalls()
        Task { await notetaker.recoverInterruptedNotes() }
        updater.startAutomaticChecks()
    }

    /// The app whose Secure Keyboard Entry is blocking the shortcuts right now (shown in the menu-bar menu).
    var secureInputOwner: String?
    @ObservationIgnored private var secureInput = SecureInputWatch(threshold: 12)

    /// Secure Keyboard Entry (a password manager, Terminal's setting) hides key presses from VoiceParty, so the
    /// shortcuts silently stop working. Say so when it stays on for a while.
    private func watchSecureInput() {
        let started = Date()
        Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let enabled = IsSecureEventInputEnabled()
                var owner: String?
                if enabled, let session = CGSessionCopyCurrentDictionary() as? [String: Any],
                   let pid = session["kCGSSessionSecureInputPID"] as? Int, pid != Int(ProcessInfo.processInfo.processIdentifier) {
                    owner = NSRunningApplication(processIdentifier: pid_t(pid))?.localizedName
                }
                switch self.secureInput.observe(enabled: enabled, owner: owner, at: Date().timeIntervalSince(started)) {
                case .blocked(let owner)?:
                    self.secureInputOwner = owner ?? "Another app"
                    self.dictationBar.toast(SecureInputWatch.message(owner: owner), style: .error, duration: 8)
                case .cleared?:
                    self.secureInputOwner = nil
                case nil:
                    break
                }
            }
        }
    }

    /// Parakeet installed → use it; removed → back to Apple's engine.
    func syncSpeechEngineWithEnhancements() {
        let installed = enhancements.isInstalled(EnhancementID.parakeet)
        if installed && settings.engine != EngineID.parakeet && !parakeetWasOffered {
            parakeetWasOffered = true
            settings.engine = EngineID.parakeet
            dictationBar.toast("Parakeet is now your speech engine", duration: 3)
        } else if !installed && settings.engine == EngineID.parakeet {
            settings.engine = EngineID.appleSpeech
        }
    }

    @ObservationIgnored private var parakeetWasOffered = false

    func syncModelServers() {
        modelServer.idleUnload = settings.modelMemory.idleUnload
        modelServer.sync(installed: { [enhancements] in enhancements.isInstalled($0) })
    }

    func startHotkeys() {
        eventTap.onEvent = { [weak self] event in self?.handle(event) ?? false }
        if !eventTap.start() {
            permissions = .current()
        }
    }

    func prepareEngine() {
        let engine = dictation.engine
        engineStatus = "Preparing on-device speech model…"
        Task { [weak self] in
            do {
                try await engine.prepare { progress in
                    Task { @MainActor [weak self] in
                        self?.engineStatus = String(format: "Downloading speech model… %.0f%%", progress * 100)
                    }
                }
                self?.engineStatus = nil
                self?.engineError = nil
            } catch {
                self?.engineStatus = nil
                self?.engineError = error.localizedDescription
            }
        }
    }

    private func wireDictationBar() {
        dictationBar.onCancel = { [weak self] in self?.dictation.cancel(.user) }
        dictationBar.onFinish = { [weak self] in self?.dictation.finish() }
        dictationBar.onStartFromBar = { [weak self] in self?.startHandsFreeFromUI() }
        dictationBar.onShowNotepad = { [weak self] in self?.notetaker.showNotepad() }
        dictationBar.onStopNotetaker = { [weak self] in
            guard let notetaker = self?.notetaker else { return }
            Task { await notetaker.stop() }
        }
        dictationBar.onCopyAnswer = { [weak self] text in self?.dictation.inserter.copy(text) }
        dictationBar.onInsertAnswer = { [weak self] text in
            guard let self else { return }
            Task { await self.dictation.inserter.insert(text) }
        }
    }

    func startHandsFreeFromUI() {
        guard dictation.state == .idle else { return }
        hotkeys.sessionStartedExternally(mode: .handsFree, at: ProcessInfo.processInfo.systemUptime)
        dictation.start(mode: .handsFree)
    }

    // MARK: - Hotkeys

    private func handle(_ event: KeyEvent) -> Bool {
        if let recorder = shortcutRecorder {
            recorder.feed(event)
            return true
        }
        // Esc also dismisses notifications and answers when nothing is recording.
        if case .down(.key(KeyCode.escape), false) = event.kind, !hotkeys.isDictating {
            switch dictationBar.phase {
            case .answer:
                dictationBar.hide()
                return true
            case .toast(let toast) where toast.actionTitle != nil:
                dictationBar.hide()
                return true
            default: break
            }
        }
        let output = hotkeys.handle(event)
        // Decide synchronously whether to swallow the key; do the (possibly slow) work afterwards so the
        // system never waits on us and typing never lags.
        let actions = output.actions
        if !actions.isEmpty {
            DispatchQueue.main.async { [weak self] in actions.forEach { self?.perform($0) } }
        }
        if let deadline = output.timerDeadline {
            let delay = max(0, deadline - ProcessInfo.processInfo.systemUptime)
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self else { return }
                let out = self.hotkeys.timerFired(at: ProcessInfo.processInfo.systemUptime)
                out.actions.forEach(self.perform)
            }
        }
        return output.consume
    }

    private func perform(_ action: HotkeyAction) {
        switch action {
        case .start(let mode): dictation.start(mode: mode)
        case .lockHandsFree: dictation.lockHandsFree()
        case .switchToCommand: dictation.switchToCommand()
        case .finish: dictation.finish()
        case .cancel(let reason): dictation.cancel(reason)
        case .showHoldHint:
            dictationBar.toast("Hold \(pushToTalkName) to dictate · double-tap for hands-free", duration: 2.5)
        case .trigger(let id): trigger(id)
        }
    }

    var pushToTalkName: String {
        settings.shortcuts.combos(for: .pushToTalk).first.map(KeyNames.display) ?? "the hotkey"
    }

    func trigger(_ id: HotkeyActionID) {
        switch id {
        case .pasteLastTranscript:
            guard let text = lastTranscript ?? (try? store.lastHistoryItem())?.pastedText else { return }
            Task { await dictation.inserter.insert(text) }
        case .copyLastTranscript:
            guard let text = lastTranscript ?? (try? store.lastHistoryItem())?.pastedText else { return }
            dictation.inserter.copy(text)
            dictationBar.toast("Last dictation copied", duration: 1.8)
        case .pressEnter:
            TextInserter.pressReturn()
        case .viewTransformChanges:
            showDiffWindow()
        default:
            if let slot = id.transformSlot, let transform = transforms.first(where: { $0.slot == slot }) {
                Task { await dictation.runTransform(transform) }
            }
        }
    }

    // MARK: - Settings side effects

    private func applySettings(old: AppSettings?) {
        hotkeys.settings = settings.shortcuts
        hotkeys.holdThreshold = settings.holdThreshold
        hotkeys.doubleTapWindow = settings.doubleTapWindow
        dictation?.sounds.isEnabled = settings.soundsEnabled
        TextInserter.defaultKeepOffHistory = DictationPrivacy.keepsOffClipboardHistory(retention: settings.historyRetention)
        dictationBar.hotkeyName = pushToTalkName
        applyRestingBar()

        if old?.showInDock != settings.showInDock || old == nil {
            windows.updateActivationPolicy()
        }
        if let old, old.launchAtLogin != settings.launchAtLogin {
            do {
                if settings.launchAtLogin { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            } catch {
                dictationBar.toast("Couldn't change launch at login: \(error.localizedDescription)", style: .error)
            }
        }
        if let old, old.engine != settings.engine { dictation.reloadEngine() }
        if let old, old.modelMemory != settings.modelMemory { syncModelServers() }
        if let old, old.historyRetention != settings.historyRetention { purgeOldHistory() }
    }

    // MARK: - Data

    func reloadAll() {
        reloadPersonalization()
        reloadHistory()
        reloadNotes() // notes cut off by a quit or crash are re-transcribed from their audio (NotetakerController)
    }

    func reloadPersonalization() {
        dictionary = (try? store.dictionary()) ?? []
        snippets = (try? store.snippets()) ?? []
        transforms = (try? store.transforms()) ?? []
        refreshShortcutAvailability()
    }

    /// ⌥-shortcuts only fire (and swallow the key) when there's something for them to do.
    func refreshShortcutAvailability() {
        let slots = Set(transforms.compactMap(\.slot))
        let hasRun = lastTransformRun != nil
        hotkeys.isAvailable = { action in
            if action == .viewTransformChanges { return hasRun }
            if let slot = action.transformSlot { return slots.contains(slot) }
            return true
        }
    }

    func reloadNotes() {
        notes = (try? store.notes()) ?? []
    }

    /// Saves one note into the list without reloading them all.
    func upsertNote(_ note: MeetingNote) {
        if let index = notes.firstIndex(where: { $0.id == note.id }) {
            notes[index] = note
        } else {
            notes.insert(note, at: 0)
        }
    }

    /// Opens a meeting note in the hub.
    func showNote(_ id: UUID) {
        windows.navigation.selectedNote = id
        windows.showHub(section: .notes)
    }

    /// The model that writes meeting notes: the local Qwen model (loaded on demand) if installed, else Apple
    /// Intelligence. Not the small cleanup model: it's trained to tidy dictation, not to summarize.
    func modelForNotes() async -> (any TextPolisher)? {
        if enhancements.isInstalled(EnhancementID.strongCleanup) {
            modelServer.ensureRunning()
            for _ in 0..<90 {
                if let strong = modelServer.strong { return strong }
                try? await Task.sleep(for: .milliseconds(500))
            }
        }
        return dictation.apple.isAvailable ? dictation.apple : nil
    }

    /// Reads history and recomputes stats off the main thread (a year of dictations is thousands of rows);
    /// the newest reload wins.
    func reloadHistory() {
        historyGeneration += 1
        let generation = historyGeneration, store = store
        Task.detached(priority: .userInitiated) { [weak self] in
            let all = (try? store.allHistory()) ?? []
            let recent = Array(all.prefix(500))
            let days = HistoryDay.group(recent), stats = UsageStats.compute(from: all)
            await MainActor.run {
                guard let self, generation == self.historyGeneration else { return }
                self.history = recent
                self.historyDays = days
                self.stats = stats
            }
        }
    }

    func record(_ item: HistoryItem, dictionaryUsed: [UUID]) {
        if settings.historyRetention != .neverStore {
            try? store.save(item)
        }
        try? store.markDictionaryUsed(ids: dictionaryUsed)
        reloadHistory()
    }

    func purgeOldHistory() {
        let fm = FileManager.default
        switch settings.historyRetention {
        case .keep:
            break
        case .deleteAfter24Hours:
            let paths = (try? store.purgeHistory(olderThan: Date().addingTimeInterval(-86_400))) ?? []
            paths.forEach { try? fm.removeItem(atPath: $0) }
        case .neverStore:
            let paths = (try? store.purgeHistory(olderThan: .distantFuture)) ?? []
            paths.forEach { try? fm.removeItem(atPath: $0) }
        }
        // Audio files older than the audio retention window.
        let cutoff = Date().addingTimeInterval(-Double(settings.keepAudioDays) * 86_400)
        if let files = try? fm.contentsOfDirectory(at: Paths.audio, includingPropertiesForKeys: [.contentModificationDateKey]) {
            for file in files {
                let date = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                if date < cutoff { try? fm.removeItem(at: file) }
            }
        }
        purgeMeetingNotes()
        reloadHistory()
    }

    /// Meeting recordings follow "Keep audio recordings"; notes follow "Delete after 24 hours". A meeting
    /// that's still recording or being written is left alone.
    private func purgeMeetingNotes() {
        let active = notetaker?.currentNoteID
        let items = ((try? store.notes()) ?? []).filter { $0.id != active && $0.status == .ready }.map { note in
            NoteRetention.Item(id: note.id, startedAt: note.startedAt,
                               hasAudio: [note.micAudioPath, note.systemAudioPath].contains { $0.map(FileManager.default.fileExists) ?? false })
        }
        let plan = NoteRetention.plan(items, retention: settings.historyRetention, keepAudioDays: settings.keepAudioDays)
        for id in plan.deleteNotes { notetaker?.delete(id) }
        let all = (try? store.notes()) ?? []
        for id in plan.deleteAudio {
            guard var note = all.first(where: { $0.id == id }) else { continue }
            for path in [note.micAudioPath, note.systemAudioPath].compactMap({ $0 }) { try? FileManager.default.removeItem(atPath: path) }
            note.micAudioPath = nil
            note.systemAudioPath = nil
            try? store.save(note)
        }
        if !plan.deleteNotes.isEmpty || !plan.deleteAudio.isEmpty { reloadNotes() }
    }

    /// "Delete all history": every transcript and recording, meeting notes included, plus anything that could
    /// still bring deleted text back (last transcript, debug files); the database then forgets freed pages.
    func deleteAllHistory() {
        try? store.deleteAllHistory()
        for note in (try? store.notes()) ?? [] where note.id != notetaker.currentNoteID { notetaker.delete(note.id) }
        let fm = FileManager.default
        try? fm.removeItem(at: Paths.audio)
        for name in ["debug-last.json", "debug-note.json", "debug-ocr.json", "debug-mic.json"] {
            try? fm.removeItem(at: Paths.appSupport.appending(path: name))
        }
        lastTranscript = nil
        try? store.vacuum()
        reloadHistory()
        reloadNotes()
    }

    /// Adds words learned from the user's corrections and offers Undo.
    func learn(_ words: [String]) {
        var added: [DictionaryEntry] = []
        for word in words {
            if let entry = try? store.addWordIfNew(word, source: .learned) { added.append(entry) }
        }
        guard !added.isEmpty else { return }
        reloadPersonalization()
        let quoted = added.map { "“\($0.phrase)”" }
        let names = quoted.count > 1 ? quoted.dropLast().joined(separator: ", ") + " and " + quoted.last! : quoted[0]
        dictationBar.toast("Learned \(names): it's in your dictionary now", action: "Undo", duration: 6) { [weak self] in
            guard let self else { return }
            added.forEach { try? self.store.deleteDictionaryEntry(id: $0.id) }
            // Undone words are never learned again (remembered only as fingerprints).
            self.settings.rejectedLearnedWords += added.map { EditDiffLearner.rejectionKey($0.phrase) }
            self.reloadPersonalization()
        }
    }

    func showDiffWindow() {
        windows.showDiff()
    }
}

struct HistoryDay: Identifiable {
    let id: Date
    let label: String
    let items: [HistoryItem]

    static func group(_ items: [HistoryItem], calendar: Calendar = .current) -> [HistoryDay] {
        let groups = Dictionary(grouping: items) { calendar.startOfDay(for: $0.createdAt) }
        return groups.keys.sorted(by: >).map { day in
            let label: String
            if calendar.isDateInToday(day) { label = "TODAY" }
            else if calendar.isDateInYesterday(day) { label = "YESTERDAY" }
            else { label = day.formatted(.dateTime.weekday(.wide).month(.wide).day()).uppercased() }
            return HistoryDay(id: day, label: label, items: groups[day]!.sorted { $0.createdAt > $1.createdAt })
        }
    }
}
