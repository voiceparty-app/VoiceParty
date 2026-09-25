@preconcurrency import AVFoundation
import FluidAudio
import Foundation
import VoicePartyCore

/// NVIDIA Parakeet TDT (English v2) on the Apple Neural Engine via FluidAudio (Apache-2.0).
/// An optional Enhancement: models are downloaded only when the user chooses it.
/// Transcribes the whole utterance at key-up (≈100× real time), so there are no live partials.
public final class ParakeetEngine: TranscriptionEngine, @unchecked Sendable {
    /// English v2 by default; VP_PARAKEET=v3|ultra|redux selects a variant for benchmarking.
    public static var version: AsrModelVersion {
        switch ProcessInfo.processInfo.environment["VP_PARAKEET"] {
        case "v3": .v3
        case "ultra": .ultra
        case "redux": .redux
        default: .v2
        }
    }

    /// Where `version` is fetched from, at an exact commit: v2's from the Enhancement catalog; Ultra's is pinned
    /// here for benchmarking. Variants without a pin (v3, redux) are never downloaded.
    static var pinnedSource: (repository: String, revision: String)? {
        switch version {
        case .v2:
            guard let external = EnhancementCatalog.enhancement(EnhancementID.parakeet)?.external,
                  let repository = external.repository, let revision = external.revision else { return nil }
            return (repository, revision)
        case .ultra: return ("FluidInference/parakeet-ultra-coreml", "95eaa59a39d4394f047a4dc5cce480388a60d1b6")
        default: return nil
        }
    }

    /// FluidAudio's folder name for `version`: `download(to:)` needs a directory with this name.
    public static var folderName: String {
        let repo: Repo = switch version {
        case .v3: .parakeetV3
        case .ultra: .parakeetUltra
        case .redux: .parakeetRedux
        default: .parakeetV2
        }
        return repo.folderName
    }

    public let modelsDirectory: URL
    public var id: String { EngineID.parakeet }
    public var displayName: String { "Parakeet (on-device)" }
    /// Only with opt-in dictionary boosting (benchmark only for now).
    public var supportsVocabulary: Bool { booster != nil }

    private let lock = NSLock()
    private var manager: AsrManager?
    private var loading: Task<Void, Error>?
    /// When set, the folder must match this digest before the models are loaded (files changed on disk are never run).
    private let expectedDigest: String?
    private let booster: VocabularyBooster?

    public init(modelsDirectory: URL, expectedDigest: String? = nil, booster: VocabularyBooster? = nil) {
        self.modelsDirectory = modelsDirectory
        self.expectedDigest = expectedDigest
        self.booster = booster
    }

    public static func isInstalled(at directory: URL) -> Bool {
        AsrModels.modelsExist(at: directory, version: version)
    }

    /// Downloads the CoreML models from Hugging Face (FluidInference) into `directory` (named `folderName`), at the
    /// pinned commit.
    public static func download(to directory: URL, progress: @escaping @Sendable (Double) -> Void) async throws {
        guard let pin = pinnedSource else { throw TranscriptionError.engineUnavailable("Parakeet \(version) has no pinned revision.") }
        // Always Hugging Face itself (not a REGISTRY_URL from the environment), at the pinned commit.
        ModelRegistry.baseURL = "https://huggingface.co"
        ModelRegistry.revisionOverrides[pin.repository] = pin.revision
        _ = try await AsrModels.download(to: directory, version: version) { update in
            progress(update.fractionCompleted)
        }
    }

    /// Sets FluidAudio's expected revision for this model to the one recorded in `directory` (if any), and keeps it on
    /// Hugging Face itself, so loading never triggers a download.
    static func expectRecordedRevision(of directory: URL) {
        ModelRegistry.baseURL = "https://huggingface.co"
        guard let repository = pinnedSource?.repository,
              let recorded = try? String(contentsOf: directory.appending(path: ".fluidaudio-revision"), encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines), !recorded.isEmpty else { return }
        ModelRegistry.revisionOverrides[repository] = recorded
    }

