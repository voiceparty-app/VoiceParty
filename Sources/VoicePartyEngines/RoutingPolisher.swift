import Foundation
import VoicePartyCore

/// Sends each dictation to the cheapest capable model: `.fast` (S1-mini) or `.strong` (Qwen), with a
/// fallback (Apple Foundation Models) when a local model is missing or errors. The pipeline has
/// already skipped the model entirely for text that needs no cleanup.
public final class RoutingPolisher: TextPolisher, @unchecked Sendable {
    public let fast: (any TextPolisher)?
    public let strong: (any TextPolisher)?
    public let fallback: (any TextPolisher)?
    private let lock = NSLock()
    private var lastUsed = "auto"

    /// Shown when no model at all is available.
    public let unavailableReason: String?

    public init(fast: (any TextPolisher)?, strong: (any TextPolisher)?, fallback: (any TextPolisher)?, fallbackUnavailableReason: String? = nil) {
        self.fast = fast
        self.strong = strong
        self.fallback = fallback
        let anything = fast != nil || strong != nil || fallback != nil
        unavailableReason = anything ? nil : fallbackUnavailableReason ?? "AI cleanup is off."
    }

    public var isAvailable: Bool { fast != nil || strong != nil || fallback != nil }

    /// Human-readable description of what's doing the cleanup.
    public var summary: String {
        switch (fast != nil, strong != nil, fallback != nil) {
        case (true, true, _): "Local models (fast + smart)"
        case (true, false, _): "Local fast model"
        case (false, true, _): "Local smart model"
        case (false, false, true): "Apple Intelligence"
        default: "Rules only"
        }
    }

    public var id: String { lock.withLock { lastUsed } }
    public var usesRouting: Bool { true }
    public var hasLocalModel: Bool { fast != nil || strong != nil }

    public func prewarm() async {
        await fast?.prewarm()
        await strong?.prewarm()
    }

    private func candidates(for route: PolishRouter.Route?) -> [any TextPolisher] {
        let ordered: [(any TextPolisher)?] = route == .fast ? [fast, strong, fallback] : [strong, fast, fallback]
        return ordered.compactMap { $0 }
    }

    public func polish(_ request: PolishRequest) async throws -> String {
        var lastError: Error = CancellationError()
        for polisher in candidates(for: request.route) {
            // Cancelled (the dictation timed out or was abandoned): don't go on to wake the next model.
            try Task.checkCancellation()
            do {
                let text = try await polisher.polish(request)
                lock.withLock { lastUsed = polisher.id }
                return text
            } catch {
                lastError = error
            }
        }
        throw lastError
    }

    /// Transforms, Command Mode answers: the strongest available model.
    public func transform(_ text: String, instructions: String) async throws -> String {
        guard let polisher = [strong, fallback, fast].compactMap({ $0 }).first else { throw CancellationError() }
        return try await polisher.transform(text, instructions: instructions)
    }

    public func answer(_ question: String, context: String?) async throws -> String {
        guard let polisher = [strong, fallback, fast].compactMap({ $0 }).first else { throw CancellationError() }
        return try await polisher.answer(question, context: context)
    }
}
