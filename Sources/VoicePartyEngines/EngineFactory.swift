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

    public static let parakeetUnifiedOption = Option(id: EngineID.parakeetUnified, name: "Parakeet Unified",
                                                     detail: "NVIDIA's model on the Neural Engine. The most accurate in testing.")
    public static let parakeetOption = Option(id: EngineID.parakeet, name: "Parakeet v2",
                                              detail: "The previous Parakeet model, on the Neural Engine.")

    /// Where the Parakeet enhancements keep their models (set by the app).
    nonisolated(unsafe) public static var parakeetDirectory: URL?
    nonisolated(unsafe) public static var parakeetUnifiedDirectory: URL?

    public static func makeEngine(id: String) -> any TranscriptionEngine {
        switch id {
        case EngineID.appleDictation: AppleSpeechEngine(kind: .dictation)
        case EngineID.parakeet:
            if let dir = parakeetDirectory, ParakeetEngine.isInstalled(at: dir) {
                ParakeetEngine(modelsDirectory: dir, expectedDigest: EnhancementCatalog.enhancement(EnhancementID.parakeet)?.external?.treeSHA256)
            }
            else { AppleSpeechEngine(kind: .speech) }
        case EngineID.parakeetUnified:
            if let dir = parakeetUnifiedDirectory, ParakeetUnifiedEngine.isInstalled(at: dir) {
                ParakeetUnifiedEngine(modelsDirectory: dir,
                                      expectedDigest: EnhancementCatalog.enhancement(EnhancementID.parakeetUnified)?.external?.treeSHA256)
            }
            else { AppleSpeechEngine(kind: .speech) }
        default: AppleSpeechEngine(kind: .speech)
        }
    }
}
