import Foundation

/// What a dictation may leave behind, from the field it went into and the user's retention settings.
public struct DictationPrivacy: Equatable, Sendable {
    public var saveHistory: Bool
    public var saveAudio: Bool
    public var learnFromEdits: Bool
    public var useLanguageModel: Bool
    /// Mark the pasted text as concealed so clipboard managers don't record it.
    public var concealOnClipboard: Bool
    /// Text put on the clipboard is marked so clipboard managers don't record it.
    public var keepOffClipboardHistory: Bool

    /// A password field leaves no trace: no history, no recording, no learning, no model, concealed paste.
    public static func decide(isSecureField: Bool, retention: HistoryRetention, keepAudioDays: Int) -> DictationPrivacy {
        if isSecureField {
            return DictationPrivacy(saveHistory: false, saveAudio: false, learnFromEdits: false, useLanguageModel: false,
                                    concealOnClipboard: true, keepOffClipboardHistory: true)
        }
        let store = retention != .neverStore
        return DictationPrivacy(saveHistory: store, saveAudio: store && keepAudioDays > 0, learnFromEdits: true,
                                useLanguageModel: true, concealOnClipboard: false, keepOffClipboardHistory: keepsOffClipboardHistory(retention: retention))
    }

    /// "Never store" means no copies anywhere, including a clipboard manager's history.
    public static func keepsOffClipboardHistory(retention: HistoryRetention) -> Bool { retention == .neverStore }
}

/// Which meeting recordings and notes the retention settings remove.
public enum NoteRetention {
    public struct Item: Equatable, Sendable {
        public var id: UUID
        public var startedAt: Date
        public var hasAudio: Bool
        public init(id: UUID, startedAt: Date, hasAudio: Bool) {
            self.id = id
            self.startedAt = startedAt
            self.hasAudio = hasAudio
        }
    }

    /// Recordings follow "Keep audio recordings" (0 days: removed once transcribed); the notes themselves are
    /// documents you keep, except under "Delete after 24 hours".
    public static func plan(_ notes: [Item], retention: HistoryRetention, keepAudioDays: Int, now: Date = Date())
        -> (deleteNotes: [UUID], deleteAudio: [UUID]) {
        let audioCutoff = now.addingTimeInterval(-Double(keepAudioDays) * 86_400)
        let deleteNotes = retention == .deleteAfter24Hours ? notes.filter { $0.startedAt < now.addingTimeInterval(-86_400) }.map(\.id) : []
        let deleteAudio = notes.filter { $0.hasAudio && !deleteNotes.contains($0.id) && (keepAudioDays == 0 || $0.startedAt < audioCutoff) }.map(\.id)
        return (deleteNotes, deleteAudio)
    }
}

/// Apps whose screens are never read, and on-screen text that looks like a secret.
public enum SensitiveApps {
    static let bundlePrefixes = [
        "com.1password", "com.agilebits", "com.bitwarden", "com.apple.Passwords", "com.apple.keychainaccess",
        "com.dashlane", "com.lastpass", "in.sinew.Enpass", "com.keepassium", "org.keepassxc", "com.nordpass",
        "com.apple.systempreferences", "com.apple.SecurityAgent",
    ]

    public static func isExcluded(_ bundleID: String?) -> Bool {
        guard let bundleID else { return false }
        return bundlePrefixes.contains { bundleID == $0 || bundleID.hasPrefix($0 + ".") || bundleID.hasPrefix($0) }
    }

    /// Screen reading (opt-in OCR) never looks at a password manager or while you're typing into a password field.
    public static func mayReadScreen(bundleID: String?, isSecureField: Bool) -> Bool {
        !isSecureField && !isExcluded(bundleID)
    }

    /// Screen text is untrusted: keep names and jargon, drop anything with digits (passwords, keys, IDs).
    public static func screenSafeTerms(_ terms: [String]) -> [String] {
        terms.filter { !$0.contains(where: \.isNumber) }
    }
}
