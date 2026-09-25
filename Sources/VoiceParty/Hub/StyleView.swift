import SwiftUI
import VoicePartyCore

struct StyleView: View {
    @Bindable var app: AppModel
    @State private var tab: Tab = .category(.personal)

    enum Tab: Hashable {
        case category(StyleCategory)
        case cleanup
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                PageHeader(title: "Style")
                HStack(spacing: 22) {
                    ForEach(StyleCategory.allCases, id: \.self) { category in
                        tabButton(category.displayName, .category(category))
                    }
                    tabButton("Auto cleanup", .cleanup)
                    Spacer()
                }
                .overlay(alignment: .bottom) { Divider() }

                switch tab {
                case .category(let category): categoryPage(category)
                case .cleanup: cleanupPage
                }
            }
            .hubPageLayout()
        }
    }

    private func tabButton(_ title: String, _ value: Tab) -> some View {
        Button { tab = value } label: {
            Text(title)
                .font(.system(size: 14, weight: tab == value ? .semibold : .regular))
                .foregroundStyle(tab == value ? .primary : .secondary)
                .padding(.bottom, 10)
                .overlay(alignment: .bottom) {
                    if tab == value { Rectangle().fill(Color.primary).frame(height: 2) }
                }
        }
        .buttonStyle(.plain)
    }

    private func categoryPage(_ category: StyleCategory) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("This style applies in \(appsList(category)).")
                .font(.system(size: 13)).foregroundStyle(.secondary)
            HStack(alignment: .top, spacing: 14) {
                ForEach(category.allowedStyles, id: \.self) { style in
                    OptionCard(title: style.displayName, detail: style.summary, example: example(style, category),
                               selected: (app.settings.styles[category] ?? .formal) == style) {
                        app.settings.styles[category] = style
                    }
                }
            }
            Text("Styles are applied on-device. Formal adds capitals and full punctuation; casual keeps capitals but drops the final period; very casual writes like a text message.")
                .font(.system(size: 12)).foregroundStyle(.secondary)
        }
    }

    private var cleanupPage: some View {
        VStack(alignment: .leading, spacing: 18) {
            PromoCard(title: Text("This cleanup level is used everywhere you dictate"),
                      detail: "Choose how much VoiceParty edits what you said. Your original words are always kept in history — use “Undo AI edit” on any dictation to get them back.",
                      examples: [])
            HStack(alignment: .top, spacing: 14) {
                ForEach(CleanupLevel.allCases, id: \.self) { level in
                    OptionCard(title: level.displayName, detail: cleanupDetail(level), example: cleanupExample(level),
                               selected: app.settings.cleanupLevel == level) {
                        app.settings.cleanupLevel = level
                    }
                }
            }
            SettingsGroup {
                SettingsRow(title: "Use Apple Intelligence for cleanup",
                            detail: app.dictation.polisher.unavailableReason
                                ?? "On-device language model: removes fillers, applies self-corrections (“actually…”), formats lists.",
                            showDivider: false) {
                    Toggle("", isOn: $app.settings.useLanguageModel).toggleStyle(.switch).labelsHidden()
                }
            }
        }
    }

    private func cleanupDetail(_ level: CleanupLevel) -> String {
        switch level {
        case .none: "Your words exactly as recognized, slips included"
        case .light: "Cleans up filler words, self-corrections and grammar"
        case .medium: "Also smooths wording and trims repetition"
        }
    }

    private func cleanupExample(_ level: CleanupLevel) -> String {
        switch level {
        case .none: "um so i think we should, uh, meet at 5 actually no 6 if that works"
        case .light: "So I think we should meet at 6, if that works."
        case .medium: "Let's meet at 6 if that works."
        }
    }

    private func example(_ style: WritingStyle, _ category: StyleCategory) -> String {
        switch (style, category) {
        case (.formal, .email): "Hi Joey,\n\nAre we still on for coffee tomorrow? We should leave a bit earlier; there might be traffic.\n\nBest,\nSam"
        case (.formal, _): "Can we push our call to 3? I'm running a little behind."
        case (.casual, _): "Can we push our call to 3? I'm running a little behind"
        case (.veryCasual, _): "can we push our call to 3? i'm running a little behind"
        case (.excited, _): "Can we push our call to 3? I'm running a little behind!"
        }
    }

    private func appsList(_ category: StyleCategory) -> String {
        switch category {
        case .personal: "Messages, WhatsApp, Telegram, Signal and similar"
        case .work: "Slack, Teams, Discord and similar"
        case .email: "Mail, Outlook, Superhuman, Gmail and similar"
        case .other: "all other apps"
        }
    }
}

struct OptionCard: View {
    var title: String
    var detail: String
    var example: String
    var selected: Bool
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 8) {
                Text(title).font(Theme.display(24))
                Text(detail).font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 20)
                Text(example)
                    .font(.system(size: 12).italic())
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 10).fill(Theme.sparkle.opacity(0.08)))
            }
            .padding(16)
            .frame(maxWidth: .infinity, minHeight: 250, alignment: .topLeading)
            .background(RoundedRectangle(cornerRadius: 14).fill(Theme.card))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(selected ? Color.primary : Theme.hairline, lineWidth: selected ? 1.5 : 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
