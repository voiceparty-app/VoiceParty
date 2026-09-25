import AppKit
import SwiftUI

/// A borderless, non-activating panel that floats over everything (including full-screen apps)
/// and never takes focus, so pasting still lands in the app you were typing in.
@MainActor
final class DictationBarPanel: NSPanel {
    private let model: DictationBarModel
    private var observation: Task<Void, Never>?

    init(model: DictationBarModel) {
        self.model = model
        super.init(contentRect: NSRect(x: 0, y: 0, width: 480, height: 260),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        becomesKeyOnlyIfNeeded = true
        animationBehavior = .none

        let host = DictationBarHostingView(rootView: DictationBarView(model: model))
        host.sizingOptions = []
        contentView = host
        track()
    }

    /// Keep the bar out of screen recordings and shares (off by default so screenshots show it).
    func setHiddenFromCapture(_ hidden: Bool) {
        sharingType = hidden ? .none : .readOnly
    }

    /// The right-click menu (transcript history, paste last, microphone…), built when it opens.
    var menuProvider: (() -> NSMenu)? {
        get { (contentView as? DictationBarHostingView)?.menuProvider }
        set { (contentView as? DictationBarHostingView)?.menuProvider = newValue }
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// Re-positions on the screen with the mouse and toggles click-through whenever the phase changes.
    private func track() {
        withObservationTracking {
            _ = model.phase
            _ = model.hovering
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.refresh()
                self?.track()
            }
        }
        refresh()
    }

    private func refresh() {
        if model.phase == .hidden {
            orderOut(nil)
            return
        }
        ignoresMouseEvents = !model.isInteractive
        reposition()
        if !isVisible { orderFrontRegardless() }
    }

    func reposition() {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return }
        let size = frame.size
        setFrameOrigin(NSPoint(x: visible.midX - size.width / 2, y: visible.minY))
    }
}

/// Hosts the bar and supplies its right-click menu.
final class DictationBarHostingView: NSHostingView<DictationBarView> {
    var menuProvider: (() -> NSMenu)?

    override func menu(for event: NSEvent) -> NSMenu? {
        menuProvider?() ?? super.menu(for: event)
    }
}
