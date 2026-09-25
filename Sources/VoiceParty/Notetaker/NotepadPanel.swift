import AppKit
import SwiftUI

/// A small floating notepad while the Notetaker records: jot what matters and it's saved with the meeting
/// and given priority in the notes. It takes typing without pulling you out of your call app.
@MainActor
final class NotepadPanel: NSPanel {
    init(notetaker: NotetakerController, onClose: @escaping () -> Void) {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 320, height: 360),
                   styleMask: [.titled, .closable, .resizable, .utilityWindow, .nonactivatingPanel], backing: .buffered, defer: false)
        title = "Meeting notes"
        isFloatingPanel = true
        level = .floating
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        becomesKeyOnlyIfNeeded = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        contentView = NSHostingView(rootView: NotepadView(notetaker: notetaker))
        closeHandler = onClose
        // Top right of the screen you're on, out of the way of the call window.
        if let screen = NSScreen.screens.first(where: { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) }) ?? NSScreen.main {
            let visible = screen.visibleFrame
            setFrameOrigin(NSPoint(x: visible.maxX - frame.width - 24, y: visible.maxY - frame.height - 24))
        }
    }

    private var closeHandler: (() -> Void)?

    override var canBecomeKey: Bool { true }

    override func close() {
        super.close()
        closeHandler?()
    }
}

private struct NotepadView: View {
    @Bindable var notetaker: NotetakerController

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Anything you write here is saved with the meeting and leads the summary.")
                .font(.system(size: 11)).foregroundStyle(.secondary)
            TextEditor(text: $notetaker.userNotes)
                .font(.system(size: 13))
                .scrollContentBackground(.hidden)
                .padding(6)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .textBackgroundColor)))
        }
        .padding(12)
        .frame(minWidth: 240, minHeight: 200)
    }
}
