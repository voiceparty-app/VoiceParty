@preconcurrency import AVFoundation
import Foundation

/// Converts audio buffers (e.g. 48 kHz stereo mic input) into the format a speech engine wants.
/// `SpeechAnalyzer` does not resample on its own.
public final class BufferConverter: @unchecked Sendable {
    public let inputFormat: AVAudioFormat
    public let outputFormat: AVAudioFormat
    private let converter: AVAudioConverter

    public init?(from input: AVAudioFormat, to output: AVAudioFormat) {
        guard let converter = AVAudioConverter(from: input, to: output) else { return nil }
        converter.primeMethod = .none
        inputFormat = input
        outputFormat = output
        self.converter = converter
    }

    public func convert(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        if inputFormat == outputFormat { return Self.copy(buffer) }
        let ratio = outputFormat.sampleRate / inputFormat.sampleRate
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 32
        guard let out = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else { return nil }
        final class Once: @unchecked Sendable { var supplied = false }
        let once = Once()
        var error: NSError?
        let status = converter.convert(to: out, error: &error) { _, inputStatus in
            if once.supplied {
                inputStatus.pointee = .noDataNow
                return nil
            }
            once.supplied = true
            inputStatus.pointee = .haveData
            return buffer
        }
        guard status != .error, error == nil, out.frameLength > 0 else { return nil }
        return out
    }

    /// Tap buffers are reused by AVAudioEngine; copy before handing them to another thread.
    public static func copy(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let out = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: buffer.frameLength) else { return nil }
        out.frameLength = buffer.frameLength
        let srcBuffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: buffer.audioBufferList))
        let dstBuffers = UnsafeMutableAudioBufferListPointer(out.mutableAudioBufferList)
        for (s, d) in zip(srcBuffers, dstBuffers) {
            if let sd = s.mData, let dd = d.mData { memcpy(dd, sd, Int(min(s.mDataByteSize, d.mDataByteSize))) }
        }
        return out
    }
}

/// RMS level of a buffer in 0…1 (roughly perceptual), for the waveform.
public func audioLevel(_ buffer: AVAudioPCMBuffer) -> Float {
    let frames = Int(buffer.frameLength)
    guard frames > 0 else { return 0 }
    var sum: Float = 0
    if let data = buffer.floatChannelData?[0] {
        for i in 0..<frames { sum += data[i] * data[i] }
    } else if let data = buffer.int16ChannelData?[0] {
        for i in 0..<frames { let v = Float(data[i]) / 32768; sum += v * v }
    } else {
        return 0
    }
    let rms = sqrt(sum / Float(frames))
    let db = 20 * log10(max(rms, 1e-6))
    return max(0, min(1, (db + 55) / 45))
}
