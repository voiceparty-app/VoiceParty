import Foundation

/// A key, modifier, or mouse button going down or up.
public struct KeyEvent: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        case down(KeyToken, isRepeat: Bool)
        case up(KeyToken)
    }

    public var kind: Kind
    public var time: TimeInterval
    /// Physical modifiers held right after this event (sided tokens and `.fn`), used to repair missed events.
    public var modifiers: Set<KeyToken>?

    public init(_ kind: Kind, time: TimeInterval, modifiers: Set<KeyToken>? = nil) {
        self.kind = kind
        self.time = time
        self.modifiers = modifiers
    }

    public static func down(_ token: KeyToken, at time: TimeInterval, repeat isRepeat: Bool = false, modifiers: Set<KeyToken>? = nil) -> KeyEvent {
        KeyEvent(.down(token, isRepeat: isRepeat), time: time, modifiers: modifiers)
    }

    public static func up(_ token: KeyToken, at time: TimeInterval, modifiers: Set<KeyToken>? = nil) -> KeyEvent {
        KeyEvent(.up(token), time: time, modifiers: modifiers)
    }
}

public enum HotkeyAction: Equatable, Sendable {
    public enum CancelReason: Equatable, Sendable {
        /// Esc (or ✕).
        case user
        /// Push-to-talk released before the hold threshold: a tap, not a dictation.
        case tooShort
        /// Another key was pressed while holding: the user was typing a shortcut.
        case interrupted
    }

    case start(DictationMode)
    /// Turn the current push-to-talk session into a locked hands-free session.
    case lockHandsFree
    case switchToCommand
    case finish
    case cancel(CancelReason)
    /// Show "Hold down to dictate" after a lone tap.
    case showHoldHint
    case trigger(HotkeyActionID)
}

public struct HotkeyOutput: Equatable, Sendable {
    public var actions: [HotkeyAction] = []
    /// Swallow the event so the focused app never sees it.
    public var consume = false
    /// Call `timerFired(at:)` at this time (hold hint after a lone tap).
    public var timerDeadline: TimeInterval?
}

/// Turns raw key events into dictation actions. Pure and deterministic so it can be unit-tested
/// (and ported) without an event tap.
public struct HotkeyStateMachine: Sendable {
    public var settings: ShortcutSettings
    /// Releases faster than this count as taps (then a hint says to hold the key).
    public var holdThreshold: TimeInterval
    public var doubleTapWindow: TimeInterval
    /// Whether a trigger action can run right now. Unavailable shortcuts pass through to the app,
    /// so ⌥O / ⌥1 still type ø / ¡ when there's nothing to act on.
    public var isAvailable: @Sendable (HotkeyActionID) -> Bool = { _ in true }
    /// Non-modifier keys held longer than this without repeating are assumed stale (their key-up was lost).
    public var staleKeyAge: TimeInterval = 3

    private enum Session: Equatable {
        case idle
        case active(mode: DictationMode, startedAt: TimeInterval, holdCombo: KeyCombo?)
    }

    private var session: Session = .idle
    private var pressed: Set<KeyToken> = []
    private var pressedAt: [KeyToken: TimeInterval] = [:]
    private var consumedDowns: Set<KeyToken> = []
    private var lastTapAt: TimeInterval?
    /// Keys held when a session was stopped by a key press; they can't start a new one until released
    /// (stopping with fn+Space must not restart on the Space).
    private var blockedUntilRelease: Set<KeyToken> = []

    public init(settings: ShortcutSettings, holdThreshold: TimeInterval = 0.35, doubleTapWindow: TimeInterval = 0.5) {
        self.settings = settings
        self.holdThreshold = holdThreshold
        self.doubleTapWindow = doubleTapWindow
    }

    public var isDictating: Bool { session != .idle }

    /// Called by the app when a session ends for reasons outside the keyboard (✓/✕ clicked, error).
    public mutating func sessionEnded() {
        session = .idle
    }

