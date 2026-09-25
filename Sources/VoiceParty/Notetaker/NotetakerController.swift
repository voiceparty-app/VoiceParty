@preconcurrency import AVFoundation
import AppKit
import Foundation
import Observation
import VoicePartyCore
import VoicePartyEngines

/// Records a meeting (your mic = "You", the Mac's audio = "Others"), transcribes it while it happens, and
/// writes notes when it ends — all on this Mac. Nothing joins the call.
@MainActor
@Observable
final class NotetakerController {
    enum State: Equatable {
        case idle
        case recording(since: Date)
        /// Finishing the transcript and writing the notes.
        case wrappingUp
    }

    private(set) var state: State = .idle
    /// The note being recorded or written.
    private(set) var currentNoteID: UUID?
    /// What you type in the notepad during the meeting.
    var userNotes = ""

    @ObservationIgnored private unowned let app: AppModel
    @ObservationIgnored private var mic: NoteMicCapture?
    @ObservationIgnored private var tap: SystemAudioTap?
    @ObservationIgnored private var sides: [NoteSideRecorder] = []
    @ObservationIgnored private var transcriber: NoteTranscriber?
    @ObservationIgnored private var note: MeetingNote?
    @ObservationIgnored private var sleepObserver: NSObjectProtocol?
    @ObservationIgnored private var silenceTimer: Timer?
    @ObservationIgnored private var holdingModel = false
    /// Transcribed so far in the current meeting (saved into the note as it goes).
    @ObservationIgnored private var liveSegments: [NoteSegment] = []
    @ObservationIgnored private var lastLiveSave = Date.distantPast
    @ObservationIgnored private var calls = CallDetector()
    @ObservationIgnored private var callTimer: Timer?
    /// The call these notes were started for (they stop when it ends).
    @ObservationIgnored private var callApp: String?
    /// The calendar event's title, when the meeting matched one (it wins over the model's title).
    @ObservationIgnored private var calendarTitle: String?
    @ObservationIgnored private var notepad: NotepadPanel?
    @ObservationIgnored private var closingNotepad = false

