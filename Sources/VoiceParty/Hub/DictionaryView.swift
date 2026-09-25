import SwiftUI
import UniformTypeIdentifiers
import VoicePartyCore

struct DictionaryView: View {
    @Bindable var app: AppModel
    @Bindable var navigation: HubNavigation
    @State private var filter: Filter = .all
    @State private var search = ""
    @State private var editing: DictionaryEntry?
    @State private var sort: Sort = .newest
    /// Bulk editing: rows show checkboxes; Delete removes every checked entry (with Undo).
    @State private var selecting = false
    @State private var selected: Set<UUID> = []

    enum Filter: String, CaseIterable { case all = "All", manual = "Added by you", learned = "Auto-learned", replacements = "Replacements" }
    enum Sort: String, CaseIterable { case newest = "Newest", oldest = "Oldest", az = "A–Z", starred = "Starred", mostUsed = "Most used" }

    private var entries: [DictionaryEntry] {
        var list = app.dictionary.filter { entry in
            switch filter {
            case .all: true
            case .manual: entry.source != .learned
            case .learned: entry.source == .learned
            case .replacements: entry.replacement != nil
            }
        }
        if !search.isEmpty {
            list = list.filter { $0.phrase.localizedCaseInsensitiveContains(search) || ($0.replacement ?? "").localizedCaseInsensitiveContains(search) }
        }
        switch sort {
        case .newest: list.sort { $0.createdAt > $1.createdAt }
        case .oldest: list.sort { $0.createdAt < $1.createdAt }
        case .az: list.sort { $0.phrase.localizedCaseInsensitiveCompare($1.phrase) == .orderedAscending }
        case .starred: list.sort { ($0.isStarred ? 0 : 1, $0.phrase.lowercased()) < ($1.isStarred ? 0 : 1, $1.phrase.lowercased()) }
        case .mostUsed: list.sort { $0.useCount > $1.useCount }
        }
        return list
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                PageHeader(title: "Dictionary") {
                    Menu("Import") {
                        Button("From Wispr Flow") { importFromWispr() }
                        Button("From CSV file…") { importCSV() }
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    Button("Add new") { editing = DictionaryEntry(phrase: "") }.buttonStyle(PrimaryButtonStyle())
                }

                PromoCard(
                    title: Text("VoiceParty spells the way \(Text("you").italic()) do."),
                    detail: "Add names, company jargon and uncommon words so they're recognized and spelled right. Words you correct after dictating are learned automatically (✨). Replacements like “btw → by the way” are applied to every dictation.",
                    examples: ["Priya", "Kubernetes", "Tamaro", "btw → by the way"]
                )

                HStack {
                    Picker("", selection: $filter) {
                        ForEach(Filter.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                    Spacer(minLength: 12)
                    SearchField(text: $search)
                    Picker("", selection: $sort) {
                        ForEach(Sort.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                    .labelsHidden()
                    .fixedSize()
                    Button(selecting ? "Done" : "Select") {
                        selecting.toggle()
                        selected.removeAll()
                    }
                    .buttonStyle(SecondaryButtonStyle())
                    .fixedSize()
                    .disabled(app.dictionary.isEmpty)
                }

                if selecting {
                    selectionBar
                }

                if entries.isEmpty {
                    Card { Text(app.dictionary.isEmpty ? "Your dictionary is empty. Add a word, or import from Wispr Flow." : "No matches.").foregroundStyle(.secondary) }
                } else {
                    VStack(spacing: 0) {
                        ForEach(entries) { entry in
                            DictionaryRow(entry: entry, isLast: entry.id == entries.last?.id,
                                          selection: selecting ? selected.contains(entry.id) : nil,
                                          onToggle: { toggle(entry.id) },
                                          onEdit: { editing = entry },
                                          onStar: { var e = entry; e.isStarred.toggle(); save(e) },
                                          onDelete: { try? app.store.deleteDictionaryEntry(id: entry.id); app.reloadPersonalization() })
                        }
                    }
                    .background(RoundedRectangle(cornerRadius: 12).fill(Theme.card))
                    .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.hairline))
                    Text("\(app.dictionary.count) entries · the \(min(100, app.dictionary.filter { $0.replacement == nil }.count)) most important words are sent to the speech engine as hints")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            .hubPageLayout()
        }
        .sheet(item: $editing) { entry in
            DictionaryEditor(entry: entry) { saved in
                if let saved { save(saved) }
                editing = nil
            }
        }
        .onAppear {
            consumeAddRequest()
            if navigation.debugSelectDictionaryEntries > 0 {
                selecting = true
                selected = Set(entries.prefix(navigation.debugSelectDictionaryEntries).map(\.id))
            }
        }
        .onChange(of: navigation.addNewRequested) { consumeAddRequest() }
    }

    private var selectionBar: some View {
        let visible = entries.map(\.id)
        let allVisibleSelected = !visible.isEmpty && visible.allSatisfy(selected.contains)
        return HStack(spacing: 14) {
            Text(selected.isEmpty ? "Select entries to delete" : "\(selected.count) selected")
                .font(.system(size: 13, weight: .medium))
            Button(allVisibleSelected ? "Deselect all" : "Select all (\(visible.count))") {
                if allVisibleSelected { selected.subtract(visible) } else { selected.formUnion(visible) }
            }
            .buttonStyle(.plain).foregroundStyle(Theme.accent).font(.system(size: 13))
            Spacer()
            Button("Delete \(selected.count == 1 ? "1 entry" : "\(selected.count) entries")", role: .destructive) { deleteSelected() }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(selected.isEmpty)
        }
        .padding(.horizontal, 16).frame(height: 48)
        .background(RoundedRectangle(cornerRadius: 12).fill(Theme.well))
    }

    private func toggle(_ id: UUID) {
        if selected.contains(id) { selected.remove(id) } else { selected.insert(id) }
    }

    private func deleteSelected() {
        guard let removed = try? app.store.deleteDictionaryEntries(ids: Array(selected)), !removed.isEmpty else { return }
        selected.removeAll()
        selecting = false
        app.reloadPersonalization()
        app.dictationBar.toast("Deleted \(removed.count == 1 ? "1 entry" : "\(removed.count) entries")", action: "Undo", duration: 6) { [app] in
            try? app.store.restoreDictionaryEntries(removed)
            app.reloadPersonalization()
        }
    }

    private func consumeAddRequest() {
        guard navigation.addNewRequested else { return }
        navigation.addNewRequested = false
        editing = DictionaryEntry(phrase: "")
    }

    private func save(_ entry: DictionaryEntry) {
        try? app.store.save(entry)
        app.reloadPersonalization()
    }

    private func importFromWispr() { app.importFromWisprFlow() }

    private func importCSV() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.commaSeparatedText, .plainText]
        guard panel.runModal() == .OK, let url = panel.url, let text = try? String(contentsOf: url, encoding: .utf8) else { return }
        let summary = try? ProfileMerger.merge(dictionary: BulkImport.dictionary(csv: text), snippets: [], into: app.store)
        app.reloadPersonalization()
        app.dictationBar.toast("Imported: \(summary?.description ?? "nothing")", duration: 4)
    }
}

struct PromoCard: View {
    var title: Text
    var detail: String
    var examples: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            title.font(Theme.display(28)).foregroundStyle(.white)
            Text(detail).font(.system(size: 13)).foregroundStyle(.white.opacity(0.8)).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                ForEach(examples, id: \.self) { ex in
                    Text(ex).font(.system(size: 12, weight: .medium)).foregroundStyle(.white)
                        .padding(.horizontal, 10).frame(height: 26)
                        .background(RoundedRectangle(cornerRadius: 7).fill(.white.opacity(0.14)))
                }
            }
        }
        .padding(26)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            LinearGradient(colors: [Color(red: 0.36, green: 0.24, blue: 0.16), Color(red: 0.62, green: 0.45, blue: 0.3)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
        )
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }
}

