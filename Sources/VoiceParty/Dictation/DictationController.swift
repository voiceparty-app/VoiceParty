@preconcurrency import AVFoundation
import AppKit
import VoicePartyCore
import VoicePartyEngines

/// Runs one dictation at a time: key down → record → transcribe → clean up → paste → save.
@MainActor
final class DictationController {
    enum State: Equatable {
        case idle
        case recording(DictationMode)
        case processing
    }

    private unowned let app: AppModel
    let audio = AudioCapture()
    let inserter = TextInserter()
    let sounds = SoundPlayer()
    /// Apple's on-device model: the fallback when no local model enhancement is installed.
    let apple = FoundationModelPolisher()

    /// Picks per dictation between the local models (if installed) and Apple Intelligence.
    var polisher: RoutingPolisher {
        let useApple = settings.useLanguageModel && apple.isAvailable
        return RoutingPolisher(fast: settings.useLanguageModel ? app.modelServer.fast : nil,
                               strong: settings.useLanguageModel ? app.modelServer.strong : nil,
                               fallback: useApple ? apple : nil,
                               fallbackUnavailableReason: settings.useLanguageModel ? apple.unavailableReason : "AI cleanup is turned off.")
    }
    private(set) var engine: any TranscriptionEngine

    private(set) var state: State = .idle
    private var sessionTask: Task<(any TranscriptionSession)?, Never>?
    private var snapshotTask: Task<ContextReader.Snapshot, Never>?
    private var releasedAt: TimeInterval = 0
    private var editWatch: Task<Void, Never>?
    private var generation = 0
    /// The app that had focus when dictation started; text is only pasted back into it.
    private var targetPID: pid_t?
    /// On-screen terms per dictation (extracted on the main thread while the user speaks).
    private var contextTerms: [Int: [String]] = [:]
    /// Screen reading (opt-in): terms recognized in the front window, per dictation.
    private var screenTermsTask: [Int: Task<[String], Never>] = [:]

    /// Called whenever a dictation ends, so the hotkey state machine can reset.
    var onSessionEnded: (() -> Void)?

    init(app: AppModel) {
        self.app = app
        engine = EngineFactory.makeEngine(id: app.settings.engine)
        audio.onLevel = { [weak self] level in
            Task { @MainActor in self?.app.dictationBar.level = level }
        }
        inserter.onPasteFailed = { [weak self] text in
            self?.dictationBar.toast("Couldn't paste — it's on your clipboard", action: "Paste again", duration: 6) { [weak self] in
                Task { await self?.inserter.insert(text) }
            }
        }
    }

    var settings: AppSettings { app.settings }
    var dictationBar: DictationBarModel { app.dictationBar }

    func reloadEngine() {
        guard engine.id != settings.engine else { return }
        engine = EngineFactory.makeEngine(id: settings.engine)
        app.prepareEngine()
    }

    // MARK: - Lifecycle

    func start(mode: DictationMode) {
        guard state == .idle else {
            if state == .processing {
                dictationBar.toast("Still finishing the last dictation…", duration: 1.5)
                onSessionEnded?()
            }
            return
        }
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
            dictationBar.toast("VoiceParty needs microphone access", action: "Open Settings", style: .error) {
                Permissions.openMicrophoneSettings()
            }
            onSessionEnded?()
            return
        }
        editWatch?.cancel()
        generation += 1
        let gen = generation
        state = .recording(mode)
        targetPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        // Load local models now: they're ready by the time you finish speaking.
        app.modelServer.ensureRunning()

