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

    public let modelsDirectory: URL
    public var id: String { EngineID.parakeet }
    public var displayName: String { "Parakeet (on-device)" }
    public var supportsVocabulary: Bool { false }

    private let lock = NSLock()
    private var manager: AsrManager?
    private var loading: Task<Void, Error>?
    /// When set, the folder must match this digest before the models are loaded (files changed on disk are never run).
    private let expectedDigest: String?

    public init(modelsDirectory: URL, expectedDigest: String? = nil) {
        self.modelsDirectory = modelsDirectory
        self.expectedDigest = expectedDigest
    }

    public static func isInstalled(at directory: URL) -> Bool {
        AsrModels.modelsExist(at: directory, version: version)
    }

    /// Downloads the CoreML models from Hugging Face (FluidInference) into `directory`.
    public static func download(to directory: URL, progress: @escaping @Sendable (Double) -> Void) async throws {
        // Always Hugging Face itself (not a REGISTRY_URL from the environment), at the pinned commit.
        ModelRegistry.baseURL = "https://huggingface.co"
        if let external = EnhancementCatalog.enhancement(EnhancementID.parakeet)?.external, let repo = external.repository,
           let revision = external.revision {
            ModelRegistry.revisionOverrides[repo] = revision
        }
        _ = try await AsrModels.download(to: directory, version: version) { update in
            progress(update.fractionCompleted)
        }
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
        // The first load compiles the models for the Neural Engine (a few seconds); later loads are cached.
        let models = try await AsrModels.load(from: modelsDirectory, version: Self.version)
        let loaded = AsrManager(config: .default, models: models)
        lock.withLock { manager = loaded }
    }

    public func makeSession(vocabulary: [String], naturalFormat: AVAudioFormat?) async throws -> any TranscriptionSession {
        try await prepare(progress: nil)
        guard let manager = lock.withLock({ manager }) else { throw TranscriptionError.assetsUnavailable }
        return ParakeetSession(manager: manager)
    }
}

/// Collects 16 kHz mono samples; transcribes them in one pass at `finish()`.
final class ParakeetSession: TranscriptionSession, @unchecked Sendable {
    let audioFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
    let partialText: AsyncStream<String>

    private let manager: AsrManager
    private let partialContinuation: AsyncStream<String>.Continuation
    private let lock = NSLock()
    private var samples: [Float] = []
    private var cancelled = false

    init(manager: AsrManager) {
        self.manager = manager
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
        var state = try TdtDecoderState()
        let result = try await manager.transcribe(audio, decoderState: &state)
        return result.text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func cancel() async {
        lock.withLock { cancelled = true }
        partialContinuation.finish()
    }
}
