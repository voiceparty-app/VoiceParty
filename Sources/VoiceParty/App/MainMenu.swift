import AppKit
import VoicePartyCore

/// The Mac menu bar while a VoiceParty window is in front:
/// VoiceParty · File · Edit · Dictation · My Voice · View · Window · Help.
/// Dictation and My Voice are rebuilt each time they open, so counts and devices are current.
@MainActor
final class MainMenu: NSObject, NSMenuDelegate {
    private unowned let app: AppModel
    private let dictationMenu = NSMenu(title: "Dictation")
    private let myVoiceMenu = NSMenu(title: "My Voice")

    init(app: AppModel) {
        self.app = app
        super.init()
        dictationMenu.delegate = self
        myVoiceMenu.delegate = self
    }

    func install() {
        let bar = NSMenu()
        let window = windowMenu()
        let help = helpMenu()
        for menu in [appMenu(), fileMenu(), editMenu(), dictationMenu, myVoiceMenu, viewMenu(), window, help] {
            let item = NSMenuItem(title: menu.title, action: nil, keyEquivalent: "")
            item.submenu = menu
            bar.addItem(item)
        }
        NSApp.mainMenu = bar
        NSApp.windowsMenu = window
        NSApp.helpMenu = help
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        if menu.title == "File" {
            // Start Dictation, Start/Stop Notetaker, Close Window.
            menu.removeAllItems()
            menu.addItem(item("Start Dictation", #selector(startDictation)))
            menu.addItem(app.menus.notetakerItem())
            menu.addItem(.separator())
            menu.addItem(item("Close Window", #selector(NSWindow.performClose(_:)), "w", responder: true))
            return
        }
        menu.removeAllItems()
        if menu === dictationMenu { fillDictation(menu) } else if menu === myVoiceMenu { fillMyVoice(menu) }
    }

    // MARK: Menus

    private func appMenu() -> NSMenu {
        let menu = NSMenu(title: "VoiceParty")
        menu.addItem(item("About VoiceParty", #selector(NSApplication.orderFrontStandardAboutPanel(_:)), responder: true))
        menu.addItem(item("Check for Updates…", #selector(checkForUpdates)))
        menu.addItem(.separator())
        menu.addItem(item("Settings…", #selector(openSettings), ","))
        menu.addItem(.separator())
        menu.addItem(item("Hide VoiceParty", #selector(NSApplication.hide(_:)), "h", responder: true))
        menu.addItem(item("Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option], responder: true))
        menu.addItem(item("Show All", #selector(NSApplication.unhideAllApplications(_:)), responder: true))
        menu.addItem(.separator())
        menu.addItem(item("Quit VoiceParty", #selector(NSApplication.terminate(_:)), "q", responder: true))
        return menu
    }

    private func fileMenu() -> NSMenu {
        let menu = NSMenu(title: "File")
        menu.delegate = self
        menu.addItem(item("Start Dictation", #selector(startDictation)))
        menu.addItem(.separator())
        menu.addItem(item("Close Window", #selector(NSWindow.performClose(_:)), "w", responder: true))
        return menu
    }

    private func editMenu() -> NSMenu {
        let menu = NSMenu(title: "Edit")
        menu.addItem(item("Undo", Selector(("undo:")), "z", responder: true))
        menu.addItem(item("Redo", Selector(("redo:")), "z", [.command, .shift], responder: true))
        menu.addItem(.separator())
        menu.addItem(item("Cut", #selector(NSText.cut(_:)), "x", responder: true))
        menu.addItem(item("Copy", #selector(NSText.copy(_:)), "c", responder: true))
        menu.addItem(item("Paste", #selector(NSText.paste(_:)), "v", responder: true))
        menu.addItem(item("Select All", #selector(NSText.selectAll(_:)), "a", responder: true))
        return menu
    }

    private func fillDictation(_ menu: NSMenu) {
        menu.addItem(item("\(app.stats.totalWords.formatted()) words dictated", #selector(showInsights)))
        menu.addItem(.separator())
        let last = app.history.first { !$0.pastedText.isEmpty }?.pastedText
        let copy = item("Copy Last Transcript", #selector(copyLast), "c", [.control, .command])
        copy.isEnabled = last != nil
        menu.addItem(copy)
        if let last {
            let preview = NSMenuItem(title: MenuActions.preview(last), action: nil, keyEquivalent: "")
            preview.isEnabled = false
            preview.toolTip = last
            menu.addItem(preview)
        }
        menu.addItem(.separator())

        menu.addItem(app.menus.microphone())
        menu.addItem(app.menus.languages())
    }

    private func fillMyVoice(_ menu: NSMenu) {
        let words = app.dictionary.count
        let snippets = app.snippets.count
        menu.addItem(item("\(words.formatted()) dictionary \(words == 1 ? "word" : "words")", #selector(showDictionary)))
        menu.addItem(item("\(snippets.formatted()) \(snippets == 1 ? "snippet" : "snippets") created", #selector(showSnippets)))
        menu.addItem(.separator())
        menu.addItem(item("Add Dictionary Word", #selector(addWord)))
        menu.addItem(item("Create Snippet", #selector(createSnippet)))
    }

    private func viewMenu() -> NSMenu {
        let menu = NSMenu(title: "View")
        for (index, section) in HubSection.allCases.enumerated() {
            let entry = item(section.title, #selector(showSection(_:)), index < 9 ? "\(index + 1)" : "")
            entry.representedObject = section.rawValue
            menu.addItem(entry)
        }
        return menu
    }

    private func windowMenu() -> NSMenu {
        let menu = NSMenu(title: "Window")
        menu.addItem(item("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m", responder: true))
        menu.addItem(item("Close", #selector(NSWindow.performClose(_:)), responder: true))
        return menu
    }

    private func helpMenu() -> NSMenu {
        let menu = NSMenu(title: "Help")
        menu.addItem(item("Shortcuts", #selector(openSettings)))
        return menu
    }

    // MARK: Helpers

    /// `responder: true` sends the action up the responder chain (Copy/Paste, Close, Hide…); otherwise to this object.
    private func item(_ title: String, _ action: Selector?, _ key: String = "", _ modifiers: NSEvent.ModifierFlags = .command,
                      responder: Bool = false) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = modifiers
        item.target = responder ? nil : self
        return item
    }

    private func submenu(_ title: String, _ menu: NSMenu) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.submenu = menu
        return item
    }

    // MARK: Actions

    @objc private func openSettings() { app.windows.showHub(settings: true) }
    @objc private func checkForUpdates() {
        if case .available = app.updater.state { Task { await app.updater.install() } } else { Task { await app.updater.check(userInitiated: true) } }
    }
    @objc private func startDictation() { app.startHandsFreeFromUI() }
    @objc private func copyLast() { app.trigger(.copyLastTranscript) }
    @objc private func showInsights() { app.windows.showHub(section: .insights) }
    @objc private func showDictionary() { app.windows.showHub(section: .dictionary) }
    @objc private func showSnippets() { app.windows.showHub(section: .snippets) }
    @objc private func addWord() { app.windows.showHub(section: .dictionary, addNew: true) }
    @objc private func createSnippet() { app.windows.showHub(section: .snippets, addNew: true) }
    @objc private func showSection(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let section = HubSection(rawValue: raw) else { return }
        app.windows.showHub(section: section)
    }
}
