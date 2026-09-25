import AppKit
import SwiftUI
import VoicePartyCore

/// Notetaker: meetings recorded and summarized on this Mac.
struct NotesView: View {
    @Bindable var app: AppModel
    @Bindable var navigation: HubNavigation

    private var selected: MeetingNote? {
        navigation.selectedNote.flatMap { id in app.notes.first { $0.id == id } }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                if let note = selected {
                    NoteDetail(app: app, note: note) { navigation.selectedNote = nil }
                } else {
                    PageHeader(title: "Notes", subtitle: "Meetings transcribed and summarized on this Mac. Nothing joins the call.") {
                        NotetakerButton(app: app)
                    }
                    if app.notes.isEmpty {
                        PromoCard(
                            title: Text("Stay in the conversation. \(Text("VoiceParty").italic()) takes the notes."),
                            detail: "Start the Notetaker when a call begins. It transcribes you (microphone) and everyone else (your Mac's audio) as the meeting goes, then writes a summary, decisions and action items when you stop — all on this Mac.",
                            examples: ["Summary", "Decisions", "Action items", "Full transcript"]
                        )
                    } else {
                        VStack(spacing: 0) {
                            ForEach(app.notes) { note in
                                NoteRow(note: note, isLast: note.id == app.notes.last?.id) { navigation.selectedNote = note.id }
                            }
                        }
                        .background(RoundedRectangle(cornerRadius: 12).fill(Theme.card))
                        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.hairline))
                    }
                }
            }
            .hubPageLayout()
        }
    }
}

/// Start / Stop with the running time.
struct NotetakerButton: View {
    @Bindable var app: AppModel

    var body: some View {
        switch app.notetaker.state {
        case .idle:
            Button { app.notetaker.start() } label: { Label("Start Notetaker", systemImage: "record.circle") }
                .buttonStyle(PrimaryButtonStyle())
        case .recording(let since):
            Button { Task { await app.notetaker.stop() } } label: {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Label("Stop · \(Self.elapsed(context.date.timeIntervalSince(since)))", systemImage: "stop.fill")
                        .monospacedDigit()
                }
            }
            .buttonStyle(PrimaryButtonStyle())
        case .wrappingUp:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Writing notes…").font(.system(size: 13)).foregroundStyle(.secondary)
            }
        }
    }

    static func elapsed(_ seconds: TimeInterval) -> String {
        let s = max(0, Int(seconds))
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60) : String(format: "%d:%02d", s / 60, s % 60)
    }
}

private struct NoteRow: View {
    var note: MeetingNote
    var isLast: Bool
    var onOpen: () -> Void
    @State private var hovering = false

    var body: some View {
        VStack(spacing: 0) {
            Button(action: onOpen) {
                HStack(alignment: .top, spacing: 14) {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 8) {
                            Text(note.title).font(.system(size: 14, weight: .semibold))
                            StatusBadge(status: note.status)
                        }
                        Text(NoteDetail.meta(note)).font(.system(size: 12)).foregroundStyle(.secondary)
                        if let first = note.summary?.split(separator: "\n").first {
                            Text(first.trimmingCharacters(in: CharacterSet(charactersIn: "- ")))
                                .font(.system(size: 13)).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                    Spacer()
                    Image(systemName: "chevron.right").font(.system(size: 12)).foregroundStyle(.tertiary)
                }
                .padding(.horizontal, 18).padding(.vertical, 14)
                .background(Theme.selection.opacity(hovering ? 0.45 : 0))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { hovering = $0 }
            if !isLast { Divider().opacity(0.6) }
        }
    }
}

private struct StatusBadge: View {
    var status: MeetingNote.Status

    var body: some View {
        switch status {
        case .recording: badge("Recording", Color(red: 0.9, green: 0.3, blue: 0.28))
        case .transcribing, .summarizing: badge("Writing notes…", Theme.accent)
        case .failed: badge("Failed", .red)
        case .ready: EmptyView()
        }
    }

