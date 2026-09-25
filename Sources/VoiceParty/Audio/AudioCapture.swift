@preconcurrency import AVFoundation
import CoreAudio
import Foundation
import VoicePartyEngines

/// Microphone capture. Buffers are copied off the tap, routed to the transcription session once it
/// exists (audio from the first few hundred ms is queued, so the first word isn't lost), and kept
/// as 16 kHz mono for "Undo" after cancel, retry, and saving.
final class AudioCapture: @unchecked Sendable {
    private let engine = AVAudioEngine()
    /// CoreAudio calls (choosing the device, starting the engine) can block for seconds while a Bluetooth
    /// device renegotiates; they run here, never on the main thread, so hotkeys and UI stay responsive.
    private let queue = DispatchQueue(label: "dev.voiceparty.audio", qos: .userInteractive)
    private let lock = NSLock()
    /// The mic in use (for restarting on it after an audio configuration change).
    private var deviceUID: String?
    /// The format the transcription session wants (to rebuild its converter after a restart).
    private var sinkFormat: AVAudioFormat?
    private var configurationObserver: NSObjectProtocol?
    private var pending: [AVAudioPCMBuffer] = []
    private var sink: ((AVAudioPCMBuffer) -> Void)?
    private var sinkConverter: BufferConverter?
    private var archiveConverter: BufferConverter?
    private var archive: [AVAudioPCMBuffer] = []
    private var speechFrames = 0
    private var totalFrames = 0
    private var recording = false
    /// Identifies the current recording so a late transcription session from an earlier one can't attach.
    private(set) var token = 0

    /// Called on the audio thread with a 0…1 level for the waveform.
    var onLevel: (@Sendable (Float) -> Void)?

    static let archiveFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!

    private(set) var inputFormat: AVAudioFormat?

    /// Seconds of audio above the speech threshold (for WPM).
    var speechDuration: Double { lock.withLock { Double(speechFrames) / Self.archiveFormat.sampleRate } }
    var duration: Double { lock.withLock { Double(totalFrames) / Self.archiveFormat.sampleRate } }

    var isAttached: Bool { lock.withLock { sink != nil } }