    /// Called when the app starts a session without a key (menu item, dictation bar click).
    public mutating func sessionStartedExternally(mode: DictationMode, at time: TimeInterval) {
        session = .active(mode: mode, startedAt: time, holdCombo: nil)
    }

    public mutating func reset() {
        session = .idle
        pressed.removeAll()
        consumedDowns.removeAll()
        lastTapAt = nil
    }

    public mutating func timerFired(at time: TimeInterval) -> HotkeyOutput {
        var out = HotkeyOutput()
        let window = settings.doubleTapForHandsFree ? doubleTapWindow : 0
        if session == .idle, let tap = lastTapAt, time - tap >= window - 0.001 {
            lastTapAt = nil
            out.actions.append(.showHoldHint)
        }
        return out
    }

    public mutating func handle(_ event: KeyEvent) -> HotkeyOutput {
        var out = HotkeyOutput()
        repairModifiers(event, into: &out)

        switch event.kind {
        case .down(let token, let isRepeat):
            if isRepeat {
                pressedAt[token] = event.time
                out.consume = consumedDowns.contains(token)
                return out
            }
            dropStaleKeys(now: event.time)
            pressed.insert(token)
            pressedAt[token] = event.time
            handleDown(token, at: event.time, into: &out)
        case .up(let token):
            blockedUntilRelease.remove(token)
            let wasPressed = pressed.remove(token) != nil
            if consumedDowns.remove(token) != nil { out.consume = true }
            if wasPressed { handleUp(token, at: event.time, into: &out) }
        }
        return out
    }

    // MARK: - Internals

    /// A key whose key-up was hidden (e.g. by Secure Input) would otherwise block every exact-match combo.
    private mutating func dropStaleKeys(now: TimeInterval) {
        for key in pressed where !key.isModifier {
            if let since = pressedAt[key], now - since > staleKeyAge {
                pressed.remove(key)
                pressedAt[key] = nil
                consumedDowns.remove(key)
                blockedUntilRelease.remove(key)
            }
        }
    }

    /// Missed flagsChanged events leave stale modifiers behind; reconcile with the real modifier state.
    private mutating func repairModifiers(_ event: KeyEvent, into out: inout HotkeyOutput) {
        guard let actual = event.modifiers else { return }
        var own: KeyToken?
        switch event.kind {
        case .down(let t, _), .up(let t): own = t
        }
        for stale in pressed where stale.isModifier && !actual.contains(stale) && stale != own {
            pressed.remove(stale)
            handleUp(stale, at: event.time, into: &out)
        }
        for missing in actual where !pressed.contains(missing) && missing != own {
            pressed.insert(missing)
        }
    }

    private func firstSatisfied(_ actions: [HotkeyActionID]) -> (HotkeyActionID, KeyCombo)? {
        var best: (HotkeyActionID, KeyCombo)?
        for action in actions {
            for combo in settings.combos(for: action) where combo.isSatisfied(by: pressed) {
                if best == nil || combo.tokens.count > best!.1.tokens.count { best = (action, combo) }
            }
        }
        return best
    }

    private static func needsConsume(_ token: KeyToken) -> Bool { !token.isModifier }

    private mutating func consume(_ token: KeyToken, _ out: inout HotkeyOutput) {
        guard Self.needsConsume(token) else { return }
        consumedDowns.insert(token)
        out.consume = true
    }

    private static let allTriggerActions: [HotkeyActionID] = HotkeyActionID.allCases.filter {
        !$0.isHold && $0 != .handsFree && $0 != .cancel
    }

    private var triggerActions: [HotkeyActionID] { Self.allTriggerActions.filter(isAvailable) }

