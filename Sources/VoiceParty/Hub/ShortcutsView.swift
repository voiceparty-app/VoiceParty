import Observation
import SwiftUI
import VoicePartyCore

/// Captures a shortcut from the global event tap (so fn, sided modifiers and mouse buttons work).
@MainActor
@Observable
final class ShortcutRecorder {
    var pressed: Set<KeyToken> = []
    var captured: Set<KeyToken> = []
    @ObservationIgnored var onFinish: ((KeyCombo) -> Void)?

    func feed(_ event: KeyEvent) {
        switch event.kind {
        case .down(let token, let isRepeat):
            guard !isRepeat else { return }
            pressed.insert(token)
            captured.formUnion(pressed)
        case .up(let token):
            pressed.remove(token)
            if pressed.isEmpty, !captured.isEmpty {
                onFinish?(Self.normalize(captured))
                captured.removeAll()
            }
        }
    }

    /// A lone modifier keeps its side (Right ⌥ alone leaves Left ⌥ free for typing); in combos, either side works.
    static func normalize(_ tokens: Set<KeyToken>) -> KeyCombo {
        if tokens.count == 1, let only = tokens.first, only.isModifier { return KeyCombo(tokens) }
        return KeyCombo(Set(tokens.map(\.generic)))
    }
}

struct ShortcutsView: View {
    @Bindable var app: AppModel
    var onDone: () -> Void
    @State private var recordingFor: HotkeyActionID?
    @State private var recorder = ShortcutRecorder()
    @State private var issue: String?

    private let actions: [HotkeyActionID] = [
        .pushToTalk, .handsFree, .commandMode, .pressEnter, .pasteLastTranscript, .copyLastTranscript, .viewTransformChanges, .cancel,
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Shortcuts").font(.system(size: 18, weight: .semibold))
                    Text("Pick the keys (or mouse buttons) for each action.").font(.system(size: 13)).foregroundStyle(.secondary)
                }
                Spacer()
                Button(action: finish) { Image(systemName: "xmark") }.buttonStyle(.plain)
            }
            if let issue {
                Label(issue, systemImage: "exclamationmark.triangle").font(.system(size: 12)).foregroundStyle(Theme.highlight)
            }
            ScrollView {
                VStack(spacing: 12) {
                    ForEach(actions, id: \.self) { action in row(action) }
                }
            }
            HStack {
                Menu("Reset to default") {
                    Button("fn key (Apple keyboards)") { app.settings.shortcuts = .defaults(primary: .fn) }
                    Button("Right ⌥ Option") { app.settings.shortcuts = .defaults(primary: .rightOption) }
                    Button("⌃ Control + ⌥ Option") { app.settings.shortcuts = .defaults(primary: .rightControl) }
                }
                .fixedSize()
                Spacer()
                Button("Done", action: finish).buttonStyle(PrimaryButtonStyle())
            }
        }
        .padding(22)
        .frame(width: 620, height: 600)
        .onDisappear { app.shortcutRecorder = nil }
    }

    private func row(_ action: HotkeyActionID) -> some View {
        let combos = app.settings.shortcuts.combos(for: action)
        return HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 3) {
                Text(action.displayName).font(.system(size: 14, weight: .semibold))
                Text(action.summary).font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 20)
            VStack(alignment: .trailing, spacing: 8) {
                if action == .handsFree {
                    Toggle(isOn: $app.settings.shortcuts.doubleTapForHandsFree) {
                        HStack(spacing: 4) {
                            Text("Double tap").font(.system(size: 12))
                            ForEach(app.settings.shortcuts.combos(for: .pushToTalk).prefix(1), id: \.self) { combo in
                                ForEach(combo.sortedTokens, id: \.self) { KeyCap(text: KeyNames.name($0)) }
                            }
                        }
                    }
                    .toggleStyle(.checkbox)
                }
                ForEach(combos, id: \.self) { combo in
                    HStack(spacing: 4) {
                        ForEach(combo.sortedTokens, id: \.self) { KeyCap(text: KeyNames.name($0)) }
                        Button {
                            app.settings.shortcuts.bindings[action] = combos.filter { $0 != combo }
                        } label: { Image(systemName: "trash").font(.system(size: 11)) }
                            .buttonStyle(.plain).foregroundStyle(.secondary).padding(.leading, 6)
                    }
                    .padding(.horizontal, 8).frame(height: 34)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Theme.card))
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.hairline))
                }
                if recordingFor == action {
                    Text(recorder.pressed.isEmpty ? "Press a shortcut…" : recorder.pressed.sorted().map(KeyNames.name).joined(separator: " + "))
                        .font(.system(size: 12)).foregroundStyle(Theme.accent)
                        .padding(.horizontal, 10).frame(height: 34)
                        .background(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.accent))
                } else if combos.count < ShortcutSettings.maxBindingsPerAction {
                    Button(combos.isEmpty ? "Click, then press the keys" : "+ Add another") { startRecording(action) }
                        .buttonStyle(SecondaryButtonStyle())
                }
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 12).fill(Theme.well))
    }

    private func startRecording(_ action: HotkeyActionID) {
        issue = nil
        recordingFor = action
        recorder = ShortcutRecorder()
        recorder.onFinish = { combo in
            let issues = ShortcutValidator.validate(combo, for: action, in: app.settings.shortcuts)
            if let first = issues.first {
                issue = "\(KeyNames.display(combo)): \(first.message)"
            } else {
                app.settings.shortcuts.bindings[action, default: []].append(combo)
            }
            recordingFor = nil
            app.shortcutRecorder = nil
        }
        app.shortcutRecorder = recorder
    }

    private func finish() {
        app.shortcutRecorder = nil
        onDone()
    }
}
