import CoreAudio
import Foundation
import VoicePartyCore

/// Which call apps are using the microphone right now, from Core Audio's per-process state (no screen
/// reading, no permissions).
enum CallWatch {
    /// Every call app's audio processes: whether each is recording from the mic and playing sound.
    static func callAudio() -> [CallDetector.AudioUse] {
        processObjects().compactMap { process in
            guard let bundleID = bundleID(of: process), let app = CallDetector.appName(forBundleID: bundleID) else { return nil }
            return CallDetector.AudioUse(app: app, process: pid(of: process), input: isRunning(process, kAudioProcessPropertyIsRunningInput),
                                         output: isRunning(process, kAudioProcessPropertyIsRunningOutput))
        }
    }

    static func callAppsUsingMic() -> Set<String> { Set(callAudio().filter(\.input).map(\.app)) }

    /// Every process Core Audio knows, with its bundle ID (to record only a call app's audio).
    static func audioProcesses() -> [(bundleID: String, id: UInt32)] {
        processObjects().compactMap { process in bundleID(of: process).map { ($0, process) } }
    }

    private static func processObjects() -> [AudioObjectID] {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyProcessObjectList,
                                                 mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        var processes = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &processes) == noErr else { return [] }
        return processes
    }

    private static func isRunning(_ process: AudioObjectID, _ selector: AudioObjectPropertySelector) -> Bool {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var running: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(process, &address, 0, nil, &size, &running) == noErr && running != 0
    }

    private static func pid(of process: AudioObjectID) -> Int32 {
        var address = AudioObjectPropertyAddress(mSelector: kAudioProcessPropertyPID, mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var pid: pid_t = 0
        var size = UInt32(MemoryLayout<pid_t>.size)
        return AudioObjectGetPropertyData(process, &address, 0, nil, &size, &pid) == noErr ? pid : -1
    }

    private static func bundleID(of process: AudioObjectID) -> String? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioProcessPropertyBundleID, mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(process, &address, 0, nil, &size, &value) == noErr, let id = value?.takeRetainedValue() else { return nil }
        return id as String
    }
}