    private func badge(_ text: String, _ color: Color) -> some View {
        Text(text).font(.system(size: 11, weight: .semibold)).foregroundStyle(color)
            .padding(.horizontal, 7).padding(.vertical, 2)
            .background(Capsule().fill(color.opacity(0.12)))
    }
}

private struct NoteDetail: View {
    @Bindable var app: AppModel
    var note: MeetingNote
    var onBack: () -> Void

    static func meta(_ note: MeetingNote) -> String {
        let date = note.startedAt.formatted(date: .abbreviated, time: .shortened)
        let minutes = Int((note.duration / 60).rounded())
        let length = note.status == .recording ? "recording" : minutes < 1 ? "under a minute" : "\(minutes) min"
        let with = note.attendees.isEmpty ? nil : "with " + note.attendees.prefix(4).joined(separator: ", ") + (note.attendees.count > 4 ? " +\(note.attendees.count - 4)" : "")
        return ([date, length] + [note.appName, with].compactMap { $0 }).joined(separator: " · ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Button(action: onBack) { Label("All notes", systemImage: "chevron.left") }
                .buttonStyle(.plain).foregroundStyle(Theme.accent).font(.system(size: 13))

            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(note.title).font(Theme.display(30))
                    Text(Self.meta(note)).font(.system(size: 13)).foregroundStyle(.secondary)
                }
                Spacer()
                if app.notetaker.currentNoteID == note.id {
                    NotetakerButton(app: app)
                } else {
                    Button("Copy as Markdown") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(note.markdown(), forType: .string)
                        app.dictationBar.toast("Notes copied", duration: 1.8)
                    }
                    .buttonStyle(SecondaryButtonStyle())
                    Button("Delete", role: .destructive) { confirmDelete() }.buttonStyle(SecondaryButtonStyle())
                }
            }

            if let summary = note.summary, !summary.isEmpty {
                section("Summary") { bullets(summary.components(separatedBy: "\n").map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "- ")) }) }
            } else if note.status == .ready && !note.segments.isEmpty {
                Card {
                    Text("No summary: install Smart cleanup under Enhancements (or turn on Apple Intelligence) to get notes written for you.")
                        .font(.system(size: 13)).foregroundStyle(.secondary)
                }
            }
            if let mine = note.userNotes?.trimmingCharacters(in: .whitespacesAndNewlines), !mine.isEmpty {
                section("Your notes") { Text(mine).font(.system(size: 14)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
            }
            if !note.decisions.isEmpty { section("Decisions") { bullets(note.decisions) } }
            if !note.actionItems.isEmpty {
                section("Action items") {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(note.actionItems, id: \.self) { item in
                            Label { Text(item).font(.system(size: 14)) } icon: { Image(systemName: "square").foregroundStyle(.secondary) }
                        }
                    }
                }
            }
            section("Transcript") {
                if note.segments.isEmpty {
                    Text(note.status == .recording ? "The transcript appears when you stop." : "Nothing was transcribed.")
                        .font(.system(size: 13)).foregroundStyle(.secondary)
                } else {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(Array(note.segments.enumerated()), id: \.offset) { _, segment in
                            HStack(alignment: .firstTextBaseline, spacing: 12) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(segment.speaker.label).font(.system(size: 12, weight: .semibold))
                                        .foregroundStyle(segment.speaker == .me ? Theme.accent : Color.primary)
                                    Text(NotetakerButton.elapsed(segment.start)).font(.system(size: 11).monospacedDigit()).foregroundStyle(.secondary)
                                }
                                .frame(width: 58, alignment: .leading)
                                Text(segment.text).font(.system(size: 14)).textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                    }
                }
            }
        }
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title.uppercased()).font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary).tracking(0.6)
            Card { content() }
        }
    }

    private func bullets(_ items: [String]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(items.filter { !$0.isEmpty }, id: \.self) { item in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("•").foregroundStyle(.secondary)
                    Text(item).font(.system(size: 14)).textSelection(.enabled)
                }
            }
        }
    }

    private func confirmDelete() {
        let alert = NSAlert()
        alert.messageText = "Delete “\(note.title)”?"
        alert.informativeText = "The notes, transcript and recording are removed from this Mac."
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        onBack()
        app.notetaker.delete(note.id)
    }
}
