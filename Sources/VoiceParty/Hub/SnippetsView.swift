import SwiftUI
import UniformTypeIdentifiers
import VoicePartyCore

struct SnippetsView: View {
    @Bindable var app: AppModel
    @Bindable var navigation: HubNavigation
    @State private var editing: Snippet?
    @State private var search = ""

    private var snippets: [Snippet] {
        search.isEmpty ? app.snippets : app.snippets.filter {
            $0.trigger.localizedCaseInsensitiveContains(search) || $0.expansion.localizedCaseInsensitiveContains(search)
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                PageHeader(title: "Snippets") {
                    Button("Import JSON…") { importJSON() }.buttonStyle(SecondaryButtonStyle())
                    Button("Add new") { editing = Snippet(trigger: "", expansion: "") }.buttonStyle(PrimaryButtonStyle())
                }
                PromoCard(
                    title: Text("The stuff \(Text("you").italic()) shouldn't have to re-type."),
                    detail: "Say a short phrase and VoiceParty types the full text for you: your email address, a signature, a prompt you reuse.",
                    examples: ["“my linkedin” → linkedin.com/in/…", "“intro email” → Hey, would love to…"]
                )
                HStack { Spacer(); SearchField(text: $search) }
                if snippets.isEmpty {
                    Card { Text(app.snippets.isEmpty ? "No snippets yet." : "No matches.").foregroundStyle(.secondary) }
                } else {
                    VStack(spacing: 0) {
                        ForEach(snippets) { snippet in
                            SnippetRow(snippet: snippet, isLast: snippet.id == snippets.last?.id,
                                       onEdit: { editing = snippet },
                                       onDelete: { try? app.store.deleteSnippet(id: snippet.id); app.reloadPersonalization() })
                        }
                    }
                    .background(RoundedRectangle(cornerRadius: 12).fill(Theme.card))
                    .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.hairline))
                }
            }
            .hubPageLayout()
        }
        .sheet(item: $editing) { snippet in
            SnippetEditor(snippet: snippet) { saved in
                if let saved { try? app.store.save(saved); app.reloadPersonalization() }
                editing = nil
            }
        }
        .onAppear(perform: consumeAddRequest)
        .onChange(of: navigation.addNewRequested) { consumeAddRequest() }
    }

    private func consumeAddRequest() {
        guard navigation.addNewRequested else { return }
        navigation.addNewRequested = false
        editing = Snippet(trigger: "", expansion: "")
    }

    private func importJSON() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url, let data = try? Data(contentsOf: url) else { return }
        do {
            let summary = try ProfileMerger.merge(dictionary: [], snippets: BulkImport.snippets(json: data), into: app.store)
            app.reloadPersonalization()
            app.dictationBar.toast("Imported: \(summary.description)", duration: 4)
        } catch {
            app.dictationBar.toast("Couldn't read that file: \(error.localizedDescription)", style: .error)
        }
    }
}

private struct SnippetRow: View {
    var snippet: Snippet
    var isLast: Bool
    var onEdit: () -> Void
    var onDelete: () -> Void
    @State private var hovering = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Text(snippet.trigger).font(.system(size: 14, weight: .medium))
                Image(systemName: "arrow.right").font(.system(size: 11)).foregroundStyle(.secondary)
                Text(snippet.expansion.replacingOccurrences(of: "\n", with: " ")).font(.system(size: 14)).foregroundStyle(.secondary).lineLimit(1)
                Spacer()
                Button(action: onEdit) { Image(systemName: "pencil") }.buttonStyle(.plain).foregroundStyle(.secondary).opacity(hovering ? 1 : 0)
                Button(action: onDelete) { Image(systemName: "trash") }.buttonStyle(.plain).foregroundStyle(.secondary).opacity(hovering ? 1 : 0)
            }
            .padding(.horizontal, 16)
            .frame(height: 46)
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
            .onTapGesture(count: 2, perform: onEdit)
            if !isLast { Divider().opacity(0.6) }
        }
    }
}

private struct SnippetEditor: View {
    @State var snippet: Snippet
    var onDone: (Snippet?) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(snippet.trigger.isEmpty ? "New snippet" : "Edit snippet").font(Theme.display(24))
            Text("When I say").font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
            TextField("e.g. my calendar link", text: $snippet.trigger).textFieldStyle(.roundedBorder)
            Text("Insert").font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
            TextEditor(text: $snippet.expansion)
                .font(.system(size: 13))
                .frame(height: 160)
                .padding(4)
                .background(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.hairline))
            HStack {
                Text("\(snippet.expansion.count)/\(Snippet.maxExpansionLength)").font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { onDone(nil) }.keyboardShortcut(.cancelAction)
                Button("Save") { onDone(snippet) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(snippet.trigger.trimmingCharacters(in: .whitespaces).isEmpty || snippet.expansion.isEmpty
                              || snippet.trigger.count > Snippet.maxTriggerLength || snippet.expansion.count > Snippet.maxExpansionLength)
            }
        }
        .padding(24)
        .frame(width: 520)
    }
}
