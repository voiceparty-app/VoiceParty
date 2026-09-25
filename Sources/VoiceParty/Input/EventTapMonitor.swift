import AppKit
import CoreGraphics
import VoicePartyCore

/// Marks events VoiceParty posts itself (synthetic ⌘V, Enter) so the tap ignores them.
let syntheticEventMarker: Int64 = 0x5650_5254 // "VPRT"

/// Global keyboard/mouse hook. A `.defaultTap` (needs Accessibility) so shortcuts can be swallowed.
/// Modifier-only shortcuts (fn, Right Option) arrive as flagsChanged, which keeps working even
/// under Secure Keyboard Entry.
@MainActor
final class EventTapMonitor {
    /// Returns whether to swallow the event.
    var onEvent: ((KeyEvent) -> Bool)?
    private(set) var isRunning = false

    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    func start() -> Bool {
        if isRunning { return true }
        let types: [CGEventType] = [.keyDown, .keyUp, .flagsChanged, .otherMouseDown, .otherMouseUp]
        let mask = types.reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << $1.rawValue) }
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: eventTapCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else { return false }
        self.tap = tap
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        isRunning = true
        return true
    }

    func stop() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let runLoopSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes) }
        tap = nil
        runLoopSource = nil
        isRunning = false
    }

    fileprivate func reenable() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
    }

    fileprivate func handle(type: CGEventType, event: CGEvent) -> Bool {
        guard let keyEvent = Self.keyEvent(type: type, event: event) else { return false }
        return onEvent?(keyEvent) ?? false
    }

    // MARK: CGEvent → KeyEvent

    /// Device-dependent modifier bits (IOLLEvent.h): tell left from right.
    private static let sidedBits: [(KeyToken, UInt64)] = [
        (.leftControl, 0x0000_0001), (.leftShift, 0x0000_0002), (.rightShift, 0x0000_0004),
        (.leftCommand, 0x0000_0008), (.rightCommand, 0x0000_0010), (.leftOption, 0x0000_0020),
        (.rightOption, 0x0000_0040), (.rightControl, 0x0000_2000),
    ]

    static func modifiers(from flags: CGEventFlags) -> Set<KeyToken> {
        var set = Set<KeyToken>()
        for (token, bit) in sidedBits where flags.rawValue & bit != 0 { set.insert(token) }
        // Keyboards that don't report sided bits: fall back to the generic flag as the left key.
        if flags.contains(.maskControl), !set.contains(.leftControl), !set.contains(.rightControl) { set.insert(.leftControl) }
        if flags.contains(.maskAlternate), !set.contains(.leftOption), !set.contains(.rightOption) { set.insert(.leftOption) }
        if flags.contains(.maskCommand), !set.contains(.leftCommand), !set.contains(.rightCommand) { set.insert(.leftCommand) }
        if flags.contains(.maskShift), !set.contains(.leftShift), !set.contains(.rightShift) { set.insert(.leftShift) }
        return set
    }

    static func keyEvent(type: CGEventType, event: CGEvent) -> KeyEvent? {
        // The event's own time (nanoseconds since boot, same clock as systemUptime), not when we got to it.
        let time = event.timestamp > 0 ? Double(event.timestamp) / 1_000_000_000 : ProcessInfo.processInfo.systemUptime
        var mods = modifiers(from: event.flags)
        let code = UInt16(event.getIntegerValueField(.keyboardEventKeycode))

        switch type {
        case .flagsChanged:
            // Globe/fn: keycode 63 (some keyboards 179). maskSecondaryFn is also set by arrows/F-keys,
            // so only trust it on the fn key's own flagsChanged event.
            if code == KeyCode.function || code == 179 {
                let down = event.flags.contains(.maskSecondaryFn)
                if down { mods.insert(.fn) }
                return KeyEvent(down ? .down(.fn, isRepeat: false) : .up(.fn), time: time, modifiers: mods)
            }
            guard let token = KeyToken.modifier(forKeyCode: code) else { return nil }
            let down = mods.contains(token)
            return KeyEvent(down ? .down(token, isRepeat: false) : .up(token), time: time, modifiers: nil)
        case .keyDown:
            let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
            return KeyEvent(.down(.key(code), isRepeat: isRepeat), time: time, modifiers: nil)
        case .keyUp:
            return KeyEvent(.up(.key(code)), time: time, modifiers: nil)
        case .otherMouseDown:
            return KeyEvent(.down(.mouse(Int(event.getIntegerValueField(.mouseEventButtonNumber))), isRepeat: false), time: time, modifiers: nil)
        case .otherMouseUp:
            return KeyEvent(.up(.mouse(Int(event.getIntegerValueField(.mouseEventButtonNumber)))), time: time, modifiers: nil)
        default:
            return nil
        }
    }
}

private func eventTapCallback(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent, userInfo: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    guard let userInfo else { return Unmanaged.passUnretained(event) }
    let monitor = Unmanaged<EventTapMonitor>.fromOpaque(userInfo).takeUnretainedValue()
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        MainActor.assumeIsolated { monitor.reenable() }
        return Unmanaged.passUnretained(event)
    }
    if event.getIntegerValueField(.eventSourceUserData) == syntheticEventMarker {
        return Unmanaged.passUnretained(event)
    }
    let swallow = MainActor.assumeIsolated { monitor.handle(type: type, event: event) }
    return swallow ? nil : Unmanaged.passUnretained(event)
}
