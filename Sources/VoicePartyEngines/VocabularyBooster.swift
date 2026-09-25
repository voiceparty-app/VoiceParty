import FluidAudio
import Foundation

/// Opt-in dictionary boosting for the Parakeet engines (benchmark only for now): a small CTC model
/// (parakeet-ctc-110m) spots the dictionary's terms in the audio and swaps them into the transcript where the
/// acoustics support it. The same steps as FluidAudio's `VocabularyBoostingSession`, which reads the CTC
/// tokenizer from FluidAudio's own cache folder; this one uses `directory`.
public final class VocabularyBooster: @unchecked Sendable {
    public static let repository = "FluidInference/parakeet-ctc-110m-coreml"
    public static let revision = "accdafd8cf8a2ff1cabe3c11e54416b405d409aa"
    /// FluidAudio's folder name for the repo: `download(to:)` needs a directory with this name.
    public static let folderName = Repo.parakeetCtc110m.folderName

    /// Folder holding the CTC model's files (MelSpectrogram, AudioEncoder, tokenizer.json, vocab.json).
    public let directory: URL
    private let minSimilarity: Float?
    private let lock = NSLock()
    private var loaded: (models: CtcModels, tokenizer: CtcTokenizer)?
    private var cache: (terms: [String], prepared: Prepared?)?

    /// `minSimilarity`: how closely a transcript word must resemble a term to be replaced; nil keeps FluidAudio's
    /// vocabulary-size default (0.50–0.60), which inserted many false terms on real dictation (0.85 didn't).
    public init(directory: URL, minSimilarity: Float? = nil) {
        self.directory = directory
        self.minSimilarity = minSimilarity
    }

    public static func isInstalled(at directory: URL) -> Bool {
        CtcModels.modelsExist(at: directory) && FileManager.default.fileExists(atPath: directory.appending(path: "tokenizer.json").path)
    }

    /// Downloads the CTC model (about 100 MB) from Hugging Face at the pinned commit.
    public static func download(to directory: URL) async throws {
        precondition(directory.lastPathComponent == folderName, "FluidAudio downloads into a folder named \(folderName)")
        ModelRegistry.baseURL = "https://huggingface.co"
        ModelRegistry.revisionOverrides[repository] = revision
        try await CtcModels.download(to: directory, variant: .ctc110m)
    }

    /// Loads the CTC model and tokenizer (local files only).
    public func prepare() async throws {
        if lock.withLock({ loaded }) != nil { return }
        let models = try await CtcModels.loadDirect(from: directory, variant: .ctc110m)
        let tokenizer = try await CtcTokenizer.load(from: directory)
        lock.withLock { loaded = (models, tokenizer) }
    }

    /// The spotter and rescorer for one term list (rebuilt only when the list changes).
    public struct Prepared: Sendable {
        let vocabulary: CustomVocabularyContext
        let spotter: CtcKeywordSpotter
        let rescorer: VocabularyRescorer
        let cbw: Float
        let minSimilarity: Float
    }

    public func prepared(for terms: [String]) async throws -> Prepared? {
        if let cache = lock.withLock({ cache }), cache.terms == terms { return cache.prepared }
        try await prepare()
        guard let current = lock.withLock({ loaded }) else { return nil }
        let (models, tokenizer) = current
        let vocabulary = CustomVocabularyContext(terms: terms.compactMap { term in
            let ids = tokenizer.encode(term)
            return ids.isEmpty ? nil : CustomVocabularyTerm(text: term, ctcTokenIds: ids)
        })
        var prepared: Prepared?
        if !vocabulary.terms.isEmpty {
            let spotter = CtcKeywordSpotter(models: models, blankId: models.vocabulary.count)
            // Both Parakeet v2 and Unified write numbers as digits, so the rescue pass gets FluidAudio's similarity
            // floors for such engines; without them it swapped unrelated words for terms in testing.
            let rescorer = try await VocabularyRescorer.create(spotter: spotter, vocabulary: vocabulary,
                                                               config: VocabularyBoostingSession.itnDefaultConfig,
                                                               ctcModelDirectory: directory)
            let sizeConfig = ContextBiasingConstants.rescorerConfig(forVocabSize: vocabulary.terms.count)
            prepared = Prepared(vocabulary: vocabulary, spotter: spotter, rescorer: rescorer, cbw: sizeConfig.cbw,
                                minSimilarity: minSimilarity ?? max(sizeConfig.minSimilarity, vocabulary.minSimilarity))
        }
        lock.withLock { cache = (terms, prepared) }
        return prepared
    }

    /// `text` with dictionary terms swapped in where the CTC model heard them. `tokenTimings` must be on the
    /// clock of `samples` (16 kHz mono). Never fails: on any error the transcript comes back unchanged.
    public static func rescore(_ text: String, tokenTimings: [TokenTiming], samples: [Float], with prepared: Prepared) async -> String {
        guard !tokenTimings.isEmpty, !samples.isEmpty else { return text }
        guard let spot = try? await prepared.spotter.spotKeywordsWithLogProbs(audioSamples: samples,
                                                                             customVocabulary: prepared.vocabulary),
              !spot.logProbs.isEmpty else { return text }
        let output = prepared.rescorer.ctcTokenRescore(
            transcript: text, tokenTimings: tokenTimings, logProbs: spot.logProbs, frameDuration: spot.frameDuration,
            cbw: prepared.cbw, marginSeconds: 0.5, minSimilarity: prepared.minSimilarity)
        return output.wasModified ? output.text : text
    }
}
