import AppKit
import AVFoundation
import VoicePartyCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private(set) var model: AppModel!
    private var dictationBarPanel: DictationBarPanel?
    private var statusMenu: StatusMenu?
    private var mainMenu: MainMenu?
    private var permissionTimer: Timer?

    func applicationWillFinishLaunching(_ notification: Notification) {
        // macOS adds "Start Dictation…" and "Emoji & Symbols" to any Edit menu; the first is confusing in a
        // dictation app (and both were being added more than once).
        UserDefaults.standard.register(defaults: ["NSDisabledDictationMenuItem": true, "NSDisabledCharacterPaletteMenuItem": true])
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        do {
            model = try AppModel()
        } catch {
            let alert = NSAlert()
            alert.messageText = "VoiceParty couldn't open its database"
            alert.informativeText = error.localizedDescription
            alert.runModal()
            NSApp.terminate(nil)
            return
        }
        mainMenu = MainMenu(app: model)
        mainMenu?.install()
        dictationBarPanel = DictationBarPanel(model: model.dictationBar)
        dictationBarPanel?.menuProvider = { [weak model] in model?.menus.dictationBarMenu() ?? NSMenu() }
        statusMenu = StatusMenu(app: model)
        model.start()

        // Someone who has granted access and dictated has clearly finished setting up.
        if !model.settings.hasCompletedOnboarding && model.permissions.allGranted && !model.history.isEmpty {
            model.settings.hasCompletedOnboarding = true
        }
        if !model.settings.hasCompletedOnboarding || !model.permissions.allGranted {
            model.windows.showOnboarding()
        } else if model.settings.showInDock && !ProcessInfo.processInfo.arguments.contains("--background") {
            // `--background`: relaunches during development/tests don't pull the window in front of your work.
            model.windows.showHub()
        }
        if ProcessInfo.processInfo.arguments.contains("--updated") {
            model.dictationBar.toast("Updated to VoiceParty \(Updater.currentVersion)", duration: 4)
        }
        watchPermissions()
        stopModelServersOnSignals()
    }

    private var signalSources: [DispatchSourceSignal] = []

    /// `kill`/logout send SIGTERM, which skips applicationWillTerminate: stop the model servers anyway.
    private func stopModelServersOnSignals() {
        for sig in [SIGTERM, SIGINT, SIGHUP] {
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            source.setEventHandler { [weak self] in
                MainActor.assumeIsolated {
                    self?.model?.notetaker.prepareForQuit()
                    self?.model?.modelServer.stopAll()
                    MediaMuter.restore()
                    exit(0)
                }
            }
            source.resume()
            signalSources.append(source)
        }
    }

    /// Accessibility can be granted at any time in System Settings; pick it up without a relaunch. While something is
    /// missing, check often (setup moves on the moment it's granted); once everything is granted, a slow check still
    /// notices a revocation without waking the Mac every second and a half all day.
    private func watchPermissions() {
        permissionTimer?.invalidate()
        let interval: TimeInterval = model.permissions.allGranted ? 10 : 1.5
        permissionTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let model = self.model else { return }
                let now = Permissions.State.current()
                if now != model.permissions {
                    let wasGranted = model.permissions.allGranted
                    model.permissions = now
                    if now.accessibility && !model.eventTap.isRunning { model.startHotkeys() }
                    if now.allGranted != wasGranted { self.watchPermissions() }
                }
            }
        }
        permissionTimer?.tolerance = interval / 5
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        model?.windows.showHub()
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        model?.notetaker.prepareForQuit()
        model?.modelServer.stopAll()
        MediaMuter.restore()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls { handle(url) }
    }

    /// voiceparty://debug/dictate?file=/path/to.wav — runs the full pipeline on a file and pastes the
    /// result into the focused app (used for end-to-end tests without speaking).
    private func handle(_ url: URL) {
        guard url.scheme == "voiceparty", let model else { return }
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let query = Dictionary((components?.queryItems ?? []).map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { first, _ in first })
        switch (url.host ?? "") + url.path {
        #if VOICEPARTY_DEBUG_URLS // development builds only (scripts/build-app.sh); releases leave these out
        case "debug/dictate" where DebugURLs.enabled:
            guard let path = query["file"], let file = try? AVAudioFile(forReading: URL(fileURLWithPath: path)),
                  let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)),
                  (try? file.read(into: buffer)) != nil else {
                model.dictationBar.toast("Debug: couldn't read audio file", style: .error)
                return
            }
            let category = AppCategory(rawValue: query["category"] ?? "") ?? .other
            // live=1: key-down does what a real dictation's does (model loading and warm-up), "speech" lasts as long
            // as the audio unless `delay` says otherwise, and tiers=0 leaves out the per-tier probes (energy runs).
            let live = query["live"] == "1"
            let delay = Double(query["delay"] ?? "") ?? (live ? Double(file.length) / file.processingFormat.sampleRate : 0)
            if live {
                model.dictation.warmModels(mode: DictationMode(rawValue: query["mode"] ?? "") ?? .hold, category: category)
            } else {
                model.modelServer.ensureRunning() // as if the dictation key were pressed
            }
            Task {
                try? await Task.sleep(for: .seconds(delay)) // as if the user were speaking
                // Never pastes: results go to debug-last.json (E2E tests must not type into the user's apps).
                await model.dictation.transcribeForTesting(buffer, context: DictationContext(category: category),
                                                           probeTiers: query["tiers"] != "0")
            }
        case "debug/snapshot" where DebugURLs.enabled:
            let directory = URL(fileURLWithPath: query["dir"] ?? NSTemporaryDirectory()).appending(path: "voiceparty-snapshots")
            Task {
                await DebugSnapshots.render(app: model, to: directory, dark: query["dark"] == "1",
                                           hubHeight: Double(query["height"] ?? "").map { CGFloat($0) } ?? 740)
                try? "done".write(to: directory.appending(path: "done"), atomically: true, encoding: .utf8)
            }
        case "debug/watch-edits" where DebugURLs.enabled:
            model.dictation.watchForTesting(bundleID: query["bundle"] ?? "", pasted: query["pasted"] ?? "")
        case "debug/ocr" where DebugURLs.enabled:
            // OCR + term extraction on an image file (tests screen reading without Screen Recording permission).
            guard let path = query["file"], let image = NSImage(contentsOfFile: path)?.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
            Task {
                let started = Date()
                let text = await ScreenOCR.recognizeText(in: image) ?? ""
                let report: [String: Any] = ["ms": Int(Date().timeIntervalSince(started) * 1000), "lines": text.split(separator: "\n").map(String.init),
                                             "terms": TermExtractor.terms(in: text, codeMode: false)]
                if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted]) {
                    try? data.write(to: Paths.appSupport.appending(path: "debug-ocr.json"))
                }
            }
        case "debug/mic-check" where DebugURLs.enabled:
            // Records 1.5 s (discarded) to check the capture path; reports start latency and frames captured.
            let capture = AudioCapture()
            _ = capture.beginRecording(deviceUID: model.settings.microphoneUID)
            Task {
                let started = Date()
                var report: [String: Any] = [:]
                do {
                    let format = try await capture.start()
                    report["startMs"] = Int(Date().timeIntervalSince(started) * 1000)
                    report["sampleRate"] = format.sampleRate
                    if query["switch"] == "1" {
                        // Halfway through, simulate AirPods connecting: recording must carry on.
                        try? await Task.sleep(for: .milliseconds(700))
                        report["secondsBeforeSwitch"] = capture.duration
                        capture.simulateDeviceChangeForTesting()
                        try? await Task.sleep(for: .milliseconds(800))
                    } else {
                        try? await Task.sleep(for: .milliseconds(1500))
                    }
                    report["seconds"] = capture.duration
                } catch {
                    report["error"] = error.localizedDescription
                }
                capture.stop()
                report["mainThreadFree"] = true
                if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
                    try? data.write(to: Paths.appSupport.appending(path: "debug-mic.json"))
                }
            }
        case "debug/notetaker" where DebugURLs.enabled:
            // A meeting from two files (you, others) → debug-note.json (never touches the mic or system audio).
            guard let mine = query["mine"], let others = query["others"] else { return }
            Task {
                let started = Date()
                let note = await model.notetaker.runForTesting(mine: URL(fileURLWithPath: mine), others: URL(fileURLWithPath: others),
                                                               userNotes: query["notes"] ?? "")
                let report: [String: Any] = ["seconds": Int(Date().timeIntervalSince(started)), "title": note?.title ?? "",
                                             "markdown": note?.markdown() ?? "(none)"]
                if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted]) {
                    try? data.write(to: Paths.appSupport.appending(path: "debug-note.json"))
                }
            }
        case "debug/hold-models" where DebugURLs.enabled:
            // A benchmark talking to the model servers directly: keep them loaded (no idle unload) until released.
            // `pid`: the benchmark's process; its hold ends when it exits, even if it never sends release-models.
            model.modelServer.hold(.tool(pid: query["pid"].flatMap { Int32($0) }))
        case "debug/release-models" where DebugURLs.enabled:
            model.modelServer.release(.tool(pid: query["pid"].flatMap { Int32($0) }))
        case "debug/bar" where DebugURLs.enabled:
            // The recording bar for `seconds` (default 20) with a speech-like mic level at the rate the mic delivers it
            // (energy of drawing the waveform; nothing is recorded). `level=0`: a silent room.
            let seconds = Double(query["seconds"] ?? "") ?? 20
            let peak = Float(query["level"] ?? "") ?? 0.5
            if query["state"] == "notes" { // the Notetaker's recording pill instead (nothing is recorded)
                model.dictationBar.notetakerStartedAt = Date()
                Task {
                    try? await Task.sleep(for: .seconds(seconds))
                    model.dictationBar.notetakerStartedAt = nil
                }
                return
            }
            model.dictationBar.show(.listening(.hold))
            Task {
                let end = Date().addingTimeInterval(seconds)
                var t = 0.0
                while Date() < end {
                    try? await Task.sleep(for: .milliseconds(21)) // 1024 frames at 48 kHz
                    t += 0.021
                    model.dictationBar.level = peak * Float(0.5 + 0.5 * sin(t * 3)) * Float(0.7 + 0.3 * sin(t * 17))
                }
                model.dictationBar.level = 0
                model.dictationBar.hide()
            }
        case "debug/load-models" where DebugURLs.enabled:
            // ?which=fast,strong (default both): what a dictation's key-down would load (energy of each model's load).
            let which = Set((query["which"] ?? "fast,strong").split(separator: ",").map(String.init))
            model.modelServer.ensureRunning(Set([which.contains("fast") ? EnhancementID.fastCleanup : nil,
                                                 which.contains("strong") ? EnhancementID.strongCleanup : nil].compactMap { $0 }))
        case "debug/unload-models" where DebugURLs.enabled:
            // As if the idle timer had fired (energy tests of cold starts); models held by a meeting or a bench stay.
            model.modelServer.unloadIfNotHeld()
        case "debug/memory" where DebugURLs.enabled:
            // ?free=20 pretends macOS reports 20% free memory (Automatic model memory without filling RAM); ?free=off
            // uses the real figure again. Writes debug-memory.json: free %, policy, each model's idle time and unload time.
            if let free = query["free"] { LocalModelServer.debugFreeMemoryPercent = Int(free) }
            // ?policy=automatic tries a policy in memory only (settings unchanged; a relaunch restores the saved one).
            if let policy = query["policy"].flatMap(ModelMemoryPolicy.init(rawValue:)) { model.modelServer.memoryPolicy = policy }
            if let data = try? JSONSerialization.data(withJSONObject: model.modelServer.debugMemoryReport(), options: [.prettyPrinted, .sortedKeys]) {
                try? data.write(to: Paths.appSupport.appending(path: "debug-memory.json"))
            }
        case "debug/model-args" where DebugURLs.enabled:
            // Flag experiments: ?fast=--poll 0&strong=-t 2 (space-separated; empty = shipped flags). In memory only:
            // the servers restart with them now and a relaunch forgets them.
            let split = { (value: String?) in value.map { $0.split(separator: " ").map(String.init) } ?? [] }
            // env=NAME=value NAME2=value: environment for both servers (NAME=- removes one; set before the restart below).
            model.modelServer.debugEnvironment = Dictionary(split(query["env"]).compactMap { pair -> (String, String)? in
                let parts = pair.split(separator: "=", maxSplits: 1).map(String.init)
                return parts.count == 2 ? (parts[0], parts[1]) : nil
            }, uniquingKeysWith: { _, last in last })
            model.modelServer.debugArguments = [EnhancementID.fastCleanup: split(query["fast"]), EnhancementID.strongCleanup: split(query["strong"])]
            // legacy=1: key-down loads and warms every model every time, as before the energy work (A/B in one session).
            DictationController.debugLegacyWarmUp = query["legacy"] == "1"
            if query["load"] == "1" { model.modelServer.ensureRunning() }
        case "debug/calendar" where DebugURLs.enabled:
            if let data = try? JSONSerialization.data(withJSONObject: CalendarReader.accessReport(), options: [.prettyPrinted, .sortedKeys]) {
                try? data.write(to: Paths.appSupport.appending(path: "debug-calendar.json"))
            }
        case "debug/update" where DebugURLs.enabled:
            // Check (from UpdateFeedURL) and install right away.
            Task {
                await model.updater.check(userInitiated: true)
                if case .available = model.updater.state { await model.updater.install() }
            }
        #endif
        case "open":
            let section = HubSection(rawValue: query["section"] ?? "")
            model.windows.showHub(section: section, behindOtherWindows: query["background"] == "1" && DebugURLs.enabled)
        case "import/wispr":
            // Any web page can open a voiceparty:// link: ask before changing the dictionary.
            let alert = NSAlert()
            alert.messageText = "Import your dictionary and snippets from Wispr Flow?"
            alert.informativeText = "Words and snippets are added to VoiceParty's; nothing is removed."
            alert.addButton(withTitle: "Import")
            alert.addButton(withTitle: "Cancel")
            NSApp.activate()
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            model.importFromWisprFlow()
        default:
            break
        }
    }
}
