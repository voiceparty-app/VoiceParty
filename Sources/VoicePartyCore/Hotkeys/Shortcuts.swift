import Foundation

/// Every action that can be bound to a shortcut.
public enum HotkeyActionID: String, Codable, CaseIterable, Sendable, CodingKeyRepresentable {
    case pushToTalk, handsFree, commandMode
    case pasteLastTranscript, copyLastTranscript
    case cancel, pressEnter, viewTransformChanges
    case transform1, transform2, transform3, transform4, transform5, transform6, transform7, transform8, transform9

    public var displayName: String {
        switch self {
        case .pushToTalk: "Push to talk"
        case .handsFree: "Hands-free mode"
        case .commandMode: "Command Mode"
        case .pasteLastTranscript: "Paste last transcript"
        case .copyLastTranscript: "Copy last transcript"
        case .cancel: "Cancel"
        case .pressEnter: "Press Enter"
        case .viewTransformChanges: "Show transform changes"
        default: "Transform \(transformSlot ?? 0)"
        }
    }

    public var summary: String {
        switch self {
        case .pushToTalk: "Hold the keys while you talk; let go to insert the text"
        case .handsFree: "Press once to start talking and again to stop, without holding"
        case .commandMode: "Select text and tell VoiceParty how to change it"
        case .pasteLastTranscript: "Insert your most recent dictation again"
        case .copyLastTranscript: "Put your most recent dictation on the clipboard"
        case .cancel: "Stop listening without inserting anything, or close a message"
        case .pressEnter: "Press Return from a mouse button or another key, e.g. to send a chat message"
        case .viewTransformChanges: "Compare the text before and after the last transform"
        default: "Apply this transform to the selected text"
        }
    }

    /// Hold actions record while the combo is held.
    public var isHold: Bool { self == .pushToTalk || self == .commandMode }

    public var transformSlot: Int? {
        switch self {
        case .transform1: 1
        case .transform2: 2
        case .transform3: 3
        case .transform4: 4
        case .transform5: 5
        case .transform6: 6
        case .transform7: 7
        case .transform8: 8
        case .transform9: 9
        default: nil
        }
    }

    public static func transform(slot: Int) -> HotkeyActionID? {
        allCases.first { $0.transformSlot == slot }
    }
}

public struct ShortcutSettings: Codable, Equatable, Sendable {
    public var bindings: [HotkeyActionID: [KeyCombo]]
    /// Double-tapping the push-to-talk key starts hands-free mode.
    public var doubleTapForHandsFree: Bool

    public static let maxBindingsPerAction = 4
    public static let maxKeysPerCombo = 3

    public init(bindings: [HotkeyActionID: [KeyCombo]], doubleTapForHandsFree: Bool = true) {
        self.bindings = bindings
        self.doubleTapForHandsFree = doubleTapForHandsFree
    }

    public func combos(for action: HotkeyActionID) -> [KeyCombo] { bindings[action] ?? [] }

    /// The defaults, built around one primary key (fn on Apple keyboards).
    public static func defaults(primary: KeyToken = .fn) -> ShortcutSettings {
        var bindings: [HotkeyActionID: [KeyCombo]] = [
            .pushToTalk: [KeyCombo(primary)],
            .handsFree: [KeyCombo(primary, .key(KeyCode.space))],
            .commandMode: [KeyCombo(primary, primary.generic == .control ? .option : .control)],
            .pasteLastTranscript: [KeyCombo(.control, .command, .key(KeyCode.v))],
            .copyLastTranscript: [KeyCombo(.control, .command, .key(KeyCode.c))],
            .cancel: [KeyCombo(.key(KeyCode.escape))],
            .viewTransformChanges: [KeyCombo(.option, .key(KeyCode.o))],
            .pressEnter: [],
        ]
        for slot in 1...2 {
            bindings[.transform(slot: slot)!] = [KeyCombo(.option, .key(KeyCode.digits[slot - 1]))]
        }
        return ShortcutSettings(bindings: bindings)
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // Decode entry by entry so one unknown action or bad combo doesn't reset every shortcut.
        var bindings = Self.defaults().bindings
        if let raw = try? c.decodeIfPresent([String: [String]].self, forKey: .bindings) {
            for (key, combos) in raw {
                guard let action = HotkeyActionID(rawValue: key) else { continue }
                bindings[action] = combos.compactMap { KeyCombo(string: $0) }
            }
        }
        self.bindings = bindings
        doubleTapForHandsFree = try c.decodeIfPresent(Bool.self, forKey: .doubleTapForHandsFree) ?? true
    }
}

