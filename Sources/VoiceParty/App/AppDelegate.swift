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

    /// Accessibility can be granted at any time in System Settings; pick it up without a relaunch.
    private func watchPermissions() {
        permissionTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let model = self?.model else { return }
                let now = Permissions.State.current()
                if now != model.permissions {
                    model.permissions = now
                    if now.accessibility && !model.eventTap.isRunning { model.startHotkeys() }
                }
            }
        }
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
            let delay = Double(query["delay"] ?? "") ?? 0
            model.modelServer.ensureRunning() // as if the dictation key were pressed
            Task {
                try? await Task.sleep(for: .seconds(delay)) // as if the user were speaking
                // Never pastes: results go to debug-last.json (E2E tests must not type into the user's apps).
                await model.dictation.transcribeForTesting(buffer, context: DictationContext(category: category))
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
            model.modelServer.hold()
        case "debug/release-models" where DebugURLs.enabled:
            model.modelServer.release()
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