    public func prepare(progress: (@Sendable (Double) -> Void)?) async throws {
        if lock.withLock({ manager }) != nil { return }
        // One load at a time: a dictation starting while the app warms up waits for the same load.
        let task: Task<Void, Error> = lock.withLock {
            if let loading { return loading }
            let task = Task { try await self.load() }
            loading = task
            return task
        }
        do {
            try await task.value
        } catch {
            lock.withLock { loading = nil } // a later dictation may try again
            throw error
        }
    }

    private func load() async throws {
        guard Self.isInstalled(at: modelsDirectory) else {
            throw TranscriptionError.engineUnavailable("Parakeet isn't downloaded yet. Get it from Enhancements.")
        }
        if let expectedDigest {
            let actual = try? FileIntegrity.treeDigest(of: modelsDirectory, ignoring: Enhancement.External.bookkeeping)
            guard actual == expectedDigest else {
                throw TranscriptionError.engineUnavailable("Parakeet's files changed on disk, so they weren't loaded. Reinstall it in Enhancements.")
            }
        }
        // FluidAudio compares the folder's revision marker with the revision it expects before loading, and deletes and
        // re-downloads on a mismatch. Expect exactly the revision the folder records (its files were just verified
        // against their digest above); folders from before pinning have no marker and load as before.
        Self.expectRecordedRevision(of: modelsDirectory)
        try await booster?.prepare()
        // The first load compiles the models for the Neural Engine (a few seconds); later loads are cached.
        let models = try await AsrModels.load(from: modelsDirectory, version: Self.version)
        let loaded = AsrManager(config: .default, models: models)
        lock.withLock { manager = loaded }
    }

    public func makeSession(vocabulary: [String], naturalFormat: AVAudioFormat?) async throws -> any TranscriptionSession {
        try await prepare(progress: nil)
        guard let manager = lock.withLock({ manager }) else { throw TranscriptionError.assetsUnavailable }
        let boost = try await booster?.prepared(for: vocabulary)
        return ParakeetSession { audio in
            var state = try TdtDecoderState()
            let result = try await manager.transcribe(audio, decoderState: &state)
            guard let boost, let timings = result.tokenTimings else { return result.text }
            return await VocabularyBooster.rescore(result.text, tokenTimings: timings, samples: audio, with: boost)
        }
    }
}

/// Collects 16 kHz mono samples; transcribes them in one pass at `finish()`.
final class ParakeetSession: TranscriptionSession, @unchecked Sendable {
    let audioFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
    let partialText: AsyncStream<String>

    private let transcribe: @Sendable ([Float]) async throws -> String
    private let partialContinuation: AsyncStream<String>.Continuation
    private let lock = NSLock()
    private var samples: [Float] = []
    private var cancelled = false

    init(transcribe: @escaping @Sendable ([Float]) async throws -> String) {
        self.transcribe = transcribe
        (partialText, partialContinuation) = AsyncStream.makeStream(of: String.self)
        samples.reserveCapacity(16_000 * 30)
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        guard let data = buffer.floatChannelData?[0] else { return }
        let chunk = UnsafeBufferPointer(start: data, count: Int(buffer.frameLength))
        lock.withLock { samples.append(contentsOf: chunk) }
    }

    func finish() async throws -> String {
        partialContinuation.finish()
        var audio = lock.withLock { samples }
        guard !lock.withLock({ cancelled }), audio.count > 1_600 else { return "" } // < 0.1 s
        // The model wants at least a second of audio: pad a quick "yes" with silence rather than fail.
        if audio.count < 16_000 { audio += [Float](repeating: 0, count: 16_000 - audio.count) }
        return try await transcribe(audio).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func cancel() async {
        lock.withLock { cancelled = true }
        partialContinuation.finish()
    }
}
