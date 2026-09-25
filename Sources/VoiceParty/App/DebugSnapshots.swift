import AppKit
import SwiftUI
import VoicePartyCore

/// Developer aid (voiceparty://debug/snapshot, only with the DebugURLs default): renders every hub page,
/// every Settings page and the dictation bar states to PNGs in an invisible window, so layout can be checked
/// without taking over the screen.
@MainActor
enum DebugSnapshots {
    static func render(app: AppModel, to directory: URL, dark: Bool, hubHeight: CGFloat = 740) async {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // The menu bar the app shows while its window is in front, and whether it's a regular app right now.
        let menus = (NSApp.mainMenu?.items ?? []).map { item in
            "\(item.title): " + (item.submenu?.items.map { $0.isSeparatorItem ? "—" : $0.title + ($0.keyEquivalent.isEmpty ? "" : " ⌘\($0.keyEquivalent)") } ?? []).joined(separator: ", ")
        }
        let policy = NSApp.activationPolicy() == .regular ? "regular" : "accessory"
        let windows = NSApp.windows.filter { !$0.title.isEmpty }.map { "window \($0.title): visible=\($0.isVisible)" }
        let dictationBarMenu = app.menus.dictationBarMenu().items.map { item in
            item.isSeparatorItem ? "—" : item.title + (item.submenu.map { " ▸ [" + $0.items.map { $0.isSeparatorItem ? "—" : $0.title }.joined(separator: ", ") + "]" } ?? "")
        }
        try? (["policy: \(policy)", "secure input blocked by: \(app.secureInputOwner ?? "none")"] + windows + menus + ["dictation bar right-click: " + dictationBarMenu.joined(separator: " | ")]).joined(separator: "\n").write(to: directory.appending(path: "menus.txt"), atomically: true, encoding: .utf8)
        let suffix = dark ? "-dark" : ""
        let navigation = HubNavigation()
        await capture(HubView(app: app, navigation: navigation), size: NSSize(width: 1120, height: hubHeight), dark: dark) { host in
            for section in HubSection.allCases {
                navigation.section = section
                try? await Task.sleep(for: .milliseconds(700))
                save(host, to: directory.appending(path: "hub-\(section.rawValue)\(suffix).png"))
            }
            // Dictionary in bulk-select mode with two entries checked.
            navigation.section = .home
            navigation.debugSelectDictionaryEntries = 2
            try? await Task.sleep(for: .milliseconds(300))
            navigation.section = .dictionary
            try? await Task.sleep(for: .milliseconds(700))
            save(host, to: directory.appending(path: "hub-dictionary-selecting\(suffix).png"))
            navigation.debugSelectDictionaryEntries = 0
            // A meeting note, opened.
            if let note = app.notes.first {
                navigation.selectedNote = note.id
                navigation.section = .notes
                try? await Task.sleep(for: .milliseconds(700))
                save(host, to: directory.appending(path: "hub-notes-detail\(suffix).png"))
                navigation.selectedNote = nil
            }
        }
        for section in SettingsView.Section.allCases {
            await capture(SettingsView(app: app, section: section), size: NSSize(width: 820, height: 600), dark: dark) { host in
                try? await Task.sleep(for: .milliseconds(500))
                save(host, to: directory.appending(path: "settings-\(section.rawValue.replacingOccurrences(of: " ", with: "-"))\(suffix).png"))
            }
        }
        let bar = DictationBarModel()
        let phases: [(String, DictationBarModel.Phase)] = [
            ("resting", .resting), ("listening-ptt", .listening(.hold)), ("listening-handsfree", .listening(.handsFree)),
            ("command", .listening(.command)), ("processing", .processing(.hold)),
            ("toast", .toast(.init(message: "Transcript cancelled", actionTitle: "Undo"))),
            ("toast-error", .toast(.init(message: "Select a text box first", actionTitle: "Copy", style: .error))),
            ("answer", .answer(.init(question: "What's the capital of France?", text: "Paris is the capital of France."))),
        ]
        await capture(DictationBarView(model: bar), size: NSSize(width: 480, height: 260), dark: dark, background: .gray) { host in
            for (name, phase) in phases {
                bar.phase = phase
                bar.level = 0.5
                try? await Task.sleep(for: .milliseconds(500))
                save(host, to: directory.appending(path: "dictationbar-\(name)\(suffix).png"))
            }
        }
    }

    private static func capture<V: View>(_ view: V, size: NSSize, dark: Bool, background: NSColor? = nil,
                                         body: (NSView) async -> Void) async {
        let window = NSWindow(contentRect: NSRect(x: -20_000, y: -20_000, width: size.width, height: size.height),
                              styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: false)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isReleasedWhenClosed = false
        window.alphaValue = 0
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        if let background { window.backgroundColor = background }
        let host = NSHostingView(rootView: view)
        window.contentView = host
        window.orderBack(nil)
        await body(host)
        window.orderOut(nil)
        window.close()
    }

    private static func save(_ view: NSView, to url: URL) {
        view.layoutSubtreeIfNeeded()
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }
}
