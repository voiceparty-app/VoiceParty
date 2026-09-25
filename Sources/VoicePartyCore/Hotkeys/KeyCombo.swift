import Foundation

/// One physical key, modifier, or mouse button in a shortcut.
///
/// Generic modifiers (`.control`) match either side; sided ones (`.rightOption`) match only that key.
public enum KeyToken: Hashable, Sendable, Comparable {
    case fn
    case control, option, command, shift
    case leftControl, rightControl, leftOption, rightOption, leftCommand, rightCommand, leftShift, rightShift
    /// macOS virtual key code (kVK_*).
    case key(UInt16)
    /// Mouse button number as reported by `otherMouseDown` (2 = middle).
    case mouse(Int)

    public var isModifier: Bool {
        switch self {
        case .key, .mouse: false
        default: true
        }
    }

    /// Side-agnostic form, used when matching generic bindings.
    public var generic: KeyToken {
        switch self {
        case .leftControl, .rightControl: .control
        case .leftOption, .rightOption: .option
        case .leftCommand, .rightCommand: .command
        case .leftShift, .rightShift: .shift
        default: self
        }
    }

    /// Whether this (binding) token is satisfied by a physically pressed token.
    public func matches(pressed: KeyToken) -> Bool {
        self == pressed || self == pressed.generic
    }

    /// The physical key for a modifier key code, if it is one.
    public static func modifier(forKeyCode code: UInt16) -> KeyToken? {
        switch code {
        case KeyCode.function: .fn
        case KeyCode.leftControl: .leftControl
        case KeyCode.rightControl: .rightControl
        case KeyCode.leftOption: .leftOption
        case KeyCode.rightOption: .rightOption
        case KeyCode.leftCommand: .leftCommand
        case KeyCode.rightCommand: .rightCommand
        case KeyCode.leftShift: .leftShift
        case KeyCode.rightShift: .rightShift
        default: nil
        }
    }

    // MARK: String form ("fn", "ropt", "key:49", "mouse:2")

    public var rawValue: String {
        switch self {
        case .fn: "fn"
        case .control: "ctrl"
        case .option: "opt"
        case .command: "cmd"
        case .shift: "shift"
        case .leftControl: "lctrl"
        case .rightControl: "rctrl"
        case .leftOption: "lopt"
        case .rightOption: "ropt"
        case .leftCommand: "lcmd"
        case .rightCommand: "rcmd"
        case .leftShift: "lshift"
        case .rightShift: "rshift"
        case .key(let code): "key:\(code)"
        case .mouse(let button): "mouse:\(button)"
        }
    }

    public init?(rawValue: String) {
        switch rawValue {
        case "fn": self = .fn
        case "ctrl": self = .control
        case "opt": self = .option
        case "cmd": self = .command
        case "shift": self = .shift
        case "lctrl": self = .leftControl
        case "rctrl": self = .rightControl
        case "lopt": self = .leftOption
        case "ropt": self = .rightOption
        case "lcmd": self = .leftCommand
        case "rcmd": self = .rightCommand
        case "lshift": self = .leftShift
        case "rshift": self = .rightShift
        default:
            if rawValue.hasPrefix("key:"), let code = UInt16(rawValue.dropFirst(4)) {
                self = .key(code)
            } else if rawValue.hasPrefix("mouse:"), let button = Int(rawValue.dropFirst(6)) {
                self = .mouse(button)
            } else {
                return nil
            }
        }
    }

    /// Display order: fn, ctrl, opt, shift, cmd, then keys, then mouse buttons.
    private var sortRank: Int {
        switch self {
        case .fn: 0
        case .control, .leftControl, .rightControl: 1
        case .option, .leftOption, .rightOption: 2
        case .shift, .leftShift, .rightShift: 3
        case .command, .leftCommand, .rightCommand: 4
        case .key: 5
        case .mouse: 6
        }
    }

    public static func < (lhs: KeyToken, rhs: KeyToken) -> Bool {
        if lhs.sortRank != rhs.sortRank { return lhs.sortRank < rhs.sortRank }
        return lhs.rawValue < rhs.rawValue
    }
}

/// A shortcut: the exact set of keys/buttons that must be held together.
public struct KeyCombo: Hashable, Sendable, Codable, CustomStringConvertible {
    public var tokens: Set<KeyToken>

    public init(_ tokens: Set<KeyToken>) { self.tokens = tokens }
    public init(_ tokens: KeyToken...) { self.tokens = Set(tokens) }

    public var sortedTokens: [KeyToken] { tokens.sorted() }
    public var isModifierOnly: Bool { !tokens.isEmpty && tokens.allSatisfy(\.isModifier) }
    public var description: String { sortedTokens.map(\.rawValue).joined(separator: "+") }

    /// True when the physically pressed set is exactly this combo (each pressed key covers one binding token).
    public func isSatisfied(by pressed: Set<KeyToken>) -> Bool {
        guard pressed.count == tokens.count else { return false }
        var remaining = pressed
        for token in tokens {
            guard let hit = remaining.first(where: { token.matches(pressed: $0) }) else { return false }
            remaining.remove(hit)
        }
        return remaining.isEmpty
    }

    /// True when every pressed key belongs to this combo (the user may still be building it).
    public func isPrefix(of pressed: Set<KeyToken>) -> Bool {
        pressed.allSatisfy { p in tokens.contains { $0.matches(pressed: p) } }
    }

    /// True when all of this combo's keys are among the pressed keys (extra keys allowed).
    public func isContained(in pressed: Set<KeyToken>) -> Bool {
        var remaining = pressed
        for token in tokens {
            guard let hit = remaining.first(where: { token.matches(pressed: $0) }) else { return false }
            remaining.remove(hit)
        }
        return true
    }

    /// Parses "fn+key:49"; nil when any part is unknown.
    public init?(string raw: String) {
        let parts = raw.split(separator: "+").map(String.init)
        let parsed = parts.compactMap(KeyToken.init(rawValue:))
        guard parsed.count == parts.count, !parsed.isEmpty else { return nil }
        tokens = Set(parsed)
    }

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        let parts = raw.split(separator: "+").map(String.init)
        let parsed = parts.compactMap(KeyToken.init(rawValue:))
        guard parsed.count == parts.count, !parsed.isEmpty else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Bad key combo \(raw)"))
        }
        tokens = Set(parsed)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(description)
    }
}

/// macOS virtual key codes used by default bindings (from HIToolbox Events.h).
public enum KeyCode {
    public static let returnKey: UInt16 = 36
    public static let tab: UInt16 = 48
    public static let space: UInt16 = 49
    public static let delete: UInt16 = 51
    public static let escape: UInt16 = 53
    public static let rightCommand: UInt16 = 54
    public static let leftCommand: UInt16 = 55
    public static let leftShift: UInt16 = 56
    public static let capsLock: UInt16 = 57
    public static let leftOption: UInt16 = 58
    public static let leftControl: UInt16 = 59
    public static let rightShift: UInt16 = 60
    public static let rightOption: UInt16 = 61
    public static let rightControl: UInt16 = 62
    public static let function: UInt16 = 63
    public static let a: UInt16 = 0
    public static let c: UInt16 = 8
    public static let v: UInt16 = 9
    public static let o: UInt16 = 31
    public static let m: UInt16 = 46
    public static let z: UInt16 = 6
    public static let q: UInt16 = 12
    public static let w: UInt16 = 13
    public static let tabKey: UInt16 = 48
    /// Top-row digits 1…9.
    public static let digits: [UInt16] = [18, 19, 20, 21, 23, 22, 26, 28, 25]
}
