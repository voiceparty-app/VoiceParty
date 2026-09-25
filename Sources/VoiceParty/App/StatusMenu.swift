import AppKit
import VoicePartyCore

/// The menu-bar icon and its menu (rebuilt each time it opens so counts and history are fresh).
@MainActor
final class StatusMenu: NSObject, NSMenuDelegate {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private unowned let app: AppModel

    init(app: AppModel) {
        self.app = app
        super.init()
        item.button?.image = NSImage(systemSymbolName: "waveform", accessibilityDescription: "VoiceParty")
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        let start = add(menu, app.dictation.state == .idle ? "Start dictating" : "Finish dictation", #selector(toggleDictation))
        start.image = NSImage(systemSymbolName: "mic", accessibilityDescription: nil)
        add(menu, "Paste last transcript", #selector(pasteLast), key: "v", modifiers: [.control, .command])
        add(menu, "Copy last transcript", #selector(copyLast), key: "c", modifiers: [.control, .command])

        menu.addItem(app.menus.notetakerItem())
        menu.addItem(app.menus.transcriptHistory())

        menu.addItem(.separator())
        menu.addItem(app.menus.microphone())

        add(menu, "New dictionary word…", #selector(openDictionary))
        add(menu, "New snippet…", #selector(openSnippets))

        menu.addItem(.separator())
        let words = NSMenuItem(title: "Words dictated: \(app.stats.totalWords.formatted())", action: nil, keyEquivalent: "")
        words.isEnabled = false
        menu.addItem(words)
        if case .available(let version) = app.updater.state {
            add(menu, "Install VoiceParty \(version)…", #selector(installUpdate))
        }
        if let owner = app.secureInputOwner {
            let blocked = NSMenuItem(title: "⚠︎ Shortcuts blocked: \(owner) has Secure Keyboard Entry on", action: nil, keyEquivalent: "")
            blocked.isEnabled = false
            menu.addItem(blocked)
        }
        if let status = app.engineStatus ?? app.engineError {
            let info = NSMenuItem(title: status, action: nil, keyEquivalent: "")
            info.isEnabled = false
            menu.addItem(info)
        }
        menu.addItem(.separator())
        add(menu, "Open VoiceParty", #selector(openHub), key: "o")
        add(menu, "Settings…", #selector(openSettings), key: ",")
        add(menu, "Quit VoiceParty", #selector(quit), key: "q")
    }

    @discardableResult
    private func add(_ menu: NSMenu, _ title: String, _ action: Selector, key: String = "", modifiers: NSEvent.ModifierFlags = [.command]) -> NSMenuItem {
        let row = NSMenuItem(title: title, action: action, keyEquivalent: key)
        row.keyEquivalentModifierMask = key.isEmpty ? [] : modifiers
        row.target = self
        menu.addItem(row)
        return row
    }

    @objc private func toggleDictation() {
        if app.dictation.state == .idle { app.startHandsFreeFromUI() } else { app.dictation.finish() }
    }

    @objc private func pasteLast() { app.trigger(.pasteLastTranscript) }
    @objc private func copyLast() { app.trigger(.copyLastTranscript) }

    @objc private func installUpdate() { Task { await app.updater.install() } }
    @objc private func openDictionary() { app.windows.showHub(section: .dictionary, addNew: true) }
    @objc private func openSnippets() { app.windows.showHub(section: .snippets, addNew: true) }
    @objc private func openHub() { app.windows.showHub() }
    @objc private func openSettings() { app.windows.showHub(settings: true) }
    @objc private func quit() { NSApp.terminate(nil) }
}
