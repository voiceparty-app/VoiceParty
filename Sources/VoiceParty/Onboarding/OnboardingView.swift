import SwiftUI
import VoicePartyCore

struct OnboardingView: View {
    @Bindable var app: AppModel
    var onFinish: () -> Void
    @State private var imported: String?
    @State private var testText = ""

    private var hasWispr: Bool { FileManager.default.fileExists(atPath: WisprFlowImporter.defaultDatabaseURL.path) }
    private var usesFn: Bool { app.settings.shortcuts.combos(for: .pushToTalk).contains { $0.tokens.contains(.fn) } }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 8) {
                    Image(systemName: "waveform").font(.system(size: 30, weight: .semibold))
                    Text("Welcome to VoiceParty").font(Theme.display(32))
                    Text("Dictate anywhere on your Mac. Speech recognition and cleanup run on this Mac; VoiceParty doesn't send what you say anywhere.")
                        .font(.system(size: 14)).foregroundStyle(.secondary)
                }
                .padding(.bottom, 6)

                step(1, "Microphone", done: app.permissions.microphone == .authorized,
                     detail: "So VoiceParty can hear you while you hold the hotkey.") {
                    Button("Allow") {
                        Task {
                            if await Permissions.requestMicrophone() == false { Permissions.openMicrophoneSettings() }
                            app.permissions = .current()
                        }
                    }
                }

                step(2, "Accessibility", done: app.permissions.accessibility,
                     detail: "Lets the hotkey work in every app and pastes text where your cursor is. Turn VoiceParty on in the list that opens.") {
                    Button("Open Settings") {
                        Permissions.promptAccessibility()
                        Permissions.openAccessibilitySettings()
                    }
                }

                step(3, "Speech model", done: app.engineStatus == nil && app.engineError == nil,
                     detail: app.engineStatus ?? app.engineError ?? "Apple's on-device model is installed.") {
                    if app.engineError != nil { Button("Retry") { app.prepareEngine() } }
                }

                step(4, "Apple Intelligence (optional)", done: app.dictation.apple.isAvailable,
                     detail: app.dictation.apple.unavailableReason ?? "On-device cleanup is ready: fillers, self-corrections and lists.") {
                    if !app.dictation.apple.isAvailable { Button("Open Settings") { Permissions.openAppleIntelligenceSettings() } }
                }

                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("5").font(.system(size: 12, weight: .bold)).frame(width: 24, height: 24).background(Circle().fill(Theme.well))
                        Text("Your dictation key").font(.system(size: 15, weight: .semibold))
                    }
                    Picker("", selection: Binding(
                        get: { app.settings.shortcuts.combos(for: .pushToTalk).first?.tokens.first ?? .fn },
                        set: { app.settings.shortcuts = .defaults(primary: $0) }
                    )) {
                        Text("fn / 🌐").tag(KeyToken.fn)
                        Text("Right ⌥ Option").tag(KeyToken.rightOption)
                        Text("Right ⌃ Control").tag(KeyToken.rightControl)
                    }
                    .pickerStyle(.radioGroup)
                    .labelsHidden()
                    if usesFn {
                        Text("For fn to work cleanly, set System Settings → Keyboard → “Press 🌐 key to” → Do Nothing, and change the macOS Dictation shortcut away from fn. If Wispr Flow is running, quit it — both apps can't own fn.")
                            .font(.system(size: 12)).foregroundStyle(.secondary)
                        Button("Open Keyboard Settings") { Permissions.openKeyboardSettings() }.buttonStyle(SecondaryButtonStyle())
                    }
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 12).fill(Theme.well))

                if hasWispr {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Bring your Wispr Flow dictionary").font(.system(size: 15, weight: .semibold))
                        Text("Copies your words, replacements and snippets from Wispr Flow on this Mac. Wispr Flow's data isn't changed.")
                            .font(.system(size: 12)).foregroundStyle(.secondary)
                        HStack {
                            Button("Import from Wispr Flow") { importWispr() }.buttonStyle(SecondaryButtonStyle())
                            if let imported { Text(imported).font(.system(size: 12)).foregroundStyle(Theme.accent) }
                        }
                    }
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 12).fill(Theme.well))
                }

                VStack(alignment: .leading, spacing: 10) {
                    Text("Try it").font(.system(size: 15, weight: .semibold))
                    Text("Click in the box, hold \(app.pushToTalkName), say something, and let go.").font(.system(size: 12)).foregroundStyle(.secondary)
                    TextEditor(text: $testText)
                        .font(.system(size: 14))
                        .frame(height: 70)
                        .padding(6)
                        .background(RoundedRectangle(cornerRadius: 8).fill(Theme.card))
                        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.hairline))
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 12).fill(Theme.well))

                HStack {
                    Spacer()
                    Button(app.permissions.allGranted ? "Get started" : "Continue anyway") {
                        app.settings.hasCompletedOnboarding = true
                        onFinish()
                    }
                    .buttonStyle(PrimaryButtonStyle())
                }
            }
            .padding(EdgeInsets(top: 48, leading: 36, bottom: 30, trailing: 36))
        }
        .background(Theme.card)
    }

    private func step<Action: View>(_ number: Int, _ title: String, done: Bool, detail: String, @ViewBuilder action: () -> Action) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Group {
                if done {
                    Image(systemName: "checkmark").font(.system(size: 11, weight: .bold)).foregroundStyle(.white)
                        .frame(width: 24, height: 24).background(Circle().fill(Theme.accent))
                } else {
                    Text("\(number)").font(.system(size: 12, weight: .bold)).frame(width: 24, height: 24).background(Circle().fill(Theme.well))
                }
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 15, weight: .semibold))
                Text(detail).font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            if !done { action().buttonStyle(PrimaryButtonStyle()) }
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 12).fill(Theme.well))
    }

    private func importWispr() {
        do {
            let data = try WisprFlowImporter.read()
            let summary = try ProfileMerger.merge(dictionary: data.dictionary, snippets: data.snippets, into: app.store)
            app.reloadPersonalization()
            imported = summary.description
        } catch {
            imported = error.localizedDescription
        }
    }
}
