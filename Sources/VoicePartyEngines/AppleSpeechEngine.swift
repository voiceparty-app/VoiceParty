@preconcurrency import AVFoundation
import Foundation
import Speech
import VoicePartyCore

/// Apple's on-device speech models via `SpeechAnalyzer`.
///
/// `.dictation` uses `DictationTranscriber`, the only module that honours `AnalysisContext`
/// contextual strings, so it is the default. `.speech` uses the newer `SpeechTranscriber` model,
/// which ignores custom vocabulary (the dictionary is applied after transcription instead).
public final class AppleSpeechEngine: TranscriptionEngine, @unchecked Sendable {
    public enum Kind: Sendable { case dictation, speech }

    public let kind: Kind
    public let locale: Locale

    public var id: String { kind == .dictation ? EngineID.appleDictation : EngineID.appleSpeech }
    public var displayName: String { kind == .dictation ? "Apple Dictation (on-device)" : "Apple Speech (on-device)" }
    public var supportsVocabulary: Bool { kind == .dictation }

    public init(kind: Kind, locale: Locale = Locale(identifier: "en-US")) {
        self.kind = kind
        self.locale = locale
    }

    func resolvedLocale() async throws -> Locale {
        let resolved: Locale? = switch kind {
        case .dictation: await DictationTranscriber.supportedLocale(equivalentTo: locale)
        case .speech: await SpeechTranscriber.supportedLocale(equivalentTo: locale)
        }
        guard let resolved else { throw TranscriptionError.localeNotSupported(locale.identifier) }
        return resolved
    }

    func makeModule(locale: Locale) -> any SpeechModule {
        switch kind {
        case .dictation:
            DictationTranscriber(
                locale: locale,
                contentHints: [.shortForm],
                transcriptionOptions: [.punctuation],
                reportingOptions: [.volatileResults, .frequentFinalization],
                attributeOptions: []
            )
        case .speech:
            SpeechTranscriber(
                locale: locale,
                transcriptionOptions: [],
                reportingOptions: [.volatileResults], // not .fastResults: measured 11.4% vs 12.1% WER on real dictation, same latency
                attributeOptions: []
            )
        }
    }

    public func prepare(progress: (@Sendable (Double) -> Void)?) async throws {
        if kind == .speech, !SpeechTranscriber.isAvailable {
            throw TranscriptionError.engineUnavailable("SpeechTranscriber isn't available on this Mac.")
        }
        let module = makeModule(locale: try await resolvedLocale())
        switch await AssetInventory.status(forModules: [module]) {
        case .installed:
            return
        case .unsupported:
            throw TranscriptionError.localeNotSupported(locale.identifier)
        default:
            break
        }
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [module]) {
            let observation = progress.map { report in
                request.progress.observe(\.fractionCompleted) { p, _ in report(p.fractionCompleted) }
            }
            defer { observation?.invalidate() }
            try await request.downloadAndInstall()
        }
    }

    public func makeSession(vocabulary: [String], naturalFormat: AVAudioFormat?) async throws -> any TranscriptionSession {
        let locale = try await resolvedLocale()
        let module = makeModule(locale: locale)
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [module], considering: naturalFormat) else {
            throw TranscriptionError.assetsUnavailable
        }
        let analyzer = SpeechAnalyzer(modules: [module], options: .init(priority: .userInitiated, modelRetention: .processLifetime))
        try await analyzer.prepareToAnalyze(in: format)
        if kind == .dictation, !vocabulary.isEmpty {
            let context = AnalysisContext()
            context.contextualStrings[.general] = Array(vocabulary.prefix(100))
            try await analyzer.setContext(context)
        }
        let session = AppleSpeechSession(analyzer: analyzer, format: format)
        try await session.start(module: module)
        return session
    }
}

/// One dictation: audio in through an AsyncStream, results collected until finalization.
final class AppleSpeechSession: TranscriptionSession, @unchecked Sendable {
    let audioFormat: AVAudioFormat
    let partialText: AsyncStream<String>

    private let analyzer: SpeechAnalyzer
    private let input: AsyncStream<AnalyzerInput>.Continuation
    private let inputStream: AsyncStream<AnalyzerInput>
    private let partialContinuation: AsyncStream<String>.Continuation
    private var resultsTask: Task<Void, Error>?
    private let lock = NSLock()
    private var finalized: [String] = []
    private var volatile = ""

    init(analyzer: SpeechAnalyzer, format: AVAudioFormat) {
        self.analyzer = analyzer
        audioFormat = format
        (partialText, partialContinuation) = AsyncStream.makeStream(of: String.self, bufferingPolicy: .bufferingNewest(1))
        (inputStream, input) = AsyncStream.makeStream(of: AnalyzerInput.self)
    }

    func start(module: any SpeechModule) async throws {
        // Strong capture is fine: the task ends when the analyzer finishes or is cancelled.
        let onResult: @Sendable (String, Bool) -> Void = { text, isFinal in self.receive(text, isFinal: isFinal) }
        resultsTask = Task { try await Self.consume(module: module, onResult: onResult) }
        try await analyzer.start(inputSequence: inputStream)
    }

    private static func consume(module: any SpeechModule, onResult: @escaping @Sendable (String, Bool) -> Void) async throws {
        if let dictation = module as? DictationTranscriber {
            for try await result in dictation.results {
                onResult(String(result.text.characters), result.isFinal)
            }
        } else if let speech = module as? SpeechTranscriber {
            for try await result in speech.results {
                onResult(String(result.text.characters), result.isFinal)
            }
        }
    }

    private func receive(_ text: String, isFinal: Bool) {
        let preview = lock.withLock {
            if isFinal {
                finalized.append(text)
                volatile = ""
            } else {
                volatile = text
            }
            return (finalized + [volatile]).joined()
        }
        partialContinuation.yield(preview)
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        input.yield(AnalyzerInput(buffer: buffer))
    }

    func finish() async throws -> String {
        input.finish()
        try await analyzer.finalizeAndFinishThroughEndOfInput()
        try await resultsTask?.value
        partialContinuation.finish()
        return lock.withLock { (finalized + [volatile]).joined() }.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func cancel() async {
        input.finish()
        await analyzer.cancelAndFinishNow()
        resultsTask?.cancel()
        partialContinuation.finish()
    }
}
