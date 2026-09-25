import AppKit
import Foundation
import VoicePartyCore

enum Paths {
    static var appSupport: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appending(path: "VoiceParty", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static var settings: URL { appSupport.appending(path: "settings.json") }
    static var database: URL { appSupport.appending(path: "voiceparty.sqlite") }

    static var audio: URL {
        let dir = appSupport.appending(path: "audio", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        excludeFromBackup(dir)
        return dir
    }

    /// Recordings stay on this Mac: not in Time Machine backups (which outlive the retention settings).
    static func excludeFromBackup(_ url: URL) {
        var url = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? url.setResourceValues(values)
    }
}

enum SettingsFile {
    static func load() -> AppSettings {
        guard let data = try? Data(contentsOf: Paths.settings),
              let settings = try? JSONDecoder().decode(AppSettings.self, from: data) else { return firstLaunchDefaults() }
        return settings
    }

    /// Another dictation app may already use fn (Wispr Flow does); then start on Right Option so both work.
    static func firstLaunchDefaults() -> AppSettings {
        var settings = AppSettings()
        let wisprRunning = NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier == "com.electron.wispr-flow" }
        if wisprRunning { settings.shortcuts = .defaults(primary: .rightOption) }
        return settings
    }

    static func save(_ settings: AppSettings) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(settings) else { return }
        try? data.write(to: Paths.settings, options: .atomic)
    }
}

/// Developer test hooks (voiceparty://debug/…, a local update feed). Compiled only into development builds
/// (`scripts/build-app.sh`; releases leave them out), and even then only on when this app's own saved
/// preferences say so — not a launch argument or another app's defaults.
enum DebugURLs {
    static var enabled: Bool {
        #if VOICEPARTY_DEBUG_URLS
        UserDefaults.standard.persistentDomain(forName: Bundle.main.bundleIdentifier ?? "")?["DebugURLs"] as? Bool == true
        #else
        false
        #endif
    }
}
