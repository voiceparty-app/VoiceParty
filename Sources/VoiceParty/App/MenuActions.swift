import AppKit
import VoicePartyCore

/// Menu pieces shared by the menu-bar icon, the app's menu bar and the dictation bar's right-click menu
/// (recent transcripts, microphone, languages), plus the actions they trigger.
@MainActor
final class MenuActions: NSObject {
    private unowned let app: AppModel

    init(app: AppModel) {
        self.app = app
        super.init()
    }

    /// Recent transcripts (click to copy) and "Show all" (the Dictation page).
    func transcriptHistory(limit: Int = 6) -> NSMenuItem {
        let menu = NSMenu()
        for entry in app.history.prefix(limit) where !entry.pastedText.isEmpty {
            let row = item(Self.preview(entry.pastedText), #selector(copyHistory(_:)))
            row.representedObject = entry.pastedText
            row.toolTip = "Copy"
            menu.addItem(row)
        }
        if menu.items.isEmpty {
            let empty = NSMenuItem(title: "No dictations yet", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
        }
        menu.addItem(.separator())
        menu.addItem(item("Show all", #selector(showHistory)))
        return submenu("Transcript history", menu)
    }

    func microphone() -> NSMenuItem {
        let menu = NSMenu()
        let systemDefault = item("System default", #selector(chooseMic(_:)))
        systemDefault.state = app.settings.microphoneUID == nil ? .on : .off
        menu.addItem(systemDefault)
        let devices = MicrophoneManager.inputDevices()
        func row(_ device: MicrophoneManager.Device) -> NSMenuItem {
            let row = item(device.name + (device.isBuiltIn ? " (recommended)" : ""), #selector(chooseMic(_:)))
            row.representedObject = device.uid
            row.state = app.settings.microphoneUID == device.uid ? .on : .off
            return row
        }
        devices.filter { !$0.isVirtual }.forEach { menu.addItem(row($0)) }
        // Virtual devices (Teams/Zoom audio, loopback tools) are rarely what you want to dictate into.
        let others = devices.filter(\.isVirtual)
        if !others.isEmpty {
            let more = NSMenu()
            others.forEach { more.addItem(row($0)) }
            let selected = others.contains { $0.uid == app.settings.microphoneUID }
            let entry = submenu("Other devices (\(others.count))", more)
            entry.state = selected ? .mixed : .off
            menu.addItem(.separator())
            menu.addItem(entry)
        }
        return submenu("Microphone", menu)
    }

    func languages() -> NSMenuItem {
        let menu = NSMenu()
        let english = NSMenuItem(title: "English", action: nil, keyEquivalent: "")
        english.state = .on
        menu.addItem(english)
        let more = NSMenuItem(title: "More languages later", action: nil, keyEquivalent: "")
        more.isEnabled = false
        menu.addItem(more)
        return submenu("Languages", menu)
    }

    /// Start/Stop Notetaker, with the running time while recording.
    func notetakerItem() -> NSMenuItem {
        switch app.notetaker.state {
        case .idle: return item("Start Notetaker", #selector(toggleNotetaker))
        case .recording(let since):
            return item("Stop Notetaker (\(NotetakerButton.elapsed(Date().timeIntervalSince(since))))", #selector(toggleNotetaker))
        case .wrappingUp:
            let row = NSMenuItem(title: "Writing meeting notes…", action: nil, keyEquivalent: "")
            row.isEnabled = false
            return row
        }
    }

    /// The dictation bar's right-click menu.
    func dictationBarMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(notetakerItem())
        if app.notetaker.isRecording { menu.addItem(item("Show Notepad", #selector(showNotepad))) }
        menu.addItem(.separator())
        menu.addItem(transcriptHistory())
        let paste = item("Paste last transcript", #selector(pasteLast))
        paste.isEnabled = app.history.contains { !$0.pastedText.isEmpty }
        menu.addItem(paste)
        menu.addItem(.separator())
        menu.addItem(microphone())
        menu.addItem(languages())
        menu.addItem(item("Formatting options", #selector(showStyle)))
        menu.addItem(item("Settings", #selector(openSettings)))
        if app.settings.showBarAlways {
            menu.addItem(.separator())
            menu.addItem(item("Hide for 1 hour", #selector(hideForAnHour)))
        }
        return menu
    }

    // MARK: Helpers

    func item(_ title: String, _ action: Selector) -> NSMenuItem {
        let row = NSMenuItem(title: title, action: action, keyEquivalent: "")
        row.target = self
        return row
    }

    func submenu(_ title: String, _ menu: NSMenu) -> NSMenuItem {
        let row = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        row.submenu = menu
        return row
    }

    static func preview(_ text: String) -> String {
        let flat = text.replacingOccurrences(of: "\n", with: " ")
        return flat.count > 48 ? String(flat.prefix(48)) + "…" : flat
    }

    // MARK: Actions

    @objc func copyHistory(_ sender: NSMenuItem) {
        guard let text = sender.representedObject as? String else { return }
        app.dictation.inserter.copy(text)
        app.dictationBar.toast("Copied to clipboard", duration: 1.8)
    }
    @objc func chooseMic(_ sender: NSMenuItem) { app.settings.microphoneUID = sender.representedObject as? String }
    @objc func pasteLast() { app.trigger(.pasteLastTranscript) }
    @objc func showHistory() { app.windows.showHub(section: .home) }
    @objc func showStyle() { app.windows.showHub(section: .style) }
    @objc func openSettings() { app.windows.showHub(settings: true) }
    @objc func hideForAnHour() { app.hideDictationBar(for: 3600) }
    @objc func showNotepad() { app.notetaker.showNotepad() }
    @objc func toggleNotetaker() {
        if app.notetaker.isRecording { Task { await app.notetaker.stop() } } else { app.notetaker.start() }
    }
}
