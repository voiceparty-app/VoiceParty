import Foundation

/// Cuts a long 16 kHz mono stream into pieces for the recognizer: at least `minSeconds`, cut in the first
/// pause after that (≥ `pauseSeconds` of quiet), never longer than `maxSeconds`. Chunks with no speech are
/// flagged so they're never transcribed (recognizers invent words in silence).
public struct SpeechChunker: Sendable {
    public struct Chunk: Sendable {
        /// Seconds from the start of the stream.
        public var start: TimeInterval
        public var samples: [Float]
        public var hasSpeech: Bool
        /// When speech begins in this chunk (seconds from the start of the stream).
        public var speechStart: TimeInterval
        public var duration: TimeInterval { Double(samples.count) / SpeechChunker.sampleRate }
    }

    /// For one side of a meeting: every utterance (cut at the pause after it) is its own turn.
    public static var meeting: SpeechChunker { SpeechChunker(minSeconds: 2, maxSeconds: 30, pauseSeconds: 0.8) }

    public static let sampleRate = 16_000.0
    static let frame = 320 // 20 ms
    public var minSeconds: Double
    public var maxSeconds: Double
    public var pauseSeconds: Double
    public var speechLevel: Float

    private var buffer: [Float] = []
    private var consumed = 0 // samples already emitted
    private var quietFrames = 0
    private var voicedFrames = 0
    private var analyzed = 0 // samples of `buffer` already classified
    private var firstVoiced: Int? // sample offset in `buffer` of the first speech frame

    public init(minSeconds: Double = 8, maxSeconds: Double = 30, pauseSeconds: Double = 0.5, speechLevel: Float = 0.01) {
        self.minSeconds = minSeconds
        self.maxSeconds = maxSeconds
        self.pauseSeconds = pauseSeconds
        self.speechLevel = speechLevel
    }

    public mutating func append(_ samples: [Float]) -> [Chunk] {
        buffer += samples
        var chunks: [Chunk] = []
        let minSamples = Int(minSeconds * Self.sampleRate), maxSamples = Int(maxSeconds * Self.sampleRate)
        let pauseFrames = Int(pauseSeconds * Self.sampleRate) / Self.frame
        while analyzed + Self.frame <= buffer.count {
            let rms = Self.rms(buffer[analyzed..<(analyzed + Self.frame)])
            analyzed += Self.frame
            if rms < speechLevel { quietFrames += 1 } else {
                quietFrames = 0
                voicedFrames += 1
                if firstVoiced == nil { firstVoiced = analyzed - Self.frame }
            }
            // Cut in the middle of a pause once long enough, or at the hard limit.
            if (analyzed >= minSamples && quietFrames >= pauseFrames) || analyzed >= maxSamples {
                let cut = analyzed >= maxSamples ? maxSamples : analyzed - quietFrames * Self.frame / 2
                chunks.append(emit(upTo: cut))
            }
        }
        return chunks
    }

    /// Whatever is left (end of the meeting).
    public mutating func flush() -> Chunk? {
        guard !buffer.isEmpty else { return nil }
        while analyzed + Self.frame <= buffer.count {
            if Self.rms(buffer[analyzed..<(analyzed + Self.frame)]) >= speechLevel {
                voicedFrames += 1
                if firstVoiced == nil { firstVoiced = analyzed }
            }
            analyzed += Self.frame
        }
        return emit(upTo: buffer.count)
    }

    private mutating func emit(upTo cut: Int) -> Chunk {
        let samples = Array(buffer[..<cut])
        // Speech if at least ~0.3 s of it (a cough or a click isn't worth transcribing).
        let chunk = Chunk(start: Double(consumed) / Self.sampleRate, samples: samples, hasSpeech: voicedFrames >= 15,
                          speechStart: Double(consumed + min(firstVoiced ?? 0, cut)) / Self.sampleRate)
        consumed += cut
        firstVoiced = firstVoiced.map { $0 >= cut ? $0 - cut : nil } ?? nil
        buffer.removeFirst(cut)
        analyzed = max(0, analyzed - cut)
        quietFrames = 0
        voicedFrames = 0
        return chunk
    }

    public static func rms(_ samples: ArraySlice<Float>) -> Float {
        guard !samples.isEmpty else { return 0 }
        return (samples.reduce(0) { $0 + $1 * $1 } / Float(samples.count)).squareRoot()
    }
}
