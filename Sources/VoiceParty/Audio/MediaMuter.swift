import CoreAudio
import Foundation

/// Mutes the default output device while the mic is open, then restores it (only if we muted it).
enum MediaMuter {
    nonisolated(unsafe) private static var mutedDevice: AudioDeviceID?

    static func mute() {
        guard mutedDevice == nil, let device = defaultOutputDevice(), !isMuted(device) else { return }
        if setMute(device, true) { mutedDevice = device }
    }

    static func restore() {
        guard let device = mutedDevice else { return }
        _ = setMute(device, false)
        mutedDevice = nil
    }

    private static func defaultOutputDevice() -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                                 mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var device = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device) == noErr,
              device != 0 else { return nil }
        return device
    }

    private static func isMuted(_ device: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyMute, mScope: kAudioDevicePropertyScopeOutput,
                                                 mElement: kAudioObjectPropertyElementMain)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr && value == 1
    }

    private static func setMute(_ device: AudioDeviceID, _ mute: Bool) -> Bool {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyMute, mScope: kAudioDevicePropertyScopeOutput,
                                                 mElement: kAudioObjectPropertyElementMain)
        var value: UInt32 = mute ? 1 : 0
        return AudioObjectSetPropertyData(device, &address, 0, nil, UInt32(MemoryLayout<UInt32>.size), &value) == noErr
    }
}
