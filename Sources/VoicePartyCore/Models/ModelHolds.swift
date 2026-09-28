import Foundation

/// Who keeps the local cleanup models loaded past their idle unload: a meeting being recorded (the Notetaker needs the
/// notes model at the end, however quiet the meeting was), or a tool talking to the model servers directly (a benchmark,
/// which the app can't see dictating). A tool that dies without releasing its hold must not keep gigabytes loaded for
/// the rest of the session: its hold ends when its process exits, and every tool hold ends once the models have done
/// no work for `inactivityLimit`.
public struct ModelHolds: Sendable, Equatable {
    public enum Owner: Hashable, Sendable {
        case meeting
        /// `pid`: the tool's process, when it says (older bench scripts don't).
        case tool(pid: Int32?)
    }

    public static let inactivityLimit: TimeInterval = 600

    private var meetings = 0
    /// One entry per tool hold, oldest first.
    private var tools: [Int32?] = []

    public init() {}

    public var isHeld: Bool { meetings > 0 || !tools.isEmpty }

    public mutating func hold(_ owner: Owner) {
        switch owner {
        case .meeting: meetings += 1
        case .tool(let pid): tools.append(pid)
        }
    }

    /// A tool's release ends its own hold; one that doesn't name its process ends the oldest hold.
    public mutating func release(_ owner: Owner) {
        switch owner {
        case .meeting:
            meetings = max(0, meetings - 1)
        case .tool(let pid):
            if let index = tools.firstIndex(of: pid) ?? (pid == nil ? tools.indices.first : nil) { tools.remove(at: index) }
        }
    }

    /// Ends tool holds whose process has exited, and all of them once the models have been idle for `inactivityLimit`
    /// (`idleFor`: seconds since the models last did any work or a hold was placed).
    public mutating func expire(idleFor: TimeInterval, isRunning: (Int32) -> Bool) {
        if idleFor > Self.inactivityLimit {
            tools.removeAll()
            return
        }
        tools.removeAll { pid in pid.map { !isRunning($0) } ?? false }
    }
}
