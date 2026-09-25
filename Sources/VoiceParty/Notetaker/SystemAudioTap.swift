@preconcurrency import AVFoundation
import CoreAudio
import Foundation
import VoicePartyEngines

/// Records what the Mac plays (the other people on a call) with a Core Audio process tap: private, not
/// muting anything, excluding VoiceParty's own sounds. macOS asks once for "System Audio Recording"
/// (NSAudioCaptureUsageDescription). Delivers 16 kHz mono samples on an audio queue.
final class SystemAudioTap: @unchecked Sendable {
    enum TapError: LocalizedError {
        case unavailable(String, OSStatus)
        var errorDescription: String? {
            switch self {
            case .unavailable(let step, let status): "Couldn't capture the computer's audio (\(step), \(status))."
            }
        }
    }

    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private let queue = DispatchQueue(label: "dev.voiceparty.notetaker.system-audio", qos: .userInitiated)
    private var converter: BufferConverter?
    private let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!

    /// Starts capturing; `onSamples` gets 16 kHz mono audio on a background queue. `onlyProcesses`: record just
    /// these apps' audio (a detected call); nil = everything the Mac plays except VoiceParty itself.
    func start(onlyProcesses: [AudioObjectID]? = nil, onSamples: @escaping @Sendable ([Float]) -> Void) throws {
        try build(onlyProcesses: onlyProcesses, onSamples: onSamples)
        // The private device is built around the current output (speakers, AirPods…): when that changes,
        // rebuild it so the other side of the call keeps being recorded.
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                                 mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            guard let self, self.isRunning else { return }
            self.teardown()
            try? self.build(onlyProcesses: onlyProcesses, onSamples: onSamples)
        }
        if AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, queue, listener) == noErr {
            outputListener = listener
        }
        isRunning = true
    }

    private var isRunning = false
    private var outputListener: AudioObjectPropertyListenerBlock?

    private func build(onlyProcesses: [AudioObjectID]?, onSamples: @escaping @Sendable ([Float]) -> Void) throws {
        let description = onlyProcesses.map { CATapDescription(monoMixdownOfProcesses: $0) }
            ?? CATapDescription(monoGlobalTapButExcludeProcesses: Self.ownProcessObject().map { [$0] } ?? [])
        description.uuid = UUID()
        description.name = "VoiceParty Notetaker"
        description.isPrivate = true
        description.muteBehavior = .unmuted
        var status = AudioHardwareCreateProcessTap(description, &tapID)
        guard status == noErr else { throw TapError.unavailable("tap", status) }

        // The tap is read through a private aggregate device built around the current output device.
        let output = try Self.defaultOutputUID()
        let aggregate: [String: Any] = [
            kAudioAggregateDeviceNameKey: "VoiceParty Notetaker",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: output,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: output]],
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapDriftCompensationKey: true, kAudioSubTapUIDKey: description.uuid.uuidString]],
        ]
        status = AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &aggregateID)
        guard status == noErr else { teardown(); throw TapError.unavailable("aggregate device", status) }

        var streamDescription = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var address = AudioObjectPropertyAddress(mSelector: kAudioTapPropertyFormat, mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        status = AudioObjectGetPropertyData(tapID, &address, 0, nil, &size, &streamDescription)
        guard status == noErr, let format = AVAudioFormat(streamDescription: &streamDescription) else {
            teardown(); throw TapError.unavailable("format", status)
        }
        converter = BufferConverter(from: format, to: target)

        status = AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, queue) { [weak self] _, input, _, _, _ in
            guard let self, let buffer = AVAudioPCMBuffer(pcmFormat: format, bufferListNoCopy: input, deallocator: nil),
                  let converted = self.converter?.convert(buffer), let channel = converted.floatChannelData?[0] else { return }
            onSamples(Array(UnsafeBufferPointer(start: channel, count: Int(converted.frameLength))))
        }
        guard status == noErr else { teardown(); throw TapError.unavailable("io proc", status) }
        status = AudioDeviceStart(aggregateID, procID)
        guard status == noErr else { teardown(); throw TapError.unavailable("start", status) }
    }

    func stop() {
        isRunning = false
        if let outputListener {
            var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                                     mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, queue, outputListener)
        }
        outputListener = nil
        teardown()
    }

    private func teardown() {
        if aggregateID != kAudioObjectUnknown {
            if let procID {
                AudioDeviceStop(aggregateID, procID)
                AudioDeviceDestroyIOProcID(aggregateID, procID)
            }
            AudioHardwareDestroyAggregateDevice(aggregateID)
        }
        if tapID != kAudioObjectUnknown { AudioHardwareDestroyProcessTap(tapID) }
        procID = nil
        aggregateID = AudioObjectID(kAudioObjectUnknown)
        tapID = AudioObjectID(kAudioObjectUnknown)
    }

    deinit { stop() }

    /// VoiceParty's own Core Audio process object (its sounds are left out of the recording).
    private static func ownProcessObject() -> AudioObjectID? {
        var pid = ProcessInfo.processInfo.processIdentifier
        var object = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
                                                 mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address,
                                                UInt32(MemoryLayout<pid_t>.size), &pid, &size, &object)
        return status == noErr && object != kAudioObjectUnknown ? object : nil
    }

    private static func defaultOutputUID() throws -> String {
        var device = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultSystemOutputDevice,
                                                 mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device)
        guard status == noErr else { throw TapError.unavailable("output device", status) }
        var uid: Unmanaged<CFString>?
        size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        address.mSelector = kAudioDevicePropertyDeviceUID
        status = AudioObjectGetPropertyData(device, &address, 0, nil, &size, &uid)
        guard status == noErr, let value = uid?.takeRetainedValue() else { throw TapError.unavailable("output uid", status) }
        return value as String
    }
}
