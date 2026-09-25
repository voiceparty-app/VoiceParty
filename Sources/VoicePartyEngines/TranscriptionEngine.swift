@preconcurrency import AVFoundation
import Foundation

/// A speech-to-text engine. One engine is created at launch; each dictation opens a session.
public protocol TranscriptionEngine: AnyObject, Sendable {
    var id: String { get }
    var displayName: String { get }
    /// Whether the engine can bias recognition toward custom words.
    var supportsVocabulary: Bool { get }

    /// Downloads/installs models if needed. Safe to call repeatedly.
    func prepare(progress: (@Sendable (Double) -> Void)?) async throws

    /// Opens a session. `naturalFormat` is the microphone's format; the session reports the format it wants.
    func makeSession(vocabulary: [String], naturalFormat: AVAudioFormat?) async throws -> any TranscriptionSession
}

public protocol TranscriptionSession: AnyObject, Sendable {
    /// Audio must be converted to this format before `append`.
    var audioFormat: AVAudioFormat { get }
    /// Live partial text (finalized + volatile), for previews.
    var partialText: AsyncStream<String> { get }
    func append(_ buffer: AVAudioPCMBuffer)
    /// Ends input and returns the final transcript.
    func finish() async throws -> String
    func cancel() async
}

public enum TranscriptionError: Error, LocalizedError {
    case localeNotSupported(String)
    case assetsUnavailable
    case engineUnavailable(String)

    public var errorDescription: String? {
        switch self {
        case .localeNotSupported(let id): "Speech recognition doesn't support \(id) on this Mac."
        case .assetsUnavailable: "The on-device speech model isn't installed yet."
        case .engineUnavailable(let why): why
        }
    }
}
