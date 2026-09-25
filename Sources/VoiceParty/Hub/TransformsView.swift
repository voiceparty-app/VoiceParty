import SwiftUI
import VoicePartyCore

struct TransformsView: View {
    @Bindable var app: AppModel
    @State private var editing: TransformDefinition?
    @State private var trying: TransformDefinition?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                PageHeader(title: "Transforms") {
                    HStack(spacing: 6) {
                        KeyCap(text: "⌥ Opt"); KeyCap(text: "O")
                        Text("to view changes").font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                }
                PromoCard(title: Text("Rewrite selected text in any app"),
                          detail: "Select text in any app and press a transform's shortcut to rewrite, clean up or restructure it with the on-device model. Or run one automatically after every dictation.",
                          examples: ["⌥1 Polish", "⌥2 AI Prompt"])

                if let reason = app.dictation.polisher.unavailableReason {
                    Card {
                        Label(reason, systemImage: "exclamationmark.triangle").foregroundStyle(Theme.highlight)
                    }
                }

                SettingsGroup {
                    SettingsRow(title: "Apply automatically", detail: "Runs the chosen transform on every dictation before it's inserted.", showDivider: false) {
                        Picker("", selection: Binding(get: { app.settings.autoApplyTransform }, set: { app.settings.autoApplyTransform = $0 })) {
                            Text("Off").tag(UUID?.none)
                            ForEach(app.transforms) { Text($0.name).tag(UUID?.some($0.id)) }
                        }
                        .labelsHidden().fixedSize()
                    }
                }

                HStack {
                    Text("My Transforms").font(Theme.display(24))
                    Spacer()
                    Button {
                        try? app.store.resetTransformsToDefaults()
                        app.reloadPersonalization()
                    } label: { Label("Reset to defaults", systemImage: "arrow.counterclockwise") }
                        .buttonStyle(.plain)
                    Button("Create New") {
                        editing = TransformDefinition(kind: .custom, name: "", summary: "", instructions: "", slot: nextFreeSlot)
                    }
                    .buttonStyle(PrimaryButtonStyle())
                }

                LazyVGrid(columns: [GridItem(.adaptive(minimum: 230), spacing: 14)], spacing: 14) {
                    ForEach(app.transforms) { transform in
                        TransformCard(transform: transform) { editing = transform }
                    }
                    Button {
                        editing = TransformDefinition(kind: .custom, name: "", summary: "", instructions: "", slot: nextFreeSlot)
                    } label: {
                        VStack(alignment: .leading, spacing: 8) {
                            // Same height as the key caps on the other cards, so titles line up across the row.
                            Image(systemName: "plus").font(.system(size: 11, weight: .semibold)).frame(width: 22, height: 22).background(Circle().fill(Theme.well))
                            Text("New transform").font(.system(size: 14, weight: .semibold))
                            Text("Write your own prompt").font(.system(size: 12)).foregroundStyle(.secondary)
                        }
                        .padding(16)
                        .frame(maxWidth: .infinity, minHeight: 130, alignment: .topLeading)
                        .background(RoundedRectangle(cornerRadius: 14).fill(Theme.card))
                        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Theme.hairline, style: StrokeStyle(lineWidth: 1, dash: [4])))
                    }
                    .buttonStyle(.plain)
                }
            }
            .hubPageLayout()
        }
        .sheet(item: $editing) { transform in
            TransformEditor(transform: transform, usedSlots: Set(app.transforms.filter { $0.id != transform.id }.compactMap(\.slot))) { result in
                switch result {
                case .save(let t): try? app.store.save(t); syncShortcut(for: t)
                case .delete(let t): try? app.store.deleteTransform(id: t.id)
                case .cancel: break
                }
                app.reloadPersonalization()
                editing = nil
            }
        }
    }

    private var nextFreeSlot: Int? {
        let used = Set(app.transforms.compactMap(\.slot))
        return (1...9).first { !used.contains($0) }
    }

    /// Keep ⌥N bound for every transform that has a slot.
    private func syncShortcut(for transform: TransformDefinition) {
        guard let slot = transform.slot, let action = HotkeyActionID.transform(slot: slot) else { return }
        if app.settings.shortcuts.combos(for: action).isEmpty {
            app.settings.shortcuts.bindings[action] = [KeyCombo(.option, .key(KeyCode.digits[slot - 1]))]
        }
    }
}