    init() {
        // AirPods connecting/disconnecting (or any device change) reconfigures the engine and stops it; a
        // recording in progress would silently end there. Restart on the same mic and keep going.
        configurationObserver = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine,
                                                                       queue: nil) { [weak self] _ in
            self?.queue.async { self?.restartAfterConfigurationChange() }
        }
    }

    deinit {
        if let configurationObserver { NotificationCenter.default.removeObserver(configurationObserver) }
    }

    /// Resets for a new recording (instant, on the caller's thread) and returns its token. Audio arriving
    /// before a transcription session attaches is queued, so nothing said after the key-press is lost.
    func beginRecording(deviceUID: String?) -> Int {
        lock.withLock {
            pending.removeAll()
            archive.removeAll()
            sink = nil
            sinkConverter = nil
            sinkFormat = nil
            speechFrames = 0
            totalFrames = 0
            recording = true
            self.deviceUID = deviceUID
            token += 1
            return token
        }
    }

    /// Starts the microphone off the main thread; gives up after `timeout` (a stuck device).
    func start(timeout: Duration = .seconds(2)) async throws -> AVAudioFormat {
        try await DictationController.withTimeout(timeout) { [self] in
            try await withCheckedThrowingContinuation { continuation in
                queue.async {
                    do { continuation.resume(returning: try self.configureAndStart()) } catch { continuation.resume(throwing: error) }
                }
            }
        }
    }

    /// Picks the device, installs the tap and starts the engine. Audio queue only.
    private func configureAndStart() throws -> AVAudioFormat {
        let input = engine.inputNode
        // A chosen mic, else the built-in mic (Bluetooth headsets drop to low-quality call audio and can
        // stall CoreAudio when they switch), else the system default. Always set it, so switching back works.
        let uid = lock.withLock { deviceUID }
        let deviceID = uid.flatMap(MicrophoneManager.deviceID(forUID:)) ?? MicrophoneManager.preferredInputDeviceID()
        if let deviceID, let unit = input.audioUnit {
            var id = deviceID
            AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &id, UInt32(MemoryLayout<AudioDeviceID>.size))
        }
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw CaptureError.noInput }
        let archive = BufferConverter(from: format, to: Self.archiveFormat)
        lock.withLock {
            inputFormat = format
            archiveConverter = archive
            // After a restart the input format may differ: rebuild the session's converter too.
            if let sinkFormat { sinkConverter = BufferConverter(from: format, to: sinkFormat) }
        }
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            self?.receive(buffer)
        }
        engine.prepare()
        try engine.start()
        return format
    }

    /// Audio queue: the device configuration changed mid-recording; carry on with the same mic.
    private func restartAfterConfigurationChange() {
        // Still running (e.g. the change was our own device selection at start): nothing to recover.
        guard lock.withLock({ recording }), !engine.isRunning else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        _ = try? configureAndStart()
    }

    /// Debug: what a device switch does to the engine mid-recording (it stops, then a change is posted).
    func simulateDeviceChangeForTesting() {
        queue.async { [engine] in
            engine.stop()
            NotificationCenter.default.post(name: .AVAudioEngineConfigurationChange, object: engine)
        }
    }

    func stop() {
        // Stop accepting audio now; tear the engine down on the audio queue (it can block).
        lock.withLock {
            recording = false
            sink = nil
            pending.removeAll()
        }
        queue.async { [engine] in
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
    }

    /// Starts forwarding (converted) audio to `sink`, flushing anything captured so far. Ignored if
    /// recording `token` has already ended (the caller then feeds the archived audio instead).
    @discardableResult
    func attach(token: Int, format: AVAudioFormat, sink: @escaping (AVAudioPCMBuffer) -> Void) -> Bool {
        guard let inputFormat = lock.withLock({ inputFormat }) else { return false }
        let converter = BufferConverter(from: inputFormat, to: format)
        return lock.withLock {
            guard recording, token == self.token else { return false }
            self.sink = sink
            sinkConverter = converter
            sinkFormat = format
            // Flush under the lock so live buffers can't overtake queued ones or share the converter.
            for buffer in pending {
                if let converted = converter?.convert(buffer) { sink(converted) }
            }
            pending.removeAll()
            return true
        }
    }

    /// Everything recorded, as one 16 kHz mono buffer.
    func recordedAudio() -> AVAudioPCMBuffer? {
        let chunks = lock.withLock { archive }
        return Self.concatenate(chunks)
    }

    private func receive(_ buffer: AVAudioPCMBuffer) {
        let level = audioLevel(buffer)
        onLevel?(level)
        let archived = lock.withLock { archiveConverter }?.convert(buffer)
        lock.withLock {
            guard recording else { return }
            if let archived {
                archive.append(archived)
                totalFrames += Int(archived.frameLength)
                if level > 0.18 { speechFrames += Int(archived.frameLength) }
            }
            if let sink, let converter = sinkConverter {
                if let converted = converter.convert(buffer) { sink(converted) }
            } else if let copy = BufferConverter.copy(buffer) {
                pending.append(copy)
            }
        }
    }

    static func concatenate(_ chunks: [AVAudioPCMBuffer]) -> AVAudioPCMBuffer? {
        let total = chunks.reduce(0) { $0 + Int($1.frameLength) }
        guard total > 0, let out = AVAudioPCMBuffer(pcmFormat: archiveFormat, frameCapacity: AVAudioFrameCount(total)),
              let dst = out.floatChannelData?[0] else { return nil }
        var offset = 0
        for chunk in chunks {
            guard let src = chunk.floatChannelData?[0] else { continue }
            dst.advanced(by: offset).update(from: src, count: Int(chunk.frameLength))
            offset += Int(chunk.frameLength)
        }
        out.frameLength = AVAudioFrameCount(offset)
        return out
    }

    /// Writes a 16 kHz mono buffer to a .caf file.
    static func write(_ buffer: AVAudioPCMBuffer, to url: URL) throws {
        let file = try AVAudioFile(forWriting: url, settings: archiveFormat.settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        try file.write(from: buffer)
    }

    enum CaptureError: LocalizedError {
        case noInput
        var errorDescription: String? { "No microphone input is available." }
    }
}

/// Lists input devices and maps persistent UIDs to CoreAudio device IDs.
enum MicrophoneManager {
    struct Device: Identifiable, Hashable {
        var id: String { uid }
        let uid: String
        let name: String
        let isBuiltIn: Bool
        /// Software devices (Teams/Zoom audio, BlackHole, aggregates): listed under "Show other devices".
        let isVirtual: Bool
    }

    static func inputDevices() -> [Device] {
        allDeviceIDs().compactMap { id in
            guard hasInput(id), let uid = string(id, kAudioDevicePropertyDeviceUID), let name = string(id, kAudioObjectPropertyName) else { return nil }
            let kind = transport(id)
            return Device(uid: uid, name: name, isBuiltIn: kind == kAudioDeviceTransportTypeBuiltIn,
                          isVirtual: [kAudioDeviceTransportTypeVirtual, kAudioDeviceTransportTypeAggregate,
                                      kAudioDeviceTransportTypeAutoAggregate].contains(kind))
        }
    }

    /// The built-in microphone when there is one, otherwise the system default input.
    static func preferredInputDeviceID() -> AudioDeviceID? {
        let ids = allDeviceIDs().filter(hasInput)
        return ids.first { transport($0) == kAudioDeviceTransportTypeBuiltIn } ?? defaultInputDeviceID()
    }

    static func defaultInputDeviceID() -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultInputDevice, mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var device = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device) == noErr, device != 0 else { return nil }
        return device
    }

    static func deviceID(forUID uid: String) -> AudioDeviceID? {
        allDeviceIDs().first { hasInput($0) && string($0, kAudioDevicePropertyDeviceUID) == uid }
    }

    private static func allDeviceIDs() -> [AudioDeviceID] {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids) == noErr else { return [] }
        return ids
    }

    private static func hasInput(_ id: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams, mScope: kAudioDevicePropertyScopeInput, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        return AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr && size > 0
    }

    private static func transport(_ id: AudioDeviceID) -> UInt32 {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyTransportType, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value)
        return value
    }

    private static func string(_ id: AudioDeviceID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr, let value else { return nil }
        return value.takeRetainedValue() as String
    }
}