private struct DictionaryRow: View {
    var entry: DictionaryEntry
    var isLast: Bool
    /// nil outside selection mode; otherwise whether this row is checked.
    var selection: Bool?
    var onToggle: () -> Void
    var onEdit: () -> Void
    var onStar: () -> Void
    var onDelete: () -> Void
    @State private var hovering = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                if let selection {
                    Image(systemName: selection ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 16))
                        .foregroundStyle(selection ? Theme.accent : Color.secondary)
                }
                if let replacement = entry.replacement {
                    Text(entry.phrase).font(.system(size: 14))
                    Image(systemName: "arrow.right").font(.system(size: 11)).foregroundStyle(.secondary)
                    Text(replacement).font(.system(size: 14))
                } else {
                    Text(entry.phrase).font(.system(size: 14))
                }
                if entry.source == .learned {
                    Image(systemName: "sparkle").font(.system(size: 11)).foregroundStyle(Theme.highlight).help("Learned from your corrections")
                }
                Spacer()
                if entry.useCount > 0 {
                    Text("used \(entry.useCount)×").font(.system(size: 11)).foregroundStyle(.secondary).opacity(hovering ? 1 : 0)
                }
                if selection == nil {
                    Button(action: onStar) {
                        Image(systemName: entry.isStarred ? "star.fill" : "star").foregroundStyle(entry.isStarred ? Theme.highlight : .secondary)
                    }
                    .buttonStyle(.plain)
                    .opacity(hovering || entry.isStarred ? 1 : 0)
                    .help("Starred words are always sent to the speech engine")
                    Button(action: onEdit) { Image(systemName: "pencil") }.buttonStyle(.plain).foregroundStyle(.secondary).opacity(hovering ? 1 : 0)
                    Button(action: onDelete) { Image(systemName: "trash") }.buttonStyle(.plain).foregroundStyle(.secondary).opacity(hovering ? 1 : 0)
                }
            }
            .padding(.horizontal, 16)
            .frame(height: 46)
            .background(Theme.selection.opacity(selection == true ? 0.5 : 0))
            .contentShape(Rectangle())
            .onTapGesture { if selection != nil { onToggle() } }
            .onHover { hovering = $0 }
            if !isLast { Divider().opacity(0.6) }
        }
    }
}

