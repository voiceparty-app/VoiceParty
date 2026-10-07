import AppKit
import ApplicationServices
import VoicePartyCore

/// Reads the field a dictation went into, for `EditWatch` (learning from the user's corrections):
/// - off the main thread, so an app that answers Accessibility slowly can't hold up the hotkeys;
/// - whatever element has focus in that app at each read, not one kept from key-down: a Chromium app may only have
///   built its accessibility tree since, and moving to another field breaks the watch's anchors anyway;
/// - woken by the field's own "value changed" notifications, so the last edit before Enter empties the box is seen.
final class FieldReader: @unchecked Sendable {
    enum Target {
        /// The focused element of app `pid`. `frontmostOnly`: and only while that app is frontmost (a real dictation).
        case focused(pid: pid_t, fallback: AXUIElement?, frontmostOnly: Bool)
        /// One element, focused or not (the debug test window).
        case element(AXUIElement)
    }

    /// Longer fields aren't followed (every read copies the whole text).
    static let maxLength = 100_000

    let target: Target
    let pid: pid_t
    private let lock = NSLock()
    private var waiter: CheckedContinuation<Void, Never>?
    private var nudged = false
    private var waits = 0
    private var observer: AXObserver?
    private var observed: AXUIElement?
    private var stopped = false
    private var reads = 0
    private var nudges = 0
    /// The role of the element last read.
    private var role: String?

    /// For diagnostics: the role of the element last read, how often it was read and how often it said it changed.
    var stats: (role: String?, reads: Int, nudges: Int) { lock.withLock { (role, reads, nudges) } }

    init(_ target: Target) {
        self.target = target
        switch target {
        case .focused(let pid, _, _): self.pid = pid
        case .element(let element):
            var pid: pid_t = 0
            AXUIElementGetPid(element, &pid)
            self.pid = pid
        }
    }

    func read() -> EditWatch.Read {
        let element: AXUIElement
        switch target {
        case .element(let fixed):
            element = fixed
        case .focused(let pid, let fallback, let frontmostOnly):
            // Another app in front ends the watch; a failed query alone doesn't.
            var frontmost: pid_t = 0
            if frontmostOnly, let app: AXUIElement = Self.copy(AXUIElementCreateSystemWide(), kAXFocusedApplicationAttribute),
               AXUIElementGetPid(app, &frontmost) == .success, frontmost != pid {
                return .focusLost
            }
            let appElement = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(appElement, 0.5)
            guard let focused: AXUIElement = Self.copy(appElement, kAXFocusedUIElementAttribute) ?? fallback else { return .unreadable }
            element = focused
        }
        AXUIElementSetMessagingTimeout(element, 0.5)
        let role: String? = Self.copy(element, kAXRoleAttribute)
        lock.withLock {
            reads += 1
            self.role = role
        }
        observe(element)
        guard let value: String = Self.copy(element, kAXValueAttribute), (value as NSString).length <= Self.maxLength else { return .unreadable }
        return .text(value)
    }

    /// Returns after `duration`, or as soon as the field reports a change (or the watch is cancelled).
    func wait(_ duration: Duration) async {
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                let ticket = lock.withLock { () -> Int? in
                    if nudged || stopped || Task.isCancelled { nudged = false; return nil }
                    waiter = continuation
                    waits += 1
                    return waits
                }
                guard let ticket else { continuation.resume(); return }
                Task { [weak self] in
                    try? await Task.sleep(for: duration)
                    self?.wake(ticket) // only this wait: an earlier one's timer mustn't cut a later one short
                }
            }
        } onCancel: {
            wake()
        }
    }

    fileprivate func fieldChanged() {
        let waiting = lock.withLock { () -> CheckedContinuation<Void, Never>? in
            nudges += 1
            if waiter == nil { nudged = true }
            defer { waiter = nil }
            return waiter
        }
        waiting?.resume()
    }

    private func wake(_ ticket: Int? = nil) {
        let waiting = lock.withLock { () -> CheckedContinuation<Void, Never>? in
            guard ticket == nil || ticket == waits else { return nil }
            defer { waiter = nil }
            return waiter
        }
        waiting?.resume()
    }

    /// Follows "value changed" on the element being read (re-registered if focus moves to another one), and focus
    /// changes in its app.
    private func observe(_ element: AXUIElement) {
        let isNew = lock.withLock { () -> Bool in
            guard !stopped, observed.map({ !CFEqual($0, element) }) ?? true else { return false }
            observed = element
            return true
        }
        guard isNew else { return }
        let pid = pid
        DispatchQueue.main.async { [self] in
            removeObserver()
            guard !lock.withLock({ stopped }) else { return }
            var created: AXObserver?
            guard AXObserverCreate(pid, fieldChangedCallback, &created) == .success, let created else { return }
            let refcon = Unmanaged.passUnretained(self).toOpaque()
            AXObserverAddNotification(created, element, kAXValueChangedNotification as CFString, refcon)
            AXObserverAddNotification(created, element, kAXUIElementDestroyedNotification as CFString, refcon)
            AXObserverAddNotification(created, AXUIElementCreateApplication(pid), kAXFocusedUIElementChangedNotification as CFString, refcon)
            CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(created), .defaultMode)
            observer = created
        }
    }

    /// Main thread.
    private func removeObserver() {
        guard let observer else { return }
        CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
        self.observer = nil
    }

    /// Ends the notifications (the reader stays alive until they're removed on the main thread).
    func stop() {
        lock.withLock { stopped = true }
        wake()
        DispatchQueue.main.async { [self] in removeObserver() }
    }

    static func copy<T>(_ element: AXUIElement, _ attribute: String) -> T? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success, let value else { return nil }
        if T.self == AXUIElement.self { return CFGetTypeID(value) == AXUIElementGetTypeID() ? (value as! T) : nil }
        return value as? T
    }
}

private func fieldChangedCallback(_ observer: AXObserver, _ element: AXUIElement, _ notification: CFString, _ refcon: UnsafeMutableRawPointer?) {
    guard let refcon else { return }
    Unmanaged<FieldReader>.fromOpaque(refcon).takeUnretainedValue().fieldChanged()
}

/// One watch: waits for the paste to land, follows the field until the correction is decided, and stops the reader.
enum EditWatchRun {
    struct Result: Sendable {
        var outcome: EditWatch.Outcome
        var role: String?
        var reads: Int
        var nudges: Int
        var seconds: Double
    }

    static func run(_ reader: FieldReader, pasted: String, watch: EditWatch = EditWatch(), delay: Duration = .milliseconds(300)) async -> Result {
        let started = ProcessInfo.processInfo.systemUptime
        try? await Task.sleep(for: delay) // let the paste land
        let outcome = await watch.run(pasted: pasted, read: { reader.read() }, wait: { await reader.wait($0) },
                                      now: { ProcessInfo.processInfo.systemUptime })
        reader.stop()
        let stats = reader.stats
        return Result(outcome: outcome, role: stats.role, reads: stats.reads, nudges: stats.nudges,
                      seconds: ProcessInfo.processInfo.systemUptime - started)
    }
}
