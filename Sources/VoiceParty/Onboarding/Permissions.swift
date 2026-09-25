import AppKit
import AVFoundation
import ApplicationServices

enum Permissions {
    struct State: Equatable {
        var microphone: AVAuthorizationStatus
        var accessibility: Bool

        static func current() -> State {
            State(microphone: AVCaptureDevice.authorizationStatus(for: .audio), accessibility: AXIsProcessTrusted())
        }

        var allGranted: Bool { microphone == .authorized && accessibility }
    }

    static func requestMicrophone() async -> Bool {
        await AVCaptureDevice.requestAccess(for: .audio)
    }

    /// Shows the system prompt that adds VoiceParty to the Accessibility list.
    static func promptAccessibility() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    static func openAccessibilitySettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
    }

    static func openMicrophoneSettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")
    }

    static func openKeyboardSettings() {
        open("x-apple.systempreferences:com.apple.Keyboard-Settings.extension")
    }

    static func openAppleIntelligenceSettings() {
        open("x-apple.systempreferences:com.apple.Siri-Settings.extension")
    }

    private static func open(_ string: String) {
        if let url = URL(string: string) { NSWorkspace.shared.open(url) }
    }

    /// What the Globe/fn key does on its own (0 nothing, 1 change input source, 2 emoji, 3 dictation).
    static var globeKeyUsage: Int? {
        UserDefaults(suiteName: "com.apple.HIToolbox")?.object(forKey: "AppleFnUsageType") as? Int
    }
}