private struct DictionaryEditor: View {
    @State var entry: DictionaryEntry
    @State private var isReplacement: Bool
    @State private var replacement: String
    var onDone: (DictionaryEntry?) -> Void

    init(entry: DictionaryEntry, onDone: @escaping (DictionaryEntry?) -> Void) {
        _entry = State(initialValue: entry)
        _isReplacement = State(initialValue: entry.replacement != nil)
        _replacement = State(initialValue: entry.replacement ?? "")
        self.onDone = onDone
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(entry.phrase.isEmpty ? "Add to dictionary" : "Edit entry").font(Theme.display(24))
            Toggle("Replace with different text", isOn: $isReplacement)
            TextField(isReplacement ? "When I say… (e.g. btw)" : "Word or phrase (e.g. Tamaro)", text: $entry.phrase)
                .textFieldStyle(.roundedBorder)
            if isReplacement {
                TextField("…write this instead (e.g. by the way)", text: $replacement).textFieldStyle(.roundedBorder)
            }
            Toggle("Star (always hint this word to the speech engine)", isOn: $entry.isStarred)
            HStack {
                Spacer()
                Button("Cancel") { onDone(nil) }.keyboardShortcut(.cancelAction)
                Button("Save") {
                    var saved = entry
                    saved.phrase = entry.phrase.trimmingCharacters(in: .whitespacesAndNewlines)
                    saved.replacement = isReplacement && !replacement.isEmpty ? replacement : nil
                    onDone(saved)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(entry.phrase.trimmingCharacters(in: .whitespaces).isEmpty || entry.phrase.count > 60)
            }
        }
        .padding(24)
        .frame(width: 440)
    }
}
