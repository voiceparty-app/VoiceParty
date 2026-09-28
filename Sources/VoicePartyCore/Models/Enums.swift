import Foundation

/// How much the text is rewritten after transcription.
public enum CleanupLevel: String, Codable, CaseIterable, Sendable {
    /// Transcribe exactly what was said (voice commands and dictionary still apply).
    case none
    /// Remove fillers, fix grammar and punctuation, apply self-corrections.
    case light
    /// Also tighten wording for clarity and concision.
    case medium

    public var displayName: String {
        switch self {
        case .none: "None"
        case .light: "Light"
        case .medium: "Medium"
        }
    }
}

/// Tone applied per app category.
public enum WritingStyle: String, Codable, CaseIterable, Sendable {
    case formal, casual, veryCasual, excited

    public var displayName: String {
        switch self {
        case .formal: "Formal"
        case .casual: "Casual"
        case .veryCasual: "Very casual"
        case .excited: "Excited!"
        }
    }

    public var summary: String {
        switch self {
        case .formal: "Capitals and full punctuation"
        case .casual: "Capitals, lighter punctuation"
        case .veryCasual: "Lowercase, minimal punctuation"
        case .excited: "Upbeat, with exclamation marks"
        }
    }
}

/// The four style buckets shown in the Style tab.
public enum StyleCategory: String, Codable, CaseIterable, Sendable, CodingKeyRepresentable {
    case personal, work, email, other

    public var displayName: String {
        switch self {
        case .personal: "Personal messages"
        case .work: "Work messages"
        case .email: "Email"
        case .other: "Other"
        }
    }

    public var allowedStyles: [WritingStyle] {
        switch self {
        case .personal: [.formal, .casual, .veryCasual]
        default: [.formal, .casual, .excited]
        }
    }
}

/// Finer-grained category of the app being dictated into (used for stats and style routing).
public enum AppCategory: String, Codable, CaseIterable, Sendable {
    case aiPrompt, email, workMessage, personalMessage, document, code, terminal, other

    public var styleCategory: StyleCategory {
        switch self {
        case .email: .email
        case .workMessage: .work
        case .personalMessage: .personal
        default: .other
        }
    }

    public var displayName: String {
        switch self {
        case .aiPrompt: "AI prompts"
        case .email: "Emails"
        case .workMessage: "Work messages"
        case .personalMessage: "Personal messages"
        case .document: "Documents"
        case .code: "Code"
        case .terminal: "Terminal"
        case .other: "Other tasks"
        }
    }
}

public enum DictationMode: String, Codable, Sendable {
    /// Push-to-talk: recording while the key is held.
    case hold
    /// Locked recording, stopped by the hotkey, ✓, or Esc.
    case handsFree
    /// Voice instruction applied to the selected text.
    case command
}

public enum HistoryRetention: String, Codable, CaseIterable, Sendable {
    case keep, deleteAfter24Hours, neverStore

    /// History older than this should be deleted (nil = keep everything).
    public func cutoff(now: Date = Date()) -> Date? {
        switch self {
        case .keep: nil
        case .deleteAfter24Hours: now.addingTimeInterval(-86_400)
        case .neverStore: .distantFuture
        }
    }

    public var displayName: String {
        switch self {
        case .keep: "Keep on this Mac"
        case .deleteAfter24Hours: "Delete after 24 hours"
        case .neverStore: "Never store"
        }
    }
}

public enum ModelMemoryPolicy: String, Codable, CaseIterable, Sendable {
    case automatic, loadWhenDictating, alwaysReady

    public var displayName: String {
        switch self {
        case .automatic: "Automatic"
        case .loadWhenDictating: "Load when I dictate"
        case .alwaysReady: "Always ready (fastest)"
        }
    }

    /// Unload a model after this long unused (nil = never). A loaded, idle model costs next to no energy, and loading
    /// one costs several joules: the small fast model (~300 MB) stays half an hour, so everyday gaps between dictations
    /// don't reload it. The strong one (~3 GB, 15–25 J and ~4 s to reload) also stays half an hour on Macs with 32 GB or
    /// more; with less memory it goes after 5 minutes.
    ///
    /// `.automatic` uses those times while the Mac has memory to spare and frees models sooner as it runs low (tests or
    /// builds next to dictation): from 50% free down to 25% the time shrinks to 1 minute for the strong model and 5 for
    /// the fast one. `freeMemoryPercent` is macOS's own figure (`kern.memorystatus_level`, what `memory_pressure` prints).
    public func idleUnload(for tier: PolishRouter.Tier, physicalMemory: UInt64 = ProcessInfo.processInfo.physicalMemory,
                           freeMemoryPercent: Int? = nil) -> Duration? {
        let longest: Duration = tier == .fast || physicalMemory >= 32 << 30 ? .seconds(1800) : .seconds(300)
        switch self {
        case .alwaysReady:
            return nil
        case .loadWhenDictating:
            return longest
        case .automatic:
            let shortest: Duration = min(tier == .fast ? .seconds(300) : .seconds(60), longest)
            guard let free = freeMemoryPercent, free < 50 else { return longest }
            guard free > 25 else { return shortest }
            let low = Double(shortest.components.seconds), high = Double(longest.components.seconds)
            return .seconds(Int((low + (high - low) * Double(free - 25) / 25).rounded()))
        }
    }
}