public enum ShortcutIssue: Equatable, Sendable {
    case empty
    case tooManyKeys
    case mixesSides
    case needsModifier
    case reservedBySystem
    case conflicts(with: HotkeyActionID)

    public var message: String {
        switch self {
        case .empty: "Press a key combination."
        case .tooManyKeys: "Use at most \(ShortcutSettings.maxKeysPerCombo) keys."
        case .mixesSides: "Can't combine the left and right version of the same modifier."
        case .needsModifier: "Add a modifier key (fn, ⌃, ⌥, ⌘ or ⇧)."
        case .reservedBySystem: "This shortcut is reserved by macOS or common apps."
        case .conflicts(let other): "Already used by \(other.displayName)."
        }
    }
}

public enum ShortcutValidator {
    /// F1…F20 key codes: allowed on their own.
    static let functionKeys: Set<UInt16> = [122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111, 105, 107, 113, 106, 64, 79, 80, 90]

    static let reserved: [KeyCombo] = {
        let cmdKeys: [UInt16] = [KeyCode.c, KeyCode.v, 7 /* x */, KeyCode.z, KeyCode.a, 1 /* s */, KeyCode.q, KeyCode.w, 17 /* t */, 45 /* n */, KeyCode.tab, KeyCode.space]
        var combos = cmdKeys.map { KeyCombo(.command, .key($0)) }
        combos.append(KeyCombo(.command, .shift, .key(KeyCode.z)))
        combos.append(KeyCombo(.control, .key(KeyCode.space)))
        return combos
    }()

    public static func validate(_ combo: KeyCombo, for action: HotkeyActionID, in settings: ShortcutSettings) -> [ShortcutIssue] {
        var issues: [ShortcutIssue] = []
        if combo.tokens.isEmpty { return [.empty] }
        if combo.tokens.count > ShortcutSettings.maxKeysPerCombo { issues.append(.tooManyKeys) }

        let sidedPairs: [(KeyToken, KeyToken)] = [
            (.leftControl, .rightControl), (.leftOption, .rightOption), (.leftCommand, .rightCommand), (.leftShift, .rightShift),
        ]
        let sidedAndGeneric = combo.tokens.contains { token in token.generic != token && combo.tokens.contains(token.generic) }
        if sidedAndGeneric || sidedPairs.contains(where: { combo.tokens.contains($0.0) && combo.tokens.contains($0.1) }) {
            issues.append(.mixesSides)
        }

        let keys = combo.tokens.compactMap { if case .key(let code) = $0 { code } else { nil } }
        let hasModifier = combo.tokens.contains(where: \.isModifier)
        let hasMouse = combo.tokens.contains { if case .mouse = $0 { true } else { false } }
        if !hasModifier && !hasMouse {
            let standaloneOK = keys.count == 1 && (functionKeys.contains(keys[0]) || (action == .cancel && keys[0] == KeyCode.escape))
            if !standaloneOK { issues.append(.needsModifier) }
        }

        if reserved.contains(where: { $0.tokens == combo.tokens }) { issues.append(.reservedBySystem) }

        for (other, combos) in settings.bindings where other != action {
            if combos.contains(where: { $0.tokens == combo.tokens }) {
                issues.append(.conflicts(with: other))
            }
        }
        return issues
    }
}
