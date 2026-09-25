import AppKit

/// Short synthesized cues (no bundled audio assets, so nothing to license).
@MainActor
final class SoundPlayer {
    enum Cue: CaseIterable {
        case start, stop, lock, cancel, error
    }

    var isEnabled = true
    private var sounds: [Cue: NSSound] = [:]

    init() {
        for cue in Cue.allCases {
            if let sound = NSSound(data: Self.render(cue)) {
                sound.volume = 0.35
                sounds[cue] = sound
            }
        }
    }

    func play(_ cue: Cue) {
        guard isEnabled, let sound = sounds[cue] else { return }
        sound.stop()
        sound.play()
    }

    /// Soft sine blips: (frequency Hz, start s, length s).
    private static func notes(for cue: Cue) -> [(Double, Double, Double)] {
        switch cue {
        case .start: [(587.33, 0, 0.09), (880, 0.07, 0.14)]
        case .stop: [(880, 0, 0.09), (659.25, 0.07, 0.14)]
        case .lock: [(659.25, 0, 0.07), (880, 0.06, 0.07), (1174.66, 0.12, 0.14)]
        case .cancel: [(523.25, 0, 0.1), (392, 0.08, 0.16)]
        case .error: [(329.63, 0, 0.14), (261.63, 0.12, 0.22)]
        }
    }

    private static func render(_ cue: Cue) -> Data {
        let rate = 44_100.0
        let notes = notes(for: cue)
        let length = notes.map { $0.1 + $0.2 }.max() ?? 0.2
        let count = Int(length * rate)
        var samples = [Float](repeating: 0, count: count)
        for (freq, start, dur) in notes {
            let first = Int(start * rate), n = Int(dur * rate)
            for i in 0..<n where first + i < count {
                let t = Double(i) / rate
                let attack = min(1, t / 0.006)
                let decay = exp(-t * 18)
                let tone = sin(2 * .pi * freq * t) + 0.25 * sin(4 * .pi * freq * t)
                samples[first + i] += Float(tone * attack * decay * 0.4)
            }
        }
        return wav(samples, sampleRate: Int(rate))
    }

    private static func wav(_ samples: [Float], sampleRate: Int) -> Data {
        var data = Data()
        func append<T: FixedWidthInteger>(_ value: T) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        let byteCount = samples.count * 2
        data.append(contentsOf: Array("RIFF".utf8)); append(UInt32(36 + byteCount))
        data.append(contentsOf: Array("WAVE".utf8)); data.append(contentsOf: Array("fmt ".utf8))
        append(UInt32(16)); append(UInt16(1)); append(UInt16(1)); append(UInt32(sampleRate))
        append(UInt32(sampleRate * 2)); append(UInt16(2)); append(UInt16(16))
        data.append(contentsOf: Array("data".utf8)); append(UInt32(byteCount))
        for s in samples { append(Int16(max(-1, min(1, s)) * Float(Int16.max))) }
        return data
    }
}
