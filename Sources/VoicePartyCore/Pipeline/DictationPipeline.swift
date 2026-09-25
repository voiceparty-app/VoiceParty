import Foundation

/// What a polisher is asked to do with one dictation.
public struct PolishRequest: Sendable, Equatable {
    public var text: String
    public var level: CleanupLevel
    public var style: WritingStyle
    public var category: AppCategory
    /// Words to spell exactly (dictionary + on-screen terms).
    public var vocabulary: [String]
    public var appName: String?
    /// A little of the text before the cursor, so the result fits in.
    public var textBeforeCursor: String?
    /// Keep code identifiers exactly as written (IDEs).
    public var preserveIdentifiers: Bool
    /// Which model tier the router picked (nil when routing isn't used).
    public var route: PolishRouter.Route?

    public init(
        text: String,
        level: CleanupLevel,
        style: WritingStyle,
        category: AppCategory,
        vocabulary: [String] = [],
        appName: String? = nil,
        textBeforeCursor: String? = nil,
        preserveIdentifiers: Bool = false
    ) {
        self.text = text
        self.level = level
        self.style = style
        self.category = category
        self.vocabulary = vocabulary
        self.appName = appName
        self.textBeforeCursor = textBeforeCursor
        self.preserveIdentifiers = preserveIdentifiers
    }
}

/// Rewrites transcribed text (on-device language model, a local model server, …).
public protocol TextPolisher: Sendable {
    var id: String { get }
    /// Called when recording starts so the first request is fast.
    func prewarm() async
    func polish(_ request: PolishRequest) async throws -> String
    /// Free-form rewrite for Command Mode and Transforms.
    func transform(_ text: String, instructions: String) async throws -> String
    /// Answer a spoken question (Command Mode with nothing selected).
    func answer(_ question: String, context: String?) async throws -> String
    /// Polishers that pick a model per dictation get the router's decision (and `.skip` short-circuits).
    var usesRouting: Bool { get }
}

extension TextPolisher {
    public var usesRouting: Bool { false }
}

public struct PipelineResult: Sendable, Equatable {
    public var text: String
    public var status: TranscriptStatus
    public var polisherID: String?
    public var style: WritingStyle
    public var snippetsUsed: [UUID]
    public var dictionaryUsed: [UUID]
    public var dictionaryReplacements: Int
    public var wordsCorrected: Int
}

/// raw → voice commands → cleanup (language model or rules) → snippets → dictionary → style.
public struct DictationPipeline: Sendable {
    public var cleaner = RuleBasedCleaner()
    public var snippets: [Snippet]
    public var dictionary: [DictionaryEntry]
    public var cleanupLevel: CleanupLevel
    public var styles: [StyleCategory: WritingStyle]
    public var polisher: (any TextPolisher)?
    /// Whether a word is ordinary English (the app passes Apple's vocabulary). Dictionary names never replace
    /// ordinary words ("brand" is not "Brandt"); without it only a small built-in word list is known.
    public var isEnglishWord: (@Sendable (String) -> Bool)?

    /// Longer dictations are cleaned up this many words at a time, in whole sentences.
    public static let chunkWords = 160

    /// Utterances shorter than this skip the language model (latency isn't worth it).
    public var minWordsForPolisher = 4
    /// Vibe coding: spoken file names → real ones, optionally @-tagged.
    public var codeFormatter: CodeFormatter?
    /// Vibe coding: spoken words → identifiers seen in the editor.
    public var identifierMatcher: IdentifierMatcher?
    /// A model slower than this is abandoned and rules are used (a hung model must never block dictation).
    public var polishTimeout: Duration = .seconds(5)

    public init(
        snippets: [Snippet],
        dictionary: [DictionaryEntry],
        cleanupLevel: CleanupLevel,
        styles: [StyleCategory: WritingStyle],
        polisher: (any TextPolisher)?
    ) {
        self.snippets = snippets
        self.dictionary = dictionary
        self.cleanupLevel = cleanupLevel
        self.styles = styles
        self.polisher = polisher
    }

    public func process(raw: String, context: DictationContext) async -> PipelineResult {
        let style = styles[context.category.styleCategory] ?? .formal
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return PipelineResult(text: "", status: .empty, polisherID: nil, style: style, snippetsUsed: [], dictionaryUsed: [],
                                  dictionaryReplacements: 0, wordsCorrected: 0)
        }

