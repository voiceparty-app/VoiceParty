@preconcurrency import AVFoundation
import FluidAudio
import Foundation
import VoicePartyCore

/// NVIDIA Parakeet Unified EN 0.6B (FastConformer-RNNT, offline int8 encoder) via FluidAudio: the speech Enhancement
/// since Sept 2026 (9.0% vs v2's 10.6% word errors on real dictation). Under the NVIDIA Open Model License, credited
/// "Licensed by NVIDIA Corporation under the NVIDIA Open Model License" (see its Enhancement entry).
public final class ParakeetUnifiedEngine: TranscriptionEngine, @unchecked Sendable {
    public static let engineID = EngineID.parakeetUnified
    public static let repository = "FluidInference/parakeet-unified-en-0.6b-coreml"
    public static let revision = "4252711f6f060f9a2f91e5f081a806d7f45eebd8"
    /// FluidAudio's folder name for the repo: `download(to:)` needs a directory with this name.
    public static let folderName = Repo.parakeetUnified.folderName
    /// Only the offline (full-attention, 15 s window) int8 build: about 615 MB of the 11 GB repo.
    static let variant = "offline"

    public let modelsDirectory: URL
    public var id: String { Self.engineID }
    public var displayName: String { "Parakeet Unified (on-device)" }
    public var supportsVocabulary: Bool { booster != nil }

    private let booster: VocabularyBooster?
    /// When set, the folder must match this digest before the models are loaded (files changed on disk are never run).
    private let expectedDigest: String?
    private let lock = NSLock()
    private var manager: UnifiedAsrManager?
    private var loading: Task<Void, Error>?

    public init(modelsDirectory: URL, expectedDigest: String? = nil, booster: VocabularyBooster? = nil) {
        self.modelsDirectory = modelsDirectory
        self.expectedDigest = expectedDigest
        self.booster = booster
    }

    public static func isInstalled(at directory: URL) -> Bool {
        ModelNames.ParakeetUnified.requiredModels(variant: variant).allSatisfy {
            FileManager.default.fileExists(atPath: directory.appending(path: $0).path)
        }
    }

    /// Downloads the offline int8 files from Hugging Face at the pinned commit.
    public static func download(to directory: URL, progress: (@Sendable (Double) -> Void)? = nil) async throws {
        precondition(directory.lastPathComponent == folderName, "FluidAudio downloads into a folder named \(folderName)")
        ModelRegistry.baseURL = "https://huggingface.co"
        ModelRegistry.revisionOverrides[repository] = revision
        try await ModelHub.download(.parakeetUnified, to: directory.deletingLastPathComponent(), variant: variant) { update in
            progress?(update.fractionCompleted)
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
            lock.withLock { loading = nil }
            throw error
        }
    }

    private func load() async throws {
        guard Self.isInstalled(at: modelsDirectory) else {
            throw TranscriptionError.engineUnavailable("Parakeet Unified isn't downloaded yet. Get it from Enhancements.")
        }
        if let expectedDigest {
            let actual = try? FileIntegrity.treeDigest(of: modelsDirectory, ignoring: Enhancement.External.bookkeeping)
            guard actual == expectedDigest else {
                throw TranscriptionError.engineUnavailable("Parakeet's files changed on disk, so they weren't loaded. Reinstall it in Enhancements.")
            }
        }
        try await booster?.prepare()
        let loaded = UnifiedAsrManager(encoderPrecision: .int8)
        try await loaded.loadModels(from: modelsDirectory) // local files only
        lock.withLock { manager = loaded }
    }

    public func makeSession(vocabulary: [String], naturalFormat: AVAudioFormat?) async throws -> any TranscriptionSession {
        try await prepare(progress: nil)
        guard let manager = lock.withLock({ manager }) else { throw TranscriptionError.assetsUnavailable }
        guard let boost = try await booster?.prepared(for: vocabulary) else {
            return ParakeetSession { try await manager.transcribe($0) }
        }
        return ParakeetSession { audio in
            let result = try await manager.transcribeWithTimings(audio)
            return await VocabularyBooster.rescore(result.text, tokenTimings: result.tokenTimings, samples: audio, with: boost)
        }
    }
}
