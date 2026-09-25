import AppKit
import Carbon.HIToolbox
import VoicePartyCore

/// Human-readable names for shortcut keys ("fn", "⌃", "Right ⌥", "Space", "V", "Middle Click").
enum KeyNames {
    static func name(_ token: KeyToken) -> String {
        switch token {
        case .fn: "fn"
        case .control: "⌃ Ctrl"
        case .option: "⌥ Opt"
        case .command: "⌘ Cmd"
        case .shift: "⇧ Shift"
        case .leftControl: "Left ⌃"
        case .rightControl: "Right ⌃"
        case .leftOption: "Left ⌥"
        case .rightOption: "Right ⌥"
        case .leftCommand: "Left ⌘"
        case .rightCommand: "Right ⌘"
        case .leftShift: "Left ⇧"
        case .rightShift: "Right ⇧"
        case .mouse(let button): button == 2 ? "Middle Click" : "Mouse \(button + 1)"
        case .key(let code): keyName(code)
        }
    }

    static func display(_ combo: KeyCombo) -> String {
        combo.sortedTokens.map(name).joined(separator: " + ")
    }

    static let special: [UInt16: String] = [
        UInt16(kVK_Space): "Space", UInt16(kVK_Return): "Return", UInt16(kVK_Escape): "esc", UInt16(kVK_Tab): "Tab",
        UInt16(kVK_Delete): "Delete", UInt16(kVK_ForwardDelete): "⌦", UInt16(kVK_LeftArrow): "←", UInt16(kVK_RightArrow): "→",
        UInt16(kVK_UpArrow): "↑", UInt16(kVK_DownArrow): "↓", UInt16(kVK_Home): "Home", UInt16(kVK_End): "End",
        UInt16(kVK_PageUp): "Page Up", UInt16(kVK_PageDown): "Page Down",
        UInt16(kVK_F1): "F1", UInt16(kVK_F2): "F2", UInt16(kVK_F3): "F3", UInt16(kVK_F4): "F4", UInt16(kVK_F5): "F5",
        UInt16(kVK_F6): "F6", UInt16(kVK_F7): "F7", UInt16(kVK_F8): "F8", UInt16(kVK_F9): "F9", UInt16(kVK_F10): "F10",
        UInt16(kVK_F11): "F11", UInt16(kVK_F12): "F12", UInt16(kVK_F13): "F13", UInt16(kVK_F14): "F14", UInt16(kVK_F15): "F15",
        UInt16(kVK_F16): "F16", UInt16(kVK_F17): "F17", UInt16(kVK_F18): "F18", UInt16(kVK_F19): "F19", UInt16(kVK_F20): "F20",
    ]

    static func keyName(_ code: UInt16) -> String {
        if let name = special[code] { return name }
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let raw = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return "Key \(code)" }
        let data = Unmanaged<CFData>.fromOpaque(raw).takeUnretainedValue() as Data
        return data.withUnsafeBytes { bytes in
            guard let layout = bytes.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else { return "Key \(code)" }
            var dead: UInt32 = 0
            var length = 0
            var chars = [UniChar](repeating: 0, count: 4)
            let status = UCKeyTranslate(layout, code, UInt16(kUCKeyActionDisplay), 0, UInt32(LMGetKbdType()),
                                        OptionBits(kUCKeyTranslateNoDeadKeysBit), &dead, 4, &length, &chars)
            guard status == noErr, length > 0 else { return "Key \(code)" }
            return String(utf16CodeUnits: chars, count: length).uppercased()
        }
    }
}
