import CoreAudio
import Foundation
import VoicePartyCore

/// Which call apps are using the microphone right now, from Core Audio's per-process state (no screen
/// reading, no permissions).
enum CallWatch {
    static func callAppsUsingMic() -> Set<String> {
        var apps = Set<String>()
        for process in processObjects() where isRunningInput(process) {
            if let bundleID = bundleID(of: process), let app = CallDetector.appName(forBundleID: bundleID) { apps.insert(app) }
        }
        return apps
    }

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

    private static func isRunningInput(_ process: AudioObjectID) -> Bool {
        var address = AudioObjectPropertyAddress(mSelector: kAudioProcessPropertyIsRunningInput, mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var running: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(process, &address, 0, nil, &size, &running) == noErr && running != 0
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
