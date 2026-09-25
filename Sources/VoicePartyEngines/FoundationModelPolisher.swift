import Foundation
import FoundationModels
import VoicePartyCore

/// Cleanup, transforms, and Command Mode answers using Apple's on-device language model.
///
/// Uses `.permissiveContentTransformations` guardrails (fewer false refusals when rewriting the
/// user's own text), greedy sampling (deterministic), and a fresh session per request. The pipeline's
/// `DriftGuard` rejects output that strays from what was said.
public final class FoundationModelPolisher: TextPolisher, @unchecked Sendable {
    public let id = "apple-foundation-model"
    private let model = SystemLanguageModel(useCase: .general, guardrails: .permissiveContentTransformations)
    private let lock = NSLock()
    private var warmSession: LanguageModelSession?

    public init() {}

    public var isAvailable: Bool { model.isAvailable }

    /// Human-readable reason when the model can't be used.
    public var unavailableReason: String? {
        switch model.availability {
        case .available: nil
        case .unavailable(.appleIntelligenceNotEnabled): "Turn on Apple Intelligence in System Settings to use AI cleanup."
        case .unavailable(.deviceNotEligible): "This Mac doesn't support Apple Intelligence."
        case .unavailable(.modelNotReady): "Apple Intelligence is still downloading its model."
        case .unavailable: "Apple Intelligence isn't available."
        }
    }

    static let cleanupInstructions = CleanupPrompt.system

    public func prewarm() async {
        guard isAvailable else { return }
        let session = LanguageModelSession(model: model, instructions: Self.cleanupInstructions)
        session.prewarm()
        lock.withLock { warmSession = session }
    }

    private func takeCleanupSession() -> LanguageModelSession {
        lock.withLock {
            defer { warmSession = nil }
            return warmSession ?? LanguageModelSession(model: model, instructions: Self.cleanupInstructions)
        }
    }

    public func polish(_ request: PolishRequest) async throws -> String {
        guard isAvailable else { throw TranscriptionError.engineUnavailable(unavailableReason ?? "Unavailable") }
        let session = takeCleanupSession()
        let words = TextTools.wordCount(request.text)
        let options = GenerationOptions(sampling: .greedy, maximumResponseTokens: min(3000, words * 3 + 60))
        let response = try await session.respond(to: CleanupPrompt.singlePrompt(for: request), options: options)
        return CleanupPrompt.stripWrapping(response.content)
    }

    public func transform(_ text: String, instructions: String) async throws -> String {
        guard isAvailable else { throw TranscriptionError.engineUnavailable(unavailableReason ?? "Unavailable") }
        let session = LanguageModelSession(model: model, instructions: """
        You rewrite text according to the user's instructions. The text is given between <text> and </text>. \
        Reply with the rewritten text only: no preamble, no quotes, no tags, no explanations.
        """)
        let options = GenerationOptions(sampling: .greedy, maximumResponseTokens: min(3500, TextTools.wordCount(text) * 4 + 200))
        let response = try await session.respond(to: "Instructions: \(instructions)\n\n<text>\n\(text)\n</text>", options: options)
        return CleanupPrompt.stripWrapping(response.content)
    }

    public func answer(_ question: String, context: String?) async throws -> String {
        guard isAvailable else { throw TranscriptionError.engineUnavailable(unavailableReason ?? "Unavailable") }
        let session = LanguageModelSession(model: model, instructions: "Answer the user's question helpfully and concisely. Reply with the answer only.")
        var prompt = question
        if let context, !context.isEmpty { prompt = "Context from the screen:\n\(context.suffix(1500))\n\nQuestion: \(question)" }
        let response = try await session.respond(to: prompt, options: GenerationOptions(sampling: .greedy, maximumResponseTokens: 800))
        return response.content.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