    init(app: AppModel) {
        self.app = app
        // A sleeping Mac can't record: wrap up what's there instead of losing it.
        sleepObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.willSleepNotification, object: nil,
                                                                          queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, case .recording = self.state else { return }
                Task { await self.stop(reason: "Your Mac went to sleep, so the meeting notes were wrapped up") }
            }
        }
    }

    var isRecording: Bool { if case .recording = state { true } else { false } }

    /// Offer notes when a call starts; stop them when that call ends.
    func watchForCalls() {
        let started = Date()
        callTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.app.settings.suggestNotesForCalls else { return }
                for event in self.calls.observe(usingMic: CallWatch.callAppsUsingMic(), at: Date().timeIntervalSince(started)) {
                    switch event {
                    case .started(let callApp) where self.state == .idle:
                        self.app.dictationBar.toast("Take notes for this \(callApp) call?", action: "Start Notetaker", duration: 12) { [weak self] in
                            self?.start(appName: callApp)
                            self?.callApp = callApp
                        }
                    case .ended(let callApp) where self.isRecording && self.callApp == callApp:
                        Task { await self.stop(reason: "The \(callApp) call ended, so the Notetaker stopped.") }
                    default:
                        break
                    }
                }
            }
        }
    }

    static var directory: URL {
        let dir = Paths.appSupport.appending(path: "notes", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        Paths.excludeFromBackup(dir)
        return dir
    }

    // MARK: Start

    func start(appName: String? = nil) {
        guard state == .idle, confirmConsentOnce() else { return }
        var note = MeetingNote(title: appName.map { "\($0) meeting" } ?? "Meeting", startedAt: Date())
        note.appName = appName
        let folder = Self.directory.appending(path: note.id.uuidString, directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        note.micAudioPath = folder.appending(path: "you.caf").path
        note.systemAudioPath = folder.appending(path: "others.caf").path

        let noteID = note.id
        let transcriber = NoteTranscriber(engine: app.dictation.engine,
                                          vocabulary: VocabularyBuilder.engineHints(dictionary: app.dictionary, contextTerms: [])) { [weak self] segment in
            Task { @MainActor in self?.addLive(segment, to: noteID) }
        }
        let hand: @Sendable (NoteSegment.Speaker, SpeechChunker.Chunk) -> Void = { transcriber.enqueue($1, speaker: $0) }
        let mine = NoteSideRecorder(speaker: .me, fileURL: URL(fileURLWithPath: note.micAudioPath!), onChunk: hand)
        let theirs = NoteSideRecorder(speaker: .others, fileURL: URL(fileURLWithPath: note.systemAudioPath!), onChunk: hand)

        let mic = NoteMicCapture()
        do {
            try mic.start(deviceUID: app.settings.microphoneUID) { mine.receive($0) }
        } catch {
            app.dictationBar.toast("Notetaker couldn't use the microphone: \(error.localizedDescription)", style: .error, duration: 5)
            return
        }
        let tap = SystemAudioTap()
        do {
            // For a detected call, only that app's audio (not music, other tabs or notifications).
            let only = NotetakerConsent.tapProcesses(callApp: appName, among: CallWatch.audioProcesses())
            try tap.start(onlyProcesses: only) { theirs.receive($0) }
        } catch {
            // Still worth recording your side (an in-person meeting, or no permission yet).
            app.dictationBar.toast("Only your microphone is recorded: allow “System Audio Recording” for VoiceParty to hear the others.",
                              style: .error, duration: 7)
        }

        self.mic = mic
        self.tap = tap
        self.sides = [mine, theirs]
        self.transcriber = transcriber
        self.note = note
        currentNoteID = note.id
        try? app.store.save(note)
        app.reloadNotes()
        let started = Date()
        state = .recording(since: started)
        app.dictationBar.notetakerStartedAt = started
        app.dictationBar.toast("Notetaker is on. Let everyone know you're taking notes.", action: "Copy message", duration: 10) { [weak self] in
            self?.app.dictation.inserter.copy(NotetakerConsent.message)
            self?.app.dictationBar.toast("Message copied: paste it into the call's chat", duration: 3)
        }
        // Load the notes model now, while the meeting runs, and keep it loaded through the wrap-up: loading ~3 GB
        // onto the GPU at the moment you stop would make wrapping up slow (and can stutter the screen).
        app.modelServer.hold()
        holdingModel = true
        watchForSilence(mine)
        userNotes = ""
        calendarTitle = nil
        if app.settings.showNotepad { showNotepad() }
        if app.settings.useCalendarForNotes { nameFromCalendar(note.id) }
    }

    /// Titles the note after the calendar event you're in, with its attendees (in the background).
    private func nameFromCalendar(_ id: UUID) {
        Task {
            guard let event = await CalendarReader.currentMeeting(), var note = self.note, note.id == id else { return }
            calendarTitle = event.title
            note.title = event.title
            note.attendees = event.attendees
            save(note)
        }
    }

    // MARK: Notepad

    func showNotepad() {
        guard isRecording else { return }
        if notepad == nil {
            notepad = NotepadPanel(notetaker: self) { [weak self] in self?.notepadClosed() }
        }
        notepad?.orderFrontRegardless() // shown, but your call app keeps focus until you click in
    }

    /// Closing it yourself means "don't open it next time" (with Undo).
    private func notepadClosed() {
        notepad = nil
        guard !closingNotepad, isRecording, app.settings.showNotepad else { return }
        app.settings.showNotepad = false
        app.dictationBar.toast("The notepad won't open next time", action: "Undo", duration: 5) { [weak self] in
            self?.app.settings.showNotepad = true
        }
    }

    private func closeNotepad() {
        closingNotepad = true
        notepad?.close()
        notepad = nil
        closingNotepad = false
    }

    /// Every 30 s while recording: keep the notes model loaded, and say so if the mic has gone quiet for a
    /// minute ("Notetaker isn't hearing you": muted, or the wrong device).
    private func watchForSilence(_ mine: NoteSideRecorder) {
        silenceTimer?.invalidate()
        silenceTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.isRecording else { return }
                self.app.modelServer.ensureRunning()
                // Keep the notepad saved as you go (a crash or quit mustn't lose it).
                if var note = self.note, note.userNotes != self.userNotes {
                    note.userNotes = self.userNotes
                    self.save(note)
                }
                guard Date().timeIntervalSince(mine.lastSoundAt) > 60 else { return }
                self.app.dictationBar.toast("No sound from your microphone for a minute. Are you muted?", action: "Microphone", duration: 6) { [weak self] in
                    self?.app.windows.showHub(settings: true)
                }
            }
        }
    }

    /// VoiceParty is quitting (or the Mac is logging out): close the audio files so they're complete, and leave the
    /// note marked unfinished. The next launch transcribes it from the audio (`recoverInterruptedNotes`).
    func prepareForQuit() {
        guard state != .idle, var note else { return }
        silenceTimer?.invalidate()
        mic?.stop()
        tap?.stop()
        sides.forEach { $0.finish() }
        mic = nil; tap = nil; sides = []
        if note.status == .recording || note.status == .ready { note.status = .transcribing }
        note.userNotes = userNotes.isEmpty ? note.userNotes : userNotes
        try? app.store.save(note)
    }

    /// The first time on this Mac: what gets recorded and that others may need to agree. False = cancelled.
    private func confirmConsentOnce() -> Bool {
        guard !app.settings.notetakerConsentAcknowledged else { return true }
        let alert = NSAlert()
        alert.messageText = "Before you take notes"
        alert.informativeText = NotetakerConsent.explanation
        alert.addButton(withTitle: "Copy Message & Start")
        alert.addButton(withTitle: "Start")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate()
        switch alert.runModal() {
        case .alertFirstButtonReturn: app.dictation.inserter.copy(NotetakerConsent.message)
        case .alertSecondButtonReturn: break
        default: return false
        }
        app.settings.notetakerConsentAcknowledged = true
        return true
    }

    // MARK: Stop

    func stop(reason: String? = nil) async {
        guard case .recording = state, let note, let transcriber else { return }
        state = .wrappingUp
        app.dictationBar.notetakerStartedAt = nil
        silenceTimer?.invalidate()
        mic?.stop()
        tap?.stop()
        sides.forEach { $0.finish() }
        mic = nil; tap = nil; sides = []
        closeNotepad()
        if let reason { app.dictationBar.toast(reason, duration: 4) } else { app.dictationBar.toast("Wrapping up your notes…", duration: 3) }
        await wrapUp(note, transcriber: transcriber)
    }

    /// Debug/E2E: a "meeting" from two audio files (you, others) through the same chunking, transcription,
    /// merge and notes as a live one. Returns the finished note.
    func runForTesting(mine: URL, others: URL, userNotes: String = "") async -> MeetingNote? {
        guard state == .idle else { return nil }
        self.userNotes = userNotes
        var note = MeetingNote(title: "Meeting", startedAt: Date())
        note.appName = "Test"
        let folder = Self.directory.appending(path: note.id.uuidString, directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        note.micAudioPath = folder.appending(path: "you.caf").path
        note.systemAudioPath = folder.appending(path: "others.caf").path
        await replay(note, mine: mine, others: others, keepCopies: true)
        return app.notes.first { $0.id == note.id }
    }

    /// Notes that VoiceParty quit or crashed in the middle of: transcribed again from their audio files (which were
    /// written as the meeting went). Runs at launch, one note at a time.
    func recoverInterruptedNotes() async {
        for var note in app.notes where note.needsRecovery && note.id != currentNoteID {
            guard state == .idle else { return }
            let files = [note.micAudioPath, note.systemAudioPath].map { $0.flatMap { FileManager.default.fileExists(atPath: $0) ? URL(fileURLWithPath: $0) : nil } }
            guard files.contains(where: { $0 != nil }) else {
                note.status = .failed
                try? app.store.save(note)
                app.upsertNote(note)
                continue
            }
            userNotes = note.userNotes ?? ""
            await replay(note, mine: files[0], others: files[1], keepCopies: false)
            let id = note.id
            app.dictationBar.toast("Notes recovered from a meeting VoiceParty was closed during", action: "View", duration: 8) { [weak self] in
                self?.app.showNote(id)
            }
        }
    }

    /// Chunks, transcribes and summarizes recorded audio files into `note`. `keepCopies`: also save the audio into
    /// the note's folder (a test meeting); false when the files already are the note's own recordings.
    private func replay(_ recorded: MeetingNote, mine: URL?, others: URL?, keepCopies: Bool) async {
        var note = recorded
        let transcriber = NoteTranscriber(engine: app.dictation.engine,
                                          vocabulary: VocabularyBuilder.engineHints(dictionary: app.dictionary, contextTerms: []))
        let hand: @Sendable (NoteSegment.Speaker, SpeechChunker.Chunk) -> Void = { transcriber.enqueue($1, speaker: $0) }
        state = .wrappingUp
        self.note = note
        currentNoteID = note.id
        note.status = .transcribing
        save(note)
        var length = 0.0
        for (url, speaker) in [(mine, NoteSegment.Speaker.me), (others, .others)] {
            guard let url else { continue }
            let copy = keepCopies ? URL(fileURLWithPath: speaker == .me ? note.micAudioPath ?? "" : note.systemAudioPath ?? "") : nil
            let side = NoteSideRecorder(speaker: speaker, fileURL: copy, onChunk: hand)
            // Read and convert off the main thread: a long meeting is hundreds of megabytes of audio.
            let samples = await Task.detached(priority: .utility) { Self.samples16k(from: url) }.value
            // Fed in 100 ms pieces, like a live capture.
            stride(from: 0, to: samples.count, by: 1_600).forEach { side.receive(Array(samples[$0..<min($0 + 1_600, samples.count)])) }
            side.finish()
            length = max(length, Double(samples.count) / 16_000)
        }
        await wrapUp(note, transcriber: transcriber, endedAt: note.startedAt.addingTimeInterval(length))
    }

    nonisolated static func samples16k(from url: URL) -> [Float] {
        guard let file = try? AVAudioFile(forReading: url),
              let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)),
              (try? file.read(into: buffer)) != nil,
              let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false),
              let converted = BufferConverter(from: file.processingFormat, to: target)?.convert(buffer),
              let channel = converted.floatChannelData?[0] else { return [] }
        return Array(UnsafeBufferPointer(start: channel, count: Int(converted.frameLength)))
    }

    /// A piece of the transcript arrived during the meeting: keep it in the saved note (at most every 15 s), so a
    /// crash or a forced quit loses almost nothing.
    private func addLive(_ segment: NoteSegment, to id: UUID) {
        guard isRecording, var note, note.id == id else { return }
        liveSegments.append(segment)
        guard Date().timeIntervalSince(lastLiveSave) > 15 else { return }
        lastLiveSave = Date()
        note.segments = NoteTranscript.merge(mine: liveSegments.filter { $0.speaker == .me }, others: liveSegments.filter { $0.speaker == .others })
        note.userNotes = userNotes.isEmpty ? note.userNotes : userNotes
        save(note)
    }

    private func wrapUp(_ recorded: MeetingNote, transcriber: NoteTranscriber, endedAt: Date = Date()) async {
        var note = self.note ?? recorded // it may have been titled from the calendar meanwhile
        note.userNotes = userNotes.isEmpty ? note.userNotes : userNotes
        let segments = await transcriber.finish()
        note.segments = NoteTranscript.merge(mine: segments.filter { $0.speaker == .me }, others: segments.filter { $0.speaker == .others })
        note.endedAt = endedAt
        note.status = .summarizing
        save(note)

        if NoteSummarizer.isTooShortToKeep(words: note.wordCount) {
            note.status = .ready
            save(note)
            finish()
            let id = note.id
            app.dictationBar.toast("Only a few words were captured. Started by mistake?", action: "Discard", duration: 8) { [weak self] in
                self?.delete(id)
            }
            return
        }

        if let model = await app.modelForNotes() {
            let transcript = NoteTranscript.plainText(note.segments)
            let context = NoteSummarizer.context(title: calendarTitle, attendees: note.attendees, userNotes: note.userNotes)
            if let notes = try? await NoteSummarizer.summarize(transcript: transcript, context: context, partWords: 1_200,
                                                               transform: { text, instructions in
                try await model.transform(text, instructions: instructions)
            }) {
                note.title = NoteSummarizer.finalTitle(calendar: calendarTitle, model: notes.title, fallback: note.title)
                note.summary = notes.summary
                note.decisions = notes.decisions
                note.actionItems = notes.actionItems
            }
        }
        note.status = .ready
        save(note)
        finish()
        let id = note.id
        app.dictationBar.toast(note.summary == nil ? "Your meeting transcript is saved" : "Meeting notes ready", action: "View", duration: 8) { [weak self] in
            self?.app.showNote(id)
        }
    }

    private func finish() {
        liveSegments = []
        lastLiveSave = .distantPast
        if holdingModel {
            app.modelServer.release()
            holdingModel = false
        }
        callApp = nil
        calendarTitle = nil
        userNotes = ""
        note = nil
        transcriber = nil
        currentNoteID = nil
        state = .idle
    }

    private func save(_ note: MeetingNote) {
        self.note = note
        try? app.store.save(note)
        app.upsertNote(note) // just this note: reloading every transcript on each save stalled the UI
    }

    func delete(_ id: UUID) {
        guard let note = app.notes.first(where: { $0.id == id }) else { return }
        try? app.store.deleteNote(id: id)
        let folder = Self.directory.appending(path: note.id.uuidString, directoryHint: .isDirectory)
        try? FileManager.default.removeItem(at: folder)
        app.reloadNotes()
    }
}
