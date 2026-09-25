import Foundation
import VoicePartyCore

public enum EngineFactory {
    public struct Option: Identifiable, Sendable {
        public var id: String
        public var name: String
        public var detail: String
    }

    public static let options: [Option] = [
        Option(id: EngineID.appleSpeech, name: "Apple Speech",
               detail: "On-device, Apple's newest model. Accurate, with nothing to download."),
        Option(id: EngineID.appleDictation, name: "Apple Dictation",
               detail: "On-device, older model. Takes dictionary hints but was less accurate overall in testing."),
    ]

    public static let parakeetOption = Option(id: EngineID.parakeet, name: "Parakeet",
                                              detail: "NVIDIA's model on the Neural Engine. The most accurate in testing.")

    /// Where the Parakeet enhancement keeps its models (set by the app).
    nonisolated(unsafe) public static var parakeetDirectory: URL?

    public static func makeEngine(id: String) -> any TranscriptionEngine {
        switch id {
        case EngineID.appleDictation: AppleSpeechEngine(kind: .dictation)
        case EngineID.parakeet:
            if let dir = parakeetDirectory, ParakeetEngine.isInstalled(at: dir) {
                ParakeetEngine(modelsDirectory: dir, expectedDigest: EnhancementCatalog.enhancement(EnhancementID.parakeet)?.external?.treeSHA256)
            }
            else { AppleSpeechEngine(kind: .speech) }
        default: AppleSpeechEngine(kind: .speech)
        }
    }
}
