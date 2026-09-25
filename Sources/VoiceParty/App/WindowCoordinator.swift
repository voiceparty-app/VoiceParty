import AppKit
import Observation
import SwiftUI

/// Which hub page is showing and whether a sheet should open (driven from the menu bar too).
@MainActor
@Observable
final class HubNavigation {
    var section: HubSection = .home
    var showSettings = false
    var addNewRequested = false
    /// The meeting note open on the Notes page.
    var selectedNote: UUID?
    /// Debug snapshots: open the Dictionary in bulk-select mode with this many entries checked.
    var debugSelectDictionaryEntries = 0
}

@MainActor
final class WindowCoordinator {
    private unowned let app: AppModel
    let navigation = HubNavigation()
    private var hubWindow: NSWindow?
    private var onboardingWindow: NSWindow?
    private var diffWindow: NSWindow?

    init(app: AppModel) {
        self.app = app
        // When the last window closes, go back to living in the menu bar (unless "Show in the Dock" is on).
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: nil, queue: .main) { [weak self] _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.updateActivationPolicy() } }
        }
    }

    /// A regular app (Dock icon + its own menu bar) while one of its windows is open or when the user wants
    /// it in the Dock; otherwise a menu-bar-only app.
    func updateActivationPolicy() {
        let windowOpen = [hubWindow, onboardingWindow, diffWindow].contains { $0?.isVisible == true }
        let policy: NSApplication.ActivationPolicy = app.settings.showInDock || windowOpen ? .regular : .accessory
        guard NSApp.activationPolicy() != policy else { return }
        NSApp.setActivationPolicy(policy)
    }

    func showHub(section: HubSection? = nil, settings: Bool = false, addNew: Bool = false, behindOtherWindows: Bool = false) {
        if let section { navigation.section = section }
        if settings { navigation.showSettings = true }
        if addNew { navigation.addNewRequested = true }
        if hubWindow == nil {
            let window = makeWindow(title: "VoiceParty", size: NSSize(width: 1120, height: 740),
                                    root: HubView(app: app, navigation: navigation))
            window.minSize = NSSize(width: 900, height: 600)
            window.setFrameAutosaveName("VoicePartyHub")
            hubWindow = window
        }
        if behindOtherWindows {
            hubWindow?.orderBack(nil) // debug/testing: don't take focus from the user's work
            return
        }
        present(hubWindow)
    }

    func showOnboarding() {
        if onboardingWindow == nil {
            onboardingWindow = makeWindow(title: "Welcome to VoiceParty", size: NSSize(width: 720, height: 640),
                                          root: OnboardingView(app: app) { [weak self] in
                                              self?.onboardingWindow?.close()
                                              self?.showHub()
                                          })
        }
        present(onboardingWindow)
    }

    func showDiff() {
        guard let run = app.lastTransformRun else {
            app.dictationBar.toast("No transform to show yet", duration: 2)
            return
        }
        diffWindow?.close()
        let window = makeWindow(title: "\(run.name) — changes", size: NSSize(width: 720, height: 520), root: DiffView(run: run))
        window.level = .floating
        diffWindow = window
        present(window)
    }

    private func makeWindow<V: View>(title: String, size: NSSize, root: V) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.title = title
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: root)
        window.center()
        return window
    }

    private func present(_ window: NSWindow?) {
        guard let window else { return }
        let wasAccessory = NSApp.activationPolicy() != .regular
        window.makeKeyAndOrderFront(nil)
        updateActivationPolicy()
        NSApp.activate()
        // An app that just became regular doesn't get its menu bar until it's activated again.
        if wasAccessory {
            DispatchQueue.main.async { NSApp.activate() }
        }
    }
}
