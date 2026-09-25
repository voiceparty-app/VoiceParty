import Foundation

/// All user preferences. Stored as `settings.json`; unknown or missing keys fall back to defaults
/// so older/newer files always load.
public struct AppSettings: Codable, Equatable, Sendable {
    public static let schemaVersion = 1

    public var shortcuts: ShortcutSettings = .defaults()
    public var holdThreshold: Double = 0.35
    public var doubleTapWindow: Double = 0.5

    public var cleanupLevel: CleanupLevel = .light
    public var styles: [StyleCategory: WritingStyle] = [.personal: .casual, .work: .formal, .email: .formal, .other: .formal]
    /// Per-app overrides: bundle identifier → category.
    public var appCategoryOverrides: [String: AppCategory] = [:]

    /// Identifier of the transcription engine (see `EngineID`).
    public var engine: String = EngineID.appleSpeech
    public var useLanguageModel = true
    public var microphoneUID: String?

    public var soundsEnabled = true
    public var showBarAlways = false
    public var showInDock = true
    public var launchAtLogin = false
    public var muteMediaWhileDictating = false

    public var contextAwareness = true
    public var screenOCR = false
    public var autoLearnWords = true
    /// Notetaker: offer to take notes when a call starts (Zoom, Teams, FaceTime…), and stop when it ends.
    public var suggestNotesForCalls = true
    /// Name notes after the calendar event you're in (asks for Calendar access once).
    public var useCalendarForNotes = true
    /// Open the notepad when the Notetaker starts.
    public var showNotepad = true
    /// The one-time explanation of recording consent was confirmed on this Mac.
    public var notetakerConsentAcknowledged = false
    /// Once a day, ask GitHub for the latest version number (nothing about you is sent).
    public var checkForUpdates = true
    public var lastUpdateCheck: Date?
    /// Learned words the user undid (lowercased); never learned again.
    public var rejectedLearnedWords: [String] = []
    public var historyRetention: HistoryRetention = .keep
    public var keepAudioDays = 14

    public var autoApplyTransform: UUID?
    public var pressEnterCommand = false
    public var variableRecognition = false
    public var fileTagging = true

    public var hasCompletedOnboarding = false
    /// Local AI models: keep loaded (fastest) or load on key-press and unload when idle (saves memory).
    public var modelMemory: ModelMemoryPolicy = .loadWhenDictating

    public init() {}

    /// A profile from another Mac brings its preferences, but this Mac's privacy choices, microphone,
    /// onboarding state and (unless asked) shortcuts stay as they are.
    public func importing(_ incoming: AppSettings, includeShortcuts: Bool) -> AppSettings {
        var merged = incoming
        if !includeShortcuts { merged.shortcuts = shortcuts }
        merged.microphoneUID = microphoneUID
        merged.hasCompletedOnboarding = hasCompletedOnboarding
        merged.historyRetention = historyRetention
        merged.keepAudioDays = keepAudioDays
        merged.screenOCR = screenOCR
        merged.contextAwareness = contextAwareness
        merged.autoLearnWords = autoLearnWords
        merged.rejectedLearnedWords = rejectedLearnedWords
        merged.checkForUpdates = checkForUpdates
        merged.lastUpdateCheck = lastUpdateCheck
        merged.useCalendarForNotes = useCalendarForNotes
        merged.suggestNotesForCalls = suggestNotesForCalls
        merged.notetakerConsentAcknowledged = notetakerConsentAcknowledged
        return merged
    }

    public func style(for category: AppCategory) -> WritingStyle {
        styles[category.styleCategory] ?? .formal
    }

    public init(from decoder: Decoder) throws {
        let d = AppSettings()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func v<T: Decodable>(_ key: CodingKeys, _ fallback: T) -> T {
            (try? c.decodeIfPresent(T.self, forKey: key)) ?? fallback
        }
        shortcuts = v(.shortcuts, d.shortcuts)
        holdThreshold = v(.holdThreshold, d.holdThreshold)
        doubleTapWindow = v(.doubleTapWindow, d.doubleTapWindow)
        cleanupLevel = v(.cleanupLevel, d.cleanupLevel)
        styles = v(.styles, d.styles)
        appCategoryOverrides = v(.appCategoryOverrides, d.appCategoryOverrides)
        engine = v(.engine, d.engine)
        useLanguageModel = v(.useLanguageModel, d.useLanguageModel)
        microphoneUID = v(.microphoneUID, d.microphoneUID)
        soundsEnabled = v(.soundsEnabled, d.soundsEnabled)
        showBarAlways = v(.showBarAlways, d.showBarAlways)
        showInDock = v(.showInDock, d.showInDock)
        launchAtLogin = v(.launchAtLogin, d.launchAtLogin)
        muteMediaWhileDictating = v(.muteMediaWhileDictating, d.muteMediaWhileDictating)
        contextAwareness = v(.contextAwareness, d.contextAwareness)
        screenOCR = v(.screenOCR, d.screenOCR)
        autoLearnWords = v(.autoLearnWords, d.autoLearnWords)
        suggestNotesForCalls = v(.suggestNotesForCalls, d.suggestNotesForCalls)
        useCalendarForNotes = v(.useCalendarForNotes, d.useCalendarForNotes)
        showNotepad = v(.showNotepad, d.showNotepad)
        notetakerConsentAcknowledged = v(.notetakerConsentAcknowledged, d.notetakerConsentAcknowledged)
        checkForUpdates = v(.checkForUpdates, d.checkForUpdates)
        lastUpdateCheck = v(.lastUpdateCheck, d.lastUpdateCheck)
        rejectedLearnedWords = v(.rejectedLearnedWords, d.rejectedLearnedWords)
        historyRetention = v(.historyRetention, d.historyRetention)
        keepAudioDays = v(.keepAudioDays, d.keepAudioDays)
        autoApplyTransform = v(.autoApplyTransform, d.autoApplyTransform)
        pressEnterCommand = v(.pressEnterCommand, d.pressEnterCommand)
        variableRecognition = v(.variableRecognition, d.variableRecognition)
        fileTagging = v(.fileTagging, d.fileTagging)
        hasCompletedOnboarding = v(.hasCompletedOnboarding, d.hasCompletedOnboarding)
        modelMemory = v(.modelMemory, d.modelMemory)
    }
}

public enum EngineID {
    public static let appleDictation = "apple-dictation"
    public static let appleSpeech = "apple-speech"
    public static let parakeet = "parakeet-v2"
}