private struct TransformCard: View {
    var transform: TransformDefinition
    var onEdit: () -> Void

    var body: some View {
        Button(action: onEdit) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 4) {
                    if let slot = transform.slot {
                        KeyCap(text: "⌥ Opt"); KeyCap(text: "\(slot)")
                    } else {
                        Text("No shortcut").font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                }
                .frame(height: 22)
                Text(transform.name).font(.system(size: 14, weight: .semibold))
                Text(transform.summary.isEmpty ? transform.instructions : transform.summary)
                    .font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(2)
            }
            .padding(16)
            .frame(maxWidth: .infinity, minHeight: 130, alignment: .topLeading)
            .background(RoundedRectangle(cornerRadius: 14).fill(Theme.card))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Theme.hairline))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

private struct TransformEditor: View {
    enum Result { case save(TransformDefinition), delete(TransformDefinition), cancel }

    @State var transform: TransformDefinition
    var usedSlots: Set<Int>
    var onDone: (Result) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(transform.name.isEmpty ? "New transform" : transform.name).font(Theme.display(24))
            TextField("Name", text: $transform.name).textFieldStyle(.roundedBorder)
                .disabled(transform.kind != .custom)
            TextField("Short description", text: $transform.summary).textFieldStyle(.roundedBorder)
            Picker("Shortcut", selection: $transform.slot) {
                Text("None").tag(Int?.none)
                ForEach(1...9, id: \.self) { slot in
                    Text("⌥ \(slot)" + (usedSlots.contains(slot) ? " (in use)" : "")).tag(Int?.some(slot)).disabled(usedSlots.contains(slot))
                }
            }
            .frame(width: 240)
            if transform.kind == .polish {
                Text("Rules").font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
                ForEach(PolishRule.allCases, id: \.self) { rule in
                    Toggle(rule.displayName, isOn: Binding(
                        get: { transform.rules[rule.rawValue] ?? false },
                        set: { transform.rules[rule.rawValue] = $0 }
                    ))
                }
            } else {
                Text("Instructions").font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
                TextEditor(text: $transform.instructions)
                    .font(.system(size: 13))
                    .frame(height: 150)
                    .padding(4)
                    .background(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.hairline))
            }
            HStack {
                if transform.kind == .custom && !transform.name.isEmpty {
                    Button("Delete", role: .destructive) { onDone(.delete(transform)) }
                }
                Spacer()
                Button("Cancel") { onDone(.cancel) }.keyboardShortcut(.cancelAction)
                Button("Save") { onDone(.save(transform)) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(transform.name.trimmingCharacters(in: .whitespaces).isEmpty
                              || (transform.kind != .polish && transform.instructions.trimmingCharacters(in: .whitespaces).isEmpty))
            }
        }
        .padding(24)
        .frame(width: 520)
    }
}

/// Word-level before/after for the last transform (⌥O).
struct DiffView: View {
    var run: TransformRun

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(run.name).font(Theme.display(26))
            Text(run.instruction).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(2)
            ScrollView {
                diffText
                    .font(.system(size: 14))
                    .lineSpacing(4)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
            }
            .background(RoundedRectangle(cornerRadius: 12).fill(Theme.well))
            HStack {
                Label("Removed", systemImage: "minus").foregroundStyle(.red)
                Label("Added", systemImage: "plus").foregroundStyle(.green)
                Spacer()
                Button("Copy original") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(run.before, forType: .string)
                }
                .buttonStyle(SecondaryButtonStyle())
            }
            .font(.system(size: 12))
        }
        .padding(EdgeInsets(top: 44, leading: 24, bottom: 20, trailing: 24))
        .frame(minWidth: 520, minHeight: 360)
        .background(Theme.card)
    }

    private var diffText: Text {
        var attributed = AttributedString()
        for segment in WordDiff.diff(run.before, run.after) {
            var piece = AttributedString(segment.text)
            switch segment.kind {
            case .same: break
            case .removed:
                piece.strikethroughStyle = .single
                piece.foregroundColor = .red
            case .added:
                piece.foregroundColor = .green
                piece.inlinePresentationIntent = .stronglyEmphasized
            }
            attributed += piece
        }
        return Text(attributed)
    }
}