        let expander = SnippetExpander(snippets: snippets)
        if let whole = expander.wholeUtteranceMatch(trimmed) {
            return PipelineResult(text: whole.expansion, status: .rulesOnly, polisherID: nil, style: style, snippetsUsed: [whole.id],
                                  dictionaryUsed: [], dictionaryReplacements: 0, wordsCorrected: 0)
        }

        // A command in a terminal stays a command: no capitals, no period, flags and paths untouched
        // ("kubectl get pods -n production", "docker build ."). A spoken prompt to a terminal AI is prose.
        if context.category == .terminal && Self.looksLikeCommand(trimmed) {
            var command = cleaner.removeFillers(trimmed)
            command = TextTools.replacing(command, pattern: #"[ \t]{2,}"#, with: " ").trimmingCharacters(in: .whitespaces)
            if command.hasSuffix(".") && !command.hasSuffix(" .") && !command.hasSuffix("..") { command.removeLast() }
            if let first = command.first, first.isUppercase, command.dropFirst().first?.isLowercase == true {
                command = first.lowercased() + command.dropFirst()
            }
            if let identifierMatcher { command = identifierMatcher.apply(command) }
            if let codeFormatter { command = codeFormatter.apply(command) }
            return PipelineResult(text: command, status: .rulesOnly, polisherID: nil, style: style, snippetsUsed: [],
                                  dictionaryUsed: [], dictionaryReplacements: 0, wordsCorrected: 0)
        }

        let modelMayRun = cleanupLevel != .none && polisher != nil && TextTools.wordCount(trimmed) >= minWordsForPolisher
        var text = cleaner.applyVoiceCommands(trimmed, resolveRetractions: !modelMayRun)
        var status = TranscriptStatus.rulesOnly
        var polisherID: String?

        var cleanedInChunks = false
        if modelMayRun, let polisher {
            // Long dictations go through the model a few sentences at a time (the size it was tuned on).
            let terms = VocabularyBuilder.build(dictionary: dictionary, contextTerms: context.terms, limit: 200)
            var done = ""
            var anyPolished = false
            for chunk in TextChunker.split(text, maxWords: Self.chunkWords) {
                let body = chunk.trimmingCharacters(in: .whitespacesAndNewlines)
                let trailing = String(chunk.reversed().prefix(while: \.isWhitespace).reversed())
                guard !body.isEmpty else { done += chunk; continue }
                let before = done.isEmpty ? context.textBeforeCursor : (context.textBeforeCursor ?? "") + done
                if let polished = await polishChunk(body, with: polisher, terms: terms, style: style, context: context, textBefore: before) {
                    // Models occasionally leave an "um" in; fillers never belong in the result.
                    done += cleaner.clean(cleanupLevel == .none ? polished : cleaner.removeFillers(polished), level: .none) + trailing
                    anyPolished = true
                } else {
                    done += cleaner.clean(cleaner.removeRetractions(body), level: cleanupLevel) + trailing
                }
            }
            text = done
            cleanedInChunks = true
            if anyPolished {
                status = .formatted
                polisherID = polisher.id
            }
        }
        // Retractions the model didn't resolve (or no model ran): the rules delete the retracted part.
        text = cleaner.removeRetractions(text)
        // Spoken quotes and "et cetera" the model wrote out in words.
        text = RuleBasedCleaner.shortenEtCetera(SpokenQuotes.apply(text))
        if !cleanedInChunks {
            text = cleaner.clean(text, level: cleanupLevel)
        }
        if cleanupLevel != .none && context.category != .code && context.category != .terminal {
            // Discourse fillers ("So…", "you know", "basically") — models leave many of them in.
            text = DiscourseCleaner().clean(text)
            // Homophones the recognizer (or a small model) got wrong, where context is unambiguous.
            text = HomophoneFixer().fix(text)
            // Long dictations read better in paragraphs (before snippets, so an expansion isn't split).
            text = Paragrapher().apply(text)
        }

        let expanded = expander.expand(text)
        text = expanded.text
        if let identifierMatcher { text = identifierMatcher.apply(text) }
        if let codeFormatter { text = codeFormatter.apply(text) }
        let applied = DictionaryApplier(entries: dictionary, isEnglishWord: isEnglishWord).apply(text)
        text = applied.text

        let protected = Set(dictionary.filter { $0.replacement == nil }.map(\.phrase))
        let endsWithSnippet = snippets.contains { expanded.used.contains($0.id) && text.hasSuffix($0.expansion) }
        text = StyleFormatter(protectedWords: protected).apply(style, to: text, addTerminalPunctuation: !endsWithSnippet)

        let rawTokens = TextTools.normalizedTokens(trimmed)
        let corrected = max(0, rawTokens.count - TextTools.lcsLength(rawTokens, TextTools.normalizedTokens(text)))
        return PipelineResult(
            text: text, status: status, polisherID: polisherID, style: style, snippetsUsed: expanded.used,
            dictionaryUsed: applied.usedIDs, dictionaryReplacements: applied.replacements, wordsCorrected: corrected
        )
    }

