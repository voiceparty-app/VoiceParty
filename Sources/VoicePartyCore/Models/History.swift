import Foundation

/// What was on screen when dictation started. Read locally, used for one dictation, never persisted in full.
public struct DictationContext: Sendable, Equatable {
    public var appBundleID: String?
    public var appName: String?
    public var windowTitle: String?
    public var url: String?
    public var category: AppCategory
    /// Text just before the cursor (a few hundred characters at most).
    public var textBeforeCursor: String?
    public var textAfterCursor: String?
    public var selectedText: String?
    /// Names and jargon pulled from the surrounding text.
    public var terms: [String]

    public init(
        appBundleID: String? = nil,
        appName: String? = nil,
        windowTitle: String? = nil,
        url: String? = nil,
        category: AppCategory = .other,
        textBeforeCursor: String? = nil,
        textAfterCursor: String? = nil,
        selectedText: String? = nil,
        terms: [String] = []
    ) {
        self.appBundleID = appBundleID
        self.appName = appName
        self.windowTitle = windowTitle
        self.url = url
        self.category = category
        self.textBeforeCursor = textBeforeCursor
        self.textAfterCursor = textAfterCursor
        self.selectedText = selectedText
        self.terms = terms
    }

    public static let empty = DictationContext()
}

public enum TranscriptStatus: String, Codable, Sendable {
    /// Cleaned by the language model.
    case formatted
    /// Cleaned by rules only (level None, short utterance, or the model was unavailable/rejected).
    case rulesOnly
    case empty
    case noAudio
    case cancelled
    case error
}

/// One dictation, as shown on the Home tab and used for Insights.
public struct HistoryItem: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var createdAt: Date
    public var mode: DictationMode
    public var status: TranscriptStatus

    public var appBundleID: String?
    public var appName: String?
    public var windowTitle: String?
    public var url: String?
    public var category: AppCategory

    /// Straight from the speech engine.
    public var rawText: String
    /// After cleanup, snippets, dictionary and style.
    public var formattedText: String
    /// What was actually inserted (formatted, or raw after "Restore what you said").
    public var pastedText: String
    /// Field contents after the user's own edits, when observed.
    public var editedText: String?

    public var audioPath: String?
    /// Seconds of audio captured.
    public var duration: Double
    /// Seconds of speech (excludes leading/trailing silence), used for WPM.
    public var speechDuration: Double
    public var wordCount: Int
    /// Key-up to text inserted, in milliseconds.
    public var latencyMs: Int

    public var engine: String
    public var polisher: String?
    public var cleanupLevel: CleanupLevel
    public var style: WritingStyle

    public var wordsCorrected: Int
    public var dictionaryReplacements: Int
    public var revertedAI: Bool

    public init(
        id: UUID = UUID(),
        createdAt: Date = Date(),
        mode: DictationMode,
        status: TranscriptStatus,
        context: DictationContext = .empty,
        rawText: String,
        formattedText: String,
        pastedText: String? = nil,
        audioPath: String? = nil,
        duration: Double,
        speechDuration: Double,
        latencyMs: Int,
        engine: String,
        polisher: String?,
        cleanupLevel: CleanupLevel,
        style: WritingStyle,
        wordsCorrected: Int = 0,
        dictionaryReplacements: Int = 0
    ) {
        self.id = id
        self.createdAt = createdAt
        self.mode = mode
        self.status = status
        appBundleID = context.appBundleID
        appName = context.appName
        // Only the site is kept: full addresses carry tokens and titles carry email subjects, and neither is
        // needed after the dictation (the category already captures what kind of app it was).
        windowTitle = nil
        url = context.url.flatMap { URL(string: $0)?.host() }
        category = context.category
        self.rawText = rawText
        self.formattedText = formattedText
        self.pastedText = pastedText ?? formattedText
        editedText = nil
        self.audioPath = audioPath
        self.duration = duration
        self.speechDuration = speechDuration
        wordCount = TextTools.wordCount(formattedText)
        self.latencyMs = latencyMs
        self.engine = engine
        self.polisher = polisher
        self.cleanupLevel = cleanupLevel
        self.style = style
        self.wordsCorrected = wordsCorrected
        self.dictionaryReplacements = dictionaryReplacements
        revertedAI = false
    }
}
