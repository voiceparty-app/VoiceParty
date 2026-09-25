import Foundation

/// A dictionary word (biases recognition and fixes spelling) or a replacement rule (`btw → by the way`).
public struct DictionaryEntry: Codable, Hashable, Sendable, Identifiable {
    public enum Source: String, Codable, Sendable {
        case manual, learned, imported
    }

    public var id: UUID
    public var phrase: String
    /// When set, `phrase` is replaced by this text; when nil, `phrase` is a vocabulary word.
    public var replacement: String?
    public var source: Source
    public var isStarred: Bool
    public var createdAt: Date
    public var useCount: Int
    public var lastUsedAt: Date?

    public init(
        id: UUID = UUID(),
        phrase: String,
        replacement: String? = nil,
        source: Source = .manual,
        isStarred: Bool = false,
        createdAt: Date = Date(),
        useCount: Int = 0,
        lastUsedAt: Date? = nil
    ) {
        self.id = id
        self.phrase = phrase
        self.replacement = replacement?.isEmpty == true ? nil : replacement
        self.source = source
        self.isStarred = isStarred
        self.createdAt = createdAt
        self.useCount = useCount
        self.lastUsedAt = lastUsedAt
    }

    public var isReplacement: Bool { replacement != nil }
}

/// A spoken trigger that expands into saved text.
public struct Snippet: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var trigger: String
    public var expansion: String
    public var createdAt: Date
    public var useCount: Int

    public init(id: UUID = UUID(), trigger: String, expansion: String, createdAt: Date = Date(), useCount: Int = 0) {
        self.id = id
        self.trigger = trigger
        self.expansion = expansion
        self.createdAt = createdAt
        self.useCount = useCount
    }

    public static let maxTriggerLength = 60
    public static let maxExpansionLength = 4000
}

/// A reusable rewrite prompt bound to ⌥1…⌥9.
public struct TransformDefinition: Codable, Hashable, Sendable, Identifiable {
    public enum Kind: String, Codable, Sendable {
        case polish, promptEngineer, custom
    }

    public var id: UUID
    public var kind: Kind
    public var name: String
    public var summary: String
    public var instructions: String
    /// Polish rule toggles, keyed by `PolishRule.rawValue`.
    public var rules: [String: Bool]
    /// 1…9 → ⌥1…⌥9. nil means no shortcut.
    public var slot: Int?

    public init(
        id: UUID = UUID(),
        kind: Kind,
        name: String,
        summary: String,
        instructions: String,
        rules: [String: Bool] = [:],
        slot: Int?
    ) {
        self.id = id
        self.kind = kind
        self.name = name
        self.summary = summary
        self.instructions = instructions
        self.rules = rules
        self.slot = slot
    }
}

public enum PolishRule: String, CaseIterable, Sendable {
    case concise, clarifyMainPoint, maintainTone, rewordForClarity, reorderForReadability, refinePhrasing, addStructure

    public var displayName: String {
        switch self {
        case .concise: "Tighten wording"
        case .clarifyMainPoint: "Lead with the main point"
        case .maintainTone: "Keep my voice"
        case .rewordForClarity: "Simplify unclear sentences"
        case .reorderForReadability: "Improve the flow of ideas"
        case .refinePhrasing: "Make phrasing more direct"
        case .addStructure: "Break into paragraphs or lists"
        }
    }

    public var instruction: String {
        switch self {
        case .concise: "Make it more concise; remove redundancy."
        case .clarifyMainPoint: "Make the main point clear and put it first."
        case .maintainTone: "Keep the author's tone and voice."
        case .rewordForClarity: "Reword unclear sentences so they are easy to understand."
        case .reorderForReadability: "Reorder sentences so ideas flow logically."
        case .refinePhrasing: "Refine phrasing so it is more direct and impactful."
        case .addStructure: "Add paragraphs or a short list where it helps readability."
        }
    }
}

extension TransformDefinition {
    public static let builtInPolish = TransformDefinition(
        id: UUID(uuidString: "6E0F4C1B-2B0B-4E6D-9C42-1D7C1F2A0001")!,
        kind: .polish,
        name: "Polish",
        summary: "Tidies wording and tightens sentences",
        instructions: "Improve this text.",
        rules: Dictionary(uniqueKeysWithValues: PolishRule.allCases.map {
            ($0.rawValue, [.concise, .clarifyMainPoint, .maintainTone, .rewordForClarity].contains($0))
        }),
        slot: 1
    )

    public static let builtInPromptEngineer = TransformDefinition(
        id: UUID(uuidString: "6E0F4C1B-2B0B-4E6D-9C42-1D7C1F2A0002")!,
        kind: .promptEngineer,
        name: "AI Prompt",
        summary: "Turns rough thoughts into a clear AI prompt",
        instructions: """
        Rewrite this text as a clear, well-structured prompt for an AI assistant. \
        State the goal, relevant context, constraints, and the desired output format. \
        Keep every requirement the author mentioned; do not invent new ones.
        """,
        slot: 2
    )

    public static let defaults: [TransformDefinition] = [builtInPolish, builtInPromptEngineer]
}