    /// One chunk through the routed model; nil when the router skips it, the model fails or times out,
    /// or the drift guard rejects the result (the caller then uses the rules).
    private func polishChunk(_ text: String, with polisher: any TextPolisher, terms: [String], style: WritingStyle,
                             context: DictationContext, textBefore: String?) async -> String? {
        // Only terms that plausibly occur in this text (fast prompt, no glossary echo).
        let vocabulary = VocabularyBuilder.relevant(terms, to: text)
        var request = PolishRequest(
            text: text, level: cleanupLevel, style: style, category: context.category, vocabulary: vocabulary,
            appName: context.appName, textBeforeCursor: textBefore.map { String($0.suffix(600)) },
            preserveIdentifiers: context.category == .code || context.category == .terminal
        )
        if polisher.usesRouting {
            let route = PolishRouter.route(text: text, category: context.category, level: cleanupLevel, relevantVocabulary: vocabulary)
            guard route != .skip else { return nil }
            request.route = route
        }
        guard let polished = await Self.polish(request, with: polisher, timeout: polishTimeout),
              DriftGuard.accepts(input: text, output: polished, level: cleanupLevel, vocabulary: vocabulary) else { return nil }
        return polished
    }

    /// Programs people type at a prompt. Short utterances are treated as commands too.
    static let commandWords: Set<String> = [
        "git", "cd", "ls", "ll", "cat", "grep", "rg", "find", "mkdir", "rm", "mv", "cp", "touch", "chmod", "chown", "sudo", "open",
        "echo", "export", "source", "npm", "npx", "yarn", "pnpm", "bun", "node", "deno", "python", "python3", "pip", "pip3", "uv",
        "poetry", "brew", "swift", "xcodebuild", "make", "cmake", "cargo", "rustc", "go", "java", "gradle", "mvn", "docker",
        "kubectl", "helm", "terraform", "aws", "gcloud", "az", "ssh", "scp", "rsync", "curl", "wget", "tar", "zip", "unzip",
        "ps", "kill", "pkill", "top", "htop", "man", "which", "vim", "nvim", "nano", "code", "claude", "gh", "tmux", "less", "tail",
        "head", "diff", "sed", "awk", "jq", "psql", "mysql", "redis-cli", "ruby", "bundle", "rails", "php", "composer", "flutter",
    ]

    /// Whether a dictation into a terminal is a command rather than a sentence.
    static func looksLikeCommand(_ text: String) -> Bool {
        let words = text.split(whereSeparator: \.isWhitespace)
        guard let first = words.first?.lowercased() else { return false }
        if TextTools.wordCount(text) <= 4 { return true }
        let hasFlag = words.contains { $0.hasPrefix("-") && $0.count > 1 && $0.dropFirst().first?.isLetter == true || $0.hasPrefix("--") }
        return words.count <= 16 && (commandWords.contains(first) || hasFlag)
    }

    /// Runs the polisher with a deadline; nil on error or timeout. A race rather than a task group: a group
    /// waits for its children, so a model call that ignores cancellation would hold the dictation hostage.
    static func polish(_ request: PolishRequest, with polisher: any TextPolisher, timeout: Duration) async -> String? {
        let first = FirstResult<String?>()
        return await withCheckedContinuation { continuation in
            first.continuation = continuation
            let work = Task { first.finish(try? await polisher.polish(request)) }
            Task {
                try? await Task.sleep(for: timeout)
                work.cancel()
                first.finish(nil)
            }
        }
    }
}

/// Resumes its continuation with whichever result arrives first.
final class FirstResult<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    var continuation: CheckedContinuation<T, Never>?

    func finish(_ value: T) {
        let waiting: CheckedContinuation<T, Never>? = lock.withLock {
            defer { continuation = nil }
            return continuation
        }
        waiting?.resume(returning: value)
    }
}