        // Show the bar and play the sound a beat later, so fn+arrow / fn+F-key shortcuts that
        // cancel within ~120 ms don't flash the UI.
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(120))
            guard let self, gen == self.generation, case .recording(let current) = self.state else { return }
            self.dictationBar.show(.listening(current))
            self.sounds.play(.start)
            if self.settings.muteMediaWhileDictating {
                // After the start cue has played.
                try? await Task.sleep(for: .milliseconds(350))
                if gen == self.generation, case .recording = self.state { MediaMuter.mute() }
            }
        }

        // Recordings stop at 20 minutes, with a heads-up a minute before.
        Task { [weak self] in
            try? await Task.sleep(for: RecordingLimit.warning)
            guard let self, gen == self.generation, case .recording = self.state else { return }
            self.dictationBar.notice = "1 minute left — dictation stops at 20 minutes"
            try? await Task.sleep(for: RecordingLimit.maximum - RecordingLimit.warning)
            guard gen == self.generation, case .recording = self.state else { return }
            self.finish()
        }

        if settings.screenOCR, let pid = targetPID, let bundleID = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier,
           SensitiveApps.mayReadScreen(bundleID: bundleID, isSecureField: false) {
            let codeMode = [.code, .terminal].contains(AppCategorizer.category(bundleID: bundleID, url: nil, overrides: settings.appCategoryOverrides))
            screenTermsTask[gen] = Task {
                guard let text = await ScreenOCR.text(inFrontWindowOf: pid) else { return [] }
                return SensitiveApps.screenSafeTerms(TermExtractor.terms(in: text, codeMode: codeMode))
            }
        }

        let includeText = settings.contextAwareness || mode == .command
        let overrides = settings.appCategoryOverrides
        snapshotTask = Task.detached(priority: .userInitiated) {
            ContextReader.snapshot(includeText: includeText, overrides: overrides)
        }
        if settings.useLanguageModel && settings.cleanupLevel != .none || mode == .command {
            let polisher = polisher
            Task.detached { await polisher.prewarm() }
        }

        // The mic starts on its own queue (CoreAudio can block while Bluetooth devices renegotiate); the
        // recording itself begins now, so nothing said after the key-press is lost.
        let token = audio.beginRecording(deviceUID: settings.microphoneUID)
        let audio = audio
        let micStart = Task { try await audio.start() }

        let engine = engine
        let dictionary = app.dictionary
        let snapshotTask = snapshotTask
        sessionTask = Task { [weak self] in
            let naturalFormat: AVAudioFormat
            do {
                naturalFormat = try await micStart.value
            } catch {
                if let self, gen == self.generation, case .recording = self.state {
                    self.fail(error is TimeoutError ? "The microphone didn't respond. Try again, or pick another one in Settings."
                                                    : "Couldn't start the microphone: \(error.localizedDescription)")
                }
                return nil
            }
            let snapshot = await snapshotTask?.value
            let terms = snapshot.map { TermExtractor.terms(for: $0.context) } ?? []
            self?.contextTerms[gen] = terms
            let vocabulary = VocabularyBuilder.engineHints(dictionary: dictionary, contextTerms: terms)
            do {
                let session = try await engine.makeSession(vocabulary: vocabulary, naturalFormat: naturalFormat)
                // A newer dictation started (or this one was cancelled): don't let this session take its audio.
                guard let self, gen == self.generation else {
                    await session.cancel()
                    return nil
                }
                self.audio.attach(token: token, format: session.audioFormat) { session.append($0) }
                return session
            } catch {
                self?.app.engineError = error.localizedDescription
                return nil
            }
        }
    }

    func lockHandsFree() {
        guard case .recording = state else { return }
        state = .recording(.handsFree)
        dictationBar.show(.listening(.handsFree))
        sounds.play(.lock)
    }

    func switchToCommand() {
        guard case .recording = state else { return }
        state = .recording(.command)
        dictationBar.show(.listening(.command))
    }

    func finish() {
        guard case .recording(let mode) = state else { return }
        state = .processing
        releasedAt = ProcessInfo.processInfo.systemUptime
        dictationBar.show(.processing(mode))
        sounds.play(.stop)
        let sessionTask = sessionTask, snapshotTask = snapshotTask
        let gen = generation
        Task { [weak self] in
            // Keep listening a moment: the last word is often still in flight when the key comes up.
            try? await Task.sleep(for: .milliseconds(150))
            guard let self else { return }
            let recorded = (duration: self.audio.duration, speech: self.audio.speechDuration)
            let recordedAudio = self.audio.recordedAudio()
            let wasAttached = self.audio.isAttached
            self.audio.stop()
            MediaMuter.restore()

            var snapshot = await snapshotTask?.value ?? ContextReader.Snapshot(context: .empty, focusedElement: nil)
            snapshot.context.terms = self.contextTerms.removeValue(forKey: gen) ?? []
            if let screen = self.screenTermsTask.removeValue(forKey: gen) {
                // Reading the screen runs while you speak; don't hold up the paste for it. A password field's
                // screen is thrown away (the field's app wasn't known to be sensitive when reading started).
                let terms = snapshot.isSecureField ? [] : await Self.value(of: screen, within: .milliseconds(400)) ?? []
                snapshot.context.terms = ContextTerms.merge(cursor: snapshot.context.terms, screen: terms)
            }
            guard let session = await sessionTask?.value else {
                self.fail(self.app.engineError ?? "Speech recognition isn't ready yet.")
                return
            }
            // The session arrived after recording ended: give it everything that was recorded.
            if !wasAttached, let recordedAudio,
               let converter = BufferConverter(from: recordedAudio.format, to: session.audioFormat),
               let converted = converter.convert(recordedAudio) {
                session.append(converted)
            }
            let raw: String
            do {
                raw = try await Self.withTimeout(RecordingLimit.transcriptionTimeout(forSeconds: recorded.duration)) { try await session.finish() }
            } catch {
                await session.cancel()
                self.fail("Transcription failed: \(error.localizedDescription)")
                return
            }
            guard gen == self.generation else { return }
            if mode == .command {
                await self.runCommand(instruction: raw, snapshot: snapshot)
            } else {
                await self.deliver(raw: raw, mode: mode, snapshot: snapshot, audio: recordedAudio, recorded: recorded)
            }
        }
    }

    struct TimeoutError: LocalizedError {
        var errorDescription: String? { "it took too long" }
    }

    /// The task's value if it's ready within `limit`, else nil (the task keeps running; its result is dropped).
    static func value<T: Sendable>(of task: Task<T, Never>, within limit: Duration) async -> T? {
        try? await withTimeout(limit) { await task.value }
    }

    /// Runs `work` with a deadline. A race, not a task group: a group waits for every child to finish, so work
    /// that ignores cancellation (a recognizer finishing up) would make the deadline meaningless.
    /// Transforms and Command Mode: a model that hangs mustn't leave dictation stuck on "processing".
    static let modelTaskLimit = Duration.seconds(90)

    /// An auto-applied transform runs before the paste: give up quickly and paste the dictation as it is.
    static func autoTransform(_ text: String, with polisher: RoutingPolisher, instructions: String) async -> String? {
        await Deadline.value(within: .seconds(15)) { try await polisher.transform(text, instructions: instructions) }
    }

    static func withTimeout<T: Sendable>(_ limit: Duration, _ work: @escaping @Sendable () async throws -> T) async throws -> T {
        let race = Race<T>()
        return try await withCheckedThrowingContinuation { continuation in
            race.continuation = continuation
            Task { race.finish(with: await Result(catching: work)) }
            Task {
                try? await Task.sleep(for: limit)
                race.finish(with: .failure(TimeoutError()))
            }
        }
    }

    func cancel(_ reason: HotkeyAction.CancelReason) {
        guard case .recording(let mode) = state else { return }
        let recordedAudio = reason == .user ? audio.recordedAudio() : nil
        let recorded = (duration: audio.duration, speech: audio.speechDuration)
        audio.stop()
        MediaMuter.restore()
        let sessionTask = sessionTask, snapshotTask = snapshotTask
        Task { await sessionTask?.value?.cancel() }
        state = .idle
        onSessionEnded?()

        switch reason {
        case .user:
            sounds.play(.cancel)
            dictationBar.toast("Transcript cancelled", action: recordedAudio == nil ? nil : "Undo", duration: 5) { [weak self] in
                guard let self, let recordedAudio else { return }
                Task {
                    let snapshot = await snapshotTask?.value ?? ContextReader.Snapshot(context: .empty, focusedElement: nil)
                    await self.retranscribe(recordedAudio, mode: mode, snapshot: snapshot, recorded: recorded)
                }
            }
        case .tooShort, .interrupted:
            dictationBar.hide()
        }
    }

    // MARK: - Delivery

    private func deliver(raw: String, mode: DictationMode, snapshot: ContextReader.Snapshot, audio: AVAudioPCMBuffer?,
                         recorded: (duration: Double, speech: Double)) async {
        var raw = raw
        var pressEnter = false
        if settings.pressEnterCommand, let stripped = Self.stripPressEnter(raw) {
            raw = stripped
            pressEnter = true
        }

        // A password field leaves no trace: no model, history, recording or learning; concealed on the clipboard.
        let privacy = DictationPrivacy.decide(isSecureField: snapshot.isSecureField, retention: settings.historyRetention,
                                              keepAudioDays: settings.keepAudioDays)
        var pipeline = makePipeline(cleanupLevel: settings.cleanupLevel, useModel: privacy.useLanguageModel)
        pipeline.codeFormatter = codeFormatter(for: snapshot.context)
        if settings.variableRecognition, [.code, .terminal].contains(snapshot.context.category) {
            let visible = [snapshot.context.windowTitle, snapshot.context.textBeforeCursor, snapshot.context.textAfterCursor]
                .compactMap { $0 }.joined(separator: "\n")
            pipeline.identifierMatcher = IdentifierMatcher(known: snapshot.context.terms + CodeFormatter.fileNames(in: visible),
                                                          isEnglishWord: TermExtractor.isEnglishWord)
        }
        var result = await pipeline.process(raw: raw, context: snapshot.context)

        if privacy.useLanguageModel, let id = settings.autoApplyTransform, let transform = app.transforms.first(where: { $0.id == id }),
           polisher.isAvailable, TextTools.wordCount(result.text) >= 3,
           let rewritten = await Self.autoTransform(result.text, with: polisher, instructions: TransformPrompt.instructions(for: transform)),
           !rewritten.isEmpty {
            app.lastTransformRun = TransformRun(name: transform.name, instruction: transform.summary, before: result.text, after: rewritten)
            result.text = rewritten
        }

        guard !result.text.isEmpty else {
            state = .idle
            onSessionEnded?()
            if pressEnter { TextInserter.pressReturn(); dictationBar.hide(); return }
            dictationBar.toast(recorded.speech < 0.2 ? "No audio detected — check your microphone" : "No speech detected", style: .error, duration: 3)
            return
        }

        // Only paste into the app you were dictating into; if you switched away, keep it on the clipboard.
        let switchedApps = targetPID != nil && NSWorkspace.shared.frontmostApplication?.processIdentifier != targetPID
        // A spoken list pastes as a real list where the app supports it (never into code or a terminal).
        let plainOnly: Set<AppCategory> = [.code, .terminal]
        let html = plainOnly.contains(snapshot.context.category) ? nil : RichText.listHTML(for: result.text)
        let outcome: TextInserter.Result
        if switchedApps {
            inserter.copy(result.text, html: html, keepOffHistory: privacy.keepOffClipboardHistory, conceal: privacy.concealOnClipboard)
            outcome = .copiedOnly
        } else {
            outcome = await inserter.insert(result.text, html: html, conceal: privacy.concealOnClipboard, pressEnter: pressEnter)
        }
        let latency = Int((ProcessInfo.processInfo.systemUptime - releasedAt) * 1000)
        state = .idle
        onSessionEnded?()
        app.lastTranscript = snapshot.isSecureField ? nil : result.text // never "paste last" a password

        if outcome == .copiedOnly {
            dictationBar.toast(switchedApps ? "You switched apps — text copied to clipboard" : "No text box focused — copied to clipboard", duration: 3.5)
        } else {
            dictationBar.hide()
        }

        var item = HistoryItem(
            mode: mode, status: result.status, context: snapshot.context, rawText: raw, formattedText: result.text,
            duration: recorded.duration, speechDuration: max(recorded.speech, min(recorded.duration, 0.5)), latencyMs: latency,
            engine: engine.id, polisher: result.polisherID, cleanupLevel: settings.cleanupLevel, style: result.style,
            wordsCorrected: result.wordsCorrected, dictionaryReplacements: result.dictionaryReplacements
        )
        if let audio, privacy.saveAudio {
            let url = Paths.audio.appending(path: "\(item.id.uuidString).caf")
            item.audioPath = url.path
            // Off the main thread: a 20-minute recording is ~77 MB (the hotkey tap runs on the main thread).
            Task.detached(priority: .utility) { try? AudioCapture.write(audio, to: url) }
        }
        if privacy.saveHistory { app.record(item, dictionaryUsed: result.dictionaryUsed) }

        if privacy.learnFromEdits, settings.autoLearnWords, outcome == .pasted, let element = snapshot.focusedElement {
            watchEdits(element: element, pasted: result.text)
        }
    }

    /// Re-runs transcription on saved audio (Undo after cancel, Retry from history).
    func retranscribe(_ buffer: AVAudioPCMBuffer, mode: DictationMode, snapshot: ContextReader.Snapshot,
                      recorded: (duration: Double, speech: Double)) async {
        guard state == .idle else { return }
        state = .processing
        releasedAt = ProcessInfo.processInfo.systemUptime
        dictationBar.show(.processing(mode))
        do {
            let vocabulary = VocabularyBuilder.engineHints(dictionary: app.dictionary, contextTerms: snapshot.context.terms)
            let session = try await engine.makeSession(vocabulary: vocabulary, naturalFormat: buffer.format)
            if let converter = BufferConverter(from: buffer.format, to: session.audioFormat), let converted = converter.convert(buffer) {
                session.append(converted)
            }
            let raw = try await session.finish()
            await deliver(raw: raw, mode: mode == .command ? .hold : mode, snapshot: snapshot, audio: buffer, recorded: recorded)
        } catch {
            fail("Couldn't transcribe: \(error.localizedDescription)")
        }
    }

    /// Debug/E2E: full pipeline on an audio buffer, no paste; the result is written to debug-last.json.
    func transcribeForTesting(_ buffer: AVAudioPCMBuffer, context: DictationContext) async {
        let started = ContinuousClock.now
        do {
            let vocabulary = VocabularyBuilder.engineHints(dictionary: app.dictionary, contextTerms: [])
            let session = try await engine.makeSession(vocabulary: vocabulary, naturalFormat: buffer.format)
            if let converter = BufferConverter(from: buffer.format, to: session.audioFormat), let converted = converter.convert(buffer) {
                session.append(converted)
            }
            let raw = try await Self.withTimeout(.seconds(20)) { try await session.finish() }
            let asrDone = ContinuousClock.now
            let pipeline = makePipeline(cleanupLevel: settings.cleanupLevel)
            let result = await pipeline.process(raw: raw, context: context)
            let cleanupDone = ContinuousClock.now
            // Each model tier on its own, so a silent fallback to rules is explainable.
            var tiers: [String: String] = [:]
            let probe = PolishRequest(text: raw, level: settings.cleanupLevel, style: result.style, category: context.category)
            for (name, tier) in [("fast", polisher.fast), ("strong", polisher.strong)] where TextTools.wordCount(raw) <= DictationPipeline.chunkWords {
                guard let tier else { tiers[name] = "not ready"; continue }
                do { tiers[name] = try await tier.polish(probe) } catch { tiers[name] = "error: \(error)" }
            }
            let report: [String: Any] = [
                "tiers": tiers,
                "route": "\(PolishRouter.route(text: raw, category: context.category, level: settings.cleanupLevel, relevantVocabulary: []))",
                "raw": raw, "text": result.text, "status": result.status.rawValue, "polisher": result.polisherID ?? "rules",
                "asrMs": (asrDone - started).components.attoseconds / 1_000_000_000_000_000 + (asrDone - started).components.seconds * 1000,
                "cleanupMs": (cleanupDone - asrDone).components.attoseconds / 1_000_000_000_000_000 + (cleanupDone - asrDone).components.seconds * 1000,
                "engine": polisher.summary,
                "asrEngine": engine.id,
            ]
            if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
                try? data.write(to: Paths.appSupport.appending(path: "debug-last.json"))
            }
        } catch {
            try? "{\"error\": \"\(error.localizedDescription)\"}".write(to: Paths.appSupport.appending(path: "debug-last.json"), atomically: true, encoding: .utf8)
        }
    }

    /// History → Retry: re-transcribe the saved audio, update that entry, and copy the new text.
    func retry(_ item: HistoryItem) async {
        guard state == .idle, let path = item.audioPath,
              let file = try? AVAudioFile(forReading: URL(fileURLWithPath: path)),
              let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)),
              (try? file.read(into: buffer)) != nil else {
            dictationBar.toast("The recording for this dictation is no longer available", style: .error)
            return
        }
        state = .processing
        dictationBar.show(.processing(item.mode))
        defer { state = .idle }
        do {
            let vocabulary = VocabularyBuilder.engineHints(dictionary: app.dictionary, contextTerms: [])
            let session = try await engine.makeSession(vocabulary: vocabulary, naturalFormat: buffer.format)
            if let converter = BufferConverter(from: buffer.format, to: session.audioFormat), let converted = converter.convert(buffer) {
                session.append(converted)
            }
            let raw = try await Self.withTimeout(.seconds(20)) { try await session.finish() }
            let pipeline = makePipeline(cleanupLevel: item.cleanupLevel)
            let context = DictationContext(appBundleID: item.appBundleID, appName: item.appName, category: item.category)
            let result = await pipeline.process(raw: raw, context: context)
            try? app.store.updateTranscript(id: item.id, raw: raw, formatted: result.text, status: result.status, polisher: result.polisherID)
            app.reloadHistory()
            inserter.copy(result.text)
            dictationBar.toast("Retried — new text copied to clipboard", duration: 3)
        } catch {
            dictationBar.toast("Retry failed: \(error.localizedDescription)", style: .error)
        }
    }

    private func fail(_ message: String) {
        audio.stop()
        MediaMuter.restore()
        state = .idle
        onSessionEnded?()
        sounds.play(.error)
        dictationBar.toast(message, style: .error, duration: 5)
    }

    static let chatEditors: Set<String> = ["com.todesktop.230313mzl4w4u92", "com.exafunction.windsurf"]

    /// Code-aware formatting in editors and terminals (Settings → Vibe coding).
    /// Every pipeline the app runs is built here, so none misses Apple's English vocabulary (without it,
    /// dictionary names rewrite ordinary words: "brand" → "Brandt").
    private func makePipeline(cleanupLevel: CleanupLevel, useModel: Bool = true) -> DictationPipeline {
        var pipeline = DictationPipeline(snippets: app.snippets, dictionary: app.dictionary, cleanupLevel: cleanupLevel,
                                         styles: app.settings.styles, polisher: useModel && polisher.isAvailable ? polisher : nil)
        pipeline.isEnglishWord = TermExtractor.isEnglishWord
        return pipeline
    }

    private func codeFormatter(for context: DictationContext) -> CodeFormatter? {
        let inCode = context.category == .code || context.category == .terminal
        guard inCode, settings.variableRecognition || settings.fileTagging else { return nil }
        let visible = [context.windowTitle, context.textBeforeCursor, context.textAfterCursor].compactMap { $0 }.joined(separator: "\n")
        let tag = settings.fileTagging && Self.chatEditors.contains(context.appBundleID ?? "")
        return CodeFormatter(knownFiles: CodeFormatter.fileNames(in: visible), tagFiles: tag)
    }

    static func stripPressEnter(_ text: String) -> String? {
        guard let re = TextTools.regex(#"[\s,.]*\bpress enter[.!]?\s*$"#),
              let match = re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range, in: text) else { return nil }
        return String(text[..<range.lowerBound])
    }

    // MARK: - Command Mode

    private func runCommand(instruction: String, snapshot: ContextReader.Snapshot) async {
        defer {
            state = .idle
            onSessionEnded?()
        }
        let instruction = instruction.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !instruction.isEmpty else { dictationBar.hide(); return }
        guard polisher.isAvailable else {
            dictationBar.toast(polisher.unavailableReason ?? "Command Mode needs an AI model (Apple Intelligence or an Enhancement)", style: .error, duration: 5)
            return
        }
        do {
            var selection = snapshot.context.selectedText
            if selection == nil { selection = await SelectionReader.read() }
            if let selection, !selection.isEmpty {
                let rewritten = try await Self.withTimeout(Self.modelTaskLimit) { [polisher = self.polisher] in try await polisher.transform(selection, instructions: instruction) }
                await inserter.insert(rewritten)
                app.lastTransformRun = TransformRun(name: "Command Mode", instruction: instruction, before: selection, after: rewritten)
                dictationBar.toast("Edited with Command Mode", action: "View changes") { [weak self] in self?.app.showDiffWindow() }
            } else {
                let context = snapshot.context.textBeforeCursor
                let answer = try await Self.withTimeout(Self.modelTaskLimit) { [polisher = self.polisher] in try await polisher.answer(instruction, context: context) }
                dictationBar.show(.answer(.init(question: instruction, text: answer)))
            }
        } catch {
            dictationBar.toast("Command Mode failed: \(error.localizedDescription)", style: .error, duration: 5)
        }
    }

    // MARK: - Transforms (⌥1…⌥9)

    func runTransform(_ transform: TransformDefinition, on text: String? = nil) async {
        guard state == .idle else { return }
        guard polisher.isAvailable else {
            dictationBar.toast(polisher.unavailableReason ?? "Transforms need an AI model (Apple Intelligence or an Enhancement)", style: .error, duration: 5)
            return
        }
        editWatch?.cancel()
        var selected = text
        if selected == nil { selected = await SelectionReader.read() }
        guard let source = selected, !source.isEmpty else {
            dictationBar.toast("Select some text first", duration: 2.5)
            return
        }
        state = .processing
        dictationBar.show(.processing(.command))
        defer { state = .idle }
        do {
            let instructions = TransformPrompt.instructions(for: transform)
            let rewritten = try await Self.withTimeout(Self.modelTaskLimit) { [polisher = self.polisher] in try await polisher.transform(source, instructions: instructions) }
            await inserter.insert(rewritten)
            app.lastTransformRun = TransformRun(name: transform.name, instruction: transform.summary, before: source, after: rewritten)
            dictationBar.toast("\(transform.name) applied", action: "View changes") { [weak self] in self?.app.showDiffWindow() }
        } catch {
            dictationBar.toast("\(transform.name) failed: \(error.localizedDescription)", style: .error, duration: 5)
        }
    }

    // MARK: - Learning from edits

    /// Debug/E2E: learn from edits to `app`'s focused field as if `pasted` had just been dictated into it
    /// (nothing is pasted or typed; the test edits the field itself).
    func watchForTesting(bundleID: String, pasted: String) {
        guard let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first else { return }
        let application = AXUIElementCreateApplication(running.processIdentifier)
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(application, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let focused, CFGetTypeID(focused) == AXUIElementGetTypeID() else {
            dictationBar.toast("Debug: no focused text field in \(bundleID)", style: .error)
            return
        }
        watchEdits(element: focused as! AXUIElement, pasted: pasted)
    }

    /// After pasting, follow the pasted text in the field for up to a minute. When the
    /// correction settles (3 s), is sent (Enter / the box empties) or focus moves away, the corrected words
    /// go into the dictionary with an Undo toast.
    private func watchEdits(element: AXUIElement, pasted: String) {
        editWatch?.cancel()
        let rejected = Set(settings.rejectedLearnedWords)
        editWatch = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard let field = ContextReader.value(of: element), field.count < 20_000,
                  var observation = EditObservation(field: field, pasted: pasted) else { return }
            let learner = EditDiffLearner(rejected: rejected) { word in
                MainActor.assumeIsolated { NSSpellChecker.shared.checkSpelling(of: word, startingAt: 0).location == NSNotFound }
            }
            let started = ContinuousClock.now
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(500))
                guard !Task.isCancelled else { return }
                let elapsed = ContinuousClock.now - started
                let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
                // Focus moved or the field is gone: decide with what we saw last.
                let value = Self.isFocused(element) ? ContextReader.value(of: element) ?? "" : ""
                switch observation.observe(value, at: seconds) {
                case .keepWatching: continue
                case .stop: return
                case .learn(let edited):
                    let words = learner.learnedWords(pasted: observation.pasted, edited: edited)
                    if !words.isEmpty { self?.app.learn(words) }
                    return
                }
            }
        }
    }

    /// Whether `element` is still the focused element of the frontmost app.
    private static func isFocused(_ element: AXUIElement) -> Bool {
        guard let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier else { return false }
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(AXUIElementCreateApplication(pid), kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let focused else { return false }
        return CFEqual(focused, element)
    }
}

struct TransformRun: Equatable {
    var name: String
    var instruction: String
    var before: String
    var after: String
    var date = Date()
}

enum TransformPrompt {
    static func instructions(for transform: TransformDefinition) -> String {
        switch transform.kind {
        case .polish:
            let rules = PolishRule.allCases.filter { transform.rules[$0.rawValue] ?? false }.map { "- \($0.instruction)" }
            return "Polish this text.\n" + rules.joined(separator: "\n")
                + "\n- Keep the author's meaning, facts and language. Do not add new information."
        case .promptEngineer, .custom:
            return transform.instructions
        }
    }
}

/// First result wins; later ones are ignored.
private final class Race<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    var continuation: CheckedContinuation<T, Error>?

    func finish(with result: Result<T, Error>) {
        let waiting: CheckedContinuation<T, Error>? = lock.withLock {
            defer { continuation = nil }
            return continuation
        }
        waiting?.resume(with: result)
    }
}

extension Result where Failure == Error {
    init(catching body: () async throws -> Success) async {
        do { self = .success(try await body()) } catch { self = .failure(error) }
    }
}
