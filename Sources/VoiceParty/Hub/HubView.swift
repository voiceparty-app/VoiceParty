import SwiftUI
import VoicePartyCore

enum HubSection: String, CaseIterable, Identifiable {
    case home, notes, insights, dictionary, snippets, style, transforms, enhancements
    var id: String { rawValue }

    var title: String {
        switch self {
        case .home: "Dictation"
        case .notes: "Notes"
        case .insights: "Insights"
        case .dictionary: "Dictionary"
        case .snippets: "Snippets"
        case .style: "Style"
        case .transforms: "Transforms"
        case .enhancements: "Enhancements"
        }
    }

    var symbol: String {
        switch self {
        case .home: "mic"
        case .notes: "note.text"
        case .insights: "chart.bar"
        case .dictionary: "book.closed"
        case .snippets: "scissors"
        case .style: "textformat"
        case .transforms: "wand.and.stars"
        case .enhancements: "sparkles"
        }
    }
}

struct HubView: View {
    @Bindable var app: AppModel
    @Bindable var navigation: HubNavigation

    var body: some View {
        HStack(spacing: 0) {
            sidebar
                .frame(width: 214)
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(RoundedRectangle(cornerRadius: 16).fill(Theme.card))
                .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Theme.hairline))
                .padding(.top, 44)
                .padding([.trailing, .bottom], 12)
        }
        .background(Theme.canvas)
        .ignoresSafeArea()
        .sheet(isPresented: $navigation.showSettings) {
            SettingsView(app: app)
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Image(systemName: "waveform")
                    .font(.system(size: 17, weight: .semibold))
                Text("VoiceParty").font(.system(size: 19, weight: .semibold))
                Text("Local")
                    .font(.system(size: 11, weight: .semibold))
                    .padding(.horizontal, 7).padding(.vertical, 2)
                    .background(Capsule().fill(Theme.accentSoft))
                    .foregroundStyle(Theme.accent)
            }
            .padding(.leading, 10)
            .padding(.top, 52)
            .padding(.bottom, 18)

            ForEach(HubSection.allCases) { section in
                SidebarButton(title: section.title, symbol: section.symbol, selected: navigation.section == section) {
                    navigation.section = section
                }
            }

            Spacer()

            PrivacyBadge()
                .padding(.bottom, 10)

            SidebarButton(title: "Settings", symbol: "gearshape", selected: false) {
                navigation.showSettings = true
            }
            SidebarButton(title: "Shortcuts", symbol: "keyboard", selected: false) {
                navigation.showSettings = true
            }
            .padding(.bottom, 14)
        }
        .padding(.horizontal, 12)
    }

    @ViewBuilder private var content: some View {
        switch navigation.section {
        case .home: HomeView(app: app)
        case .notes: NotesView(app: app, navigation: navigation)
        case .insights: InsightsView(app: app)
        case .dictionary: DictionaryView(app: app, navigation: navigation)
        case .snippets: SnippetsView(app: app, navigation: navigation)
        case .style: StyleView(app: app)
        case .transforms: TransformsView(app: app)
        case .enhancements: EnhancementsView(app: app)
        }
    }
}

private struct SidebarButton: View {
    var title: String
    var symbol: String
    var selected: Bool
    var action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: symbol).frame(width: 18)
                Text(title)
                Spacer()
            }
            .font(.system(size: 14, weight: selected ? .semibold : .regular))
            .padding(.horizontal, 10)
            .frame(height: 34)
            .background(RoundedRectangle(cornerRadius: 9).fill(selected ? Theme.selection : hovering ? Theme.selection.opacity(0.5) : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

private struct PrivacyBadge: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Image(systemName: "lock.shield")
                .font(.system(size: 20))
                .foregroundStyle(Theme.accent)
            Text("Private by design")
                .font(.system(size: 13, weight: .semibold))
            Text("Speech recognition and AI cleanup run on this Mac. VoiceParty doesn't upload what you say.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(Theme.card))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.hairline))
    }
}
