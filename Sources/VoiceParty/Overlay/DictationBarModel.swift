import Foundation
import Observation
import VoicePartyCore

/// State of the floating dictation bar.
@MainActor
@Observable
final class DictationBarModel {
    struct Toast: Equatable, Identifiable {
        enum Style { case normal, error }
        let id = UUID()
        var message: String
        var actionTitle: String?
        var style: Style = .normal
        var duration: TimeInterval = 4
        var action: (() -> Void)?

        static func == (a: Toast, b: Toast) -> Bool { a.id == b.id }
    }

    struct Answer: Equatable {
        var question: String
        var text: String
    }

    enum Phase: Equatable {
        case hidden
        /// "Always show the dictation bar": a small resting capsule.
        case resting
        case listening(DictationMode)
        case processing(DictationMode)
        case toast(Toast)
        case answer(Answer)
        /// The Notetaker is recording a meeting: a small timer pill with Stop.
        case notetaking
    }

    var phase: Phase = .hidden {
        didSet { if case .listening = phase {} else { notice = nil } }
    }
    /// A short line above the recording pill ("1 minute left"); cleared when recording ends.
    var notice: String?
    /// Latest mic level 0…1 (the view animates bars around it).
    var level: Float = 0
    var hovering = false
    var hotkeyName = "fn"

    var onCancel: (() -> Void)?
    var onFinish: (() -> Void)?
    var onStartFromBar: (() -> Void)?
    var onInsertAnswer: ((String) -> Void)?
    var onCopyAnswer: ((String) -> Void)?

    var showRestingBar = false
    /// Set while the Notetaker records; the bar rests on its timer pill instead of hiding.
    var notetakerStartedAt: Date? {
        didSet { if phase == .hidden || phase == .resting || phase == .notetaking { hide() } }
    }
    var onStopNotetaker: (() -> Void)?
    var onShowNotepad: (() -> Void)?

    private var toastTask: Task<Void, Never>?

    var isInteractive: Bool {
        switch phase {
        case .listening(.handsFree), .listening(.command), .toast, .answer, .resting, .notetaking: true
        default: false
        }
    }

    func show(_ phase: Phase) {
        toastTask?.cancel()
        self.phase = phase
        if case .toast(let toast) = phase {
            toastTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(toast.duration))
                guard !Task.isCancelled, let self, self.phase == .toast(toast) else { return }
                self.hide()
            }
        }
    }

    func toast(_ message: String, action: String? = nil, style: Toast.Style = .normal, duration: TimeInterval = 4, perform: (() -> Void)? = nil) {
        show(.toast(Toast(message: message, actionTitle: action, style: style, duration: duration, action: perform)))
    }

    func hide() {
        toastTask?.cancel()
        phase = notetakerStartedAt != nil ? .notetaking : showRestingBar ? .resting : .hidden
        level = 0
    }
}