    private mutating func handleDown(_ token: KeyToken, at time: TimeInterval, into out: inout HotkeyOutput) {
        switch session {
        case .idle:
            if !blockedUntilRelease.isEmpty {
                let partOfStopCombo = (settings.combos(for: .handsFree) + settings.combos(for: .pushToTalk))
                    .contains { combo in combo.tokens.contains { $0.matches(pressed: token) } }
                if partOfStopCombo {
                    // Finishing the rest of the combo that just stopped a session (the Space of fn+Space).
                    consume(token, &out)
                    blockedUntilRelease.insert(token)
                    return
                }
                blockedUntilRelease.removeAll() // any other key: normal typing resumes
            }
            if let (action, combo) = firstSatisfied([.pushToTalk, .commandMode, .handsFree] + triggerActions) {
                switch action {
                case .pushToTalk:
                    if settings.doubleTapForHandsFree, let tap = lastTapAt, time - tap <= doubleTapWindow {
                        session = .active(mode: .handsFree, startedAt: time, holdCombo: nil)
                        out.actions.append(.start(.handsFree))
                    } else {
                        session = .active(mode: .hold, startedAt: time, holdCombo: combo)
                        out.actions.append(.start(.hold))
                    }
                    lastTapAt = nil
                case .commandMode:
                    session = .active(mode: .command, startedAt: time, holdCombo: combo)
                    out.actions.append(.start(.command))
                    lastTapAt = nil
                case .handsFree:
                    session = .active(mode: .handsFree, startedAt: time, holdCombo: nil)
                    out.actions.append(.start(.handsFree))
                    lastTapAt = nil
                default:
                    out.actions.append(.trigger(action))
                }
                consume(token, &out)
            }

        case .active(let mode, let startedAt, let holdCombo):
            // Esc cancels even while other keys are still held down.
            if settings.combos(for: .cancel).contains(where: { $0.isContained(in: pressed) && $0.tokens.contains { $0.matches(pressed: token) } }) {
                session = .idle
                out.actions.append(.cancel(.user))
                consume(token, &out)
                return
            }
            if let (action, _) = firstSatisfied(triggerActions) {
                // A shortcut pressed while holding means the hold key was the start of that shortcut.
                if mode != .handsFree {
                    session = .idle
                    out.actions.append(.cancel(.interrupted))
                }
                out.actions.append(.trigger(action))
                consume(token, &out)
                return
            }
            switch mode {
            case .hold, .command:
                if firstSatisfied([.handsFree]) != nil {
                    session = .active(mode: .handsFree, startedAt: startedAt, holdCombo: nil)
                    out.actions.append(.lockHandsFree)
                    consume(token, &out)
                } else if mode == .hold, firstSatisfied([.commandMode]) != nil {
                    // Keep the original hold key: letting go of Ctrl first shouldn't end the command.
                    session = .active(mode: .command, startedAt: startedAt, holdCombo: holdCombo)
                    out.actions.append(.switchToCommand)
                    consume(token, &out)
                } else if let holdCombo, holdCombo.isPrefix(of: pressed) {
                    // Still inside the hold combo (e.g. a sided variant); nothing to do.
                } else if !token.isModifier {
                    session = .idle
                    out.actions.append(.cancel(.interrupted))
                }
            case .handsFree:
                if firstSatisfied([.pushToTalk, .handsFree]) != nil {
                    session = .idle
                    out.actions.append(.finish)
                    consume(token, &out)
                    blockedUntilRelease = pressed
                }
            }
        }
    }

    private mutating func handleUp(_ token: KeyToken, at time: TimeInterval, into out: inout HotkeyOutput) {
        blockedUntilRelease.remove(token)
        guard case .active(let mode, let startedAt, let holdCombo?) = session, mode != .handsFree else { return }
        guard holdCombo.tokens.contains(where: { $0.matches(pressed: token) }) else { return }

        session = .idle
        if time - startedAt < holdThreshold {
            out.actions.append(.cancel(.tooShort))
            if mode == .hold {
                lastTapAt = time
                out.timerDeadline = time + (settings.doubleTapForHandsFree ? doubleTapWindow : 0)
            }
        } else {
            out.actions.append(.finish)
        }
    }
}
