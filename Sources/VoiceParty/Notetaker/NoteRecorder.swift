@preconcurrency import AVFoundation
import CoreAudio
import Foundation
import VoicePartyCore
import VoicePartyEngines

/// The Notetaker's microphone ("You"), separate from dictation's so you can still dictate during a meeting.
/// Delivers 16 kHz mono samples on the audio thread.
final class NoteMicCapture: @unchecked Sendable {
    private let engine = AVAudioEngine()
    private let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
    private let lock = NSLock()
    private var deviceUID: String?
    private var onSamples: (@Sendable ([Float]) -> Void)?
    private var observer: NSObjectProtocol?

    func start(deviceUID: String?, onSamples: @escaping @Sendable ([Float]) -> Void) throws {
        lock.withLock {
            self.deviceUID = deviceUID
            self.onSamples = onSamples
        }
        try startEngine()
        // AirPods connecting, a mic unplugged: macOS stops the engine. Start again on whatever is there now,
        // rather than recording silence for the rest of the meeting.
        observer = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil) { [weak self] _ in
            self?.restart()
        }
    }

    private func startEngine() throws {
        let (uid, deliver) = lock.withLock { (deviceUID, onSamples) }
        guard let deliver else { return }
        let input = engine.inputNode
        if let deviceID = uid.flatMap(MicrophoneManager.deviceID(forUID:)) ?? MicrophoneManager.preferredInputDeviceID(),
           let unit = input.audioUnit {
            var id = deviceID
            AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &id, UInt32(MemoryLayout<AudioDeviceID>.size))
        }
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, let converter = BufferConverter(from: format, to: target) else { throw AudioCapture.CaptureError.noInput }
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { buffer, _ in
            guard let converted = converter.convert(buffer), let channel = converted.floatChannelData?[0] else { return }
            deliver(Array(UnsafeBufferPointer(start: channel, count: Int(converted.frameLength))))
        }
        engine.prepare()
        try engine.start()
    }

    private func restart() {
        guard lock.withLock({ onSamples != nil }) else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        try? startEngine()
    }

    func stop() {
        lock.withLock { onSamples = nil }
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
    }
}

/// One side of the meeting: cuts its audio into chunks at pauses (for transcription while the meeting goes
/// on) and streams it to a file on disk (so long meetings don't live in memory).
final class NoteSideRecorder: @unchecked Sendable {
    let speaker: NoteSegment.Speaker
    let fileURL: URL?
    private let lock = NSLock()
    private var chunker = SpeechChunker.meeting
    private var file: AVAudioFile?
    private let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
    private let onChunk: @Sendable (NoteSegment.Speaker, SpeechChunker.Chunk) -> Void
    /// Seconds of audio louder than a whisper in the last minute (for "Notetaker isn't hearing you").
    private(set) var lastSoundAt = Date()

    /// `fileURL` nil: chunk only, don't save the audio (re-transcribing a recording that's already on disk).
    init(speaker: NoteSegment.Speaker, fileURL: URL?, onChunk: @escaping @Sendable (NoteSegment.Speaker, SpeechChunker.Chunk) -> Void) {
        self.speaker = speaker
        self.fileURL = fileURL
        self.onChunk = onChunk
        file = fileURL.flatMap { try? AVAudioFile(forWriting: $0, settings: format.settings, commonFormat: .pcmFormatFloat32, interleaved: false) }
    }

    func receive(_ samples: [Float]) {
        let chunks: [SpeechChunker.Chunk] = lock.withLock {
            if let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)), let channel = buffer.floatChannelData?[0] {
                samples.withUnsafeBufferPointer { channel.update(from: $0.baseAddress!, count: samples.count) }
                buffer.frameLength = AVAudioFrameCount(samples.count)
                try? file?.write(from: buffer)
            }
            if SpeechChunker.rms(samples[...]) > 0.01 { lastSoundAt = Date() }
            return chunker.append(samples)
        }
        chunks.forEach { onChunk(speaker, $0) }
    }

    /// Hands over the last piece and closes the file.
    func finish() {
        let last: SpeechChunker.Chunk? = lock.withLock {
            file = nil // closes it
            return chunker.flush()
        }
        if let last { onChunk(speaker, last) }
    }
}

/// Transcribes chunks one at a time, in order, with the dictation engine (Parakeet or Apple's). Chunks are
/// queued synchronously from the audio threads; `finish()` waits for the last one.
final class NoteTranscriber: @unchecked Sendable {
    private let continuation: AsyncStream<(SpeechChunker.Chunk, NoteSegment.Speaker)>.Continuation
    private let worker: Task<[NoteSegment], Never>

    /// `onSegment`: each transcribed piece as it's ready (the note is saved as it goes, so a crash loses little).
    init(engine: any TranscriptionEngine, vocabulary: [String], onSegment: (@Sendable (NoteSegment) -> Void)? = nil) {
        let (stream, continuation) = AsyncStream.makeStream(of: (SpeechChunker.Chunk, NoteSegment.Speaker).self)
        self.continuation = continuation
        worker = Task.detached(priority: .utility) {
            var segments: [NoteSegment] = []
            for await (chunk, speaker) in stream {
                // A recognizer call that never returns mustn't hold up the rest of the meeting.
                let limit = Duration.seconds(max(30, chunk.duration * 4))
                let result = await Deadline.value(within: limit) {
                    await Self.transcribe(chunk, speaker: speaker, engine: engine, vocabulary: vocabulary)
                }
                if let segment = result ?? nil {
                    segments.append(segment)
                    onSegment?(segment)
                }
            }
            return segments
        }
    }

    func enqueue(_ chunk: SpeechChunker.Chunk, speaker: NoteSegment.Speaker) {
        guard chunk.hasSpeech else { return } // recognizers invent words in silence
        continuation.yield((chunk, speaker))
    }

    /// Everything transcribed, once the queue is empty.
    func finish() async -> [NoteSegment] {
        continuation.finish()
        return await worker.value
    }

    private static func transcribe(_ chunk: SpeechChunker.Chunk, speaker: NoteSegment.Speaker, engine: any TranscriptionEngine,
                                   vocabulary: [String]) async -> NoteSegment? {
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(chunk.samples.count)),
              let channel = buffer.floatChannelData?[0] else { return nil }
        chunk.samples.withUnsafeBufferPointer { channel.update(from: $0.baseAddress!, count: chunk.samples.count) }
        buffer.frameLength = AVAudioFrameCount(chunk.samples.count)
        do {
            let session = try await engine.makeSession(vocabulary: vocabulary, naturalFormat: format)
            if let converter = BufferConverter(from: format, to: session.audioFormat), let converted = converter.convert(buffer) {
                session.append(converted)
            }
            let text = try await session.finish().trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? nil : NoteSegment(speaker: speaker, start: chunk.speechStart, end: chunk.start + chunk.duration, text: text)
        } catch {
            return nil // one chunk failing shouldn't lose the meeting; its audio is still in the file
        }
    }
}
