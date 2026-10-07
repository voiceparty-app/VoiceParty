import Foundation

/// Notices calls from which apps are using the microphone (Zoom, Teams, FaceTime…): suggests taking notes
/// once a call has had the mic for `startDelay`, and reports the call ending once the processes that had the mic have
/// stopped both recording and playing for `quickEndDelay`, or the mic has been free for `endDelay` whatever plays.
///
/// Live: Teams let go of the mic and its speaker within 20 ms when the call ended, but notes waited 20 s for the mic
/// alone (the user stopped them by hand). A mute keeps the sound of the others playing, and a device switch restarts
/// both within a second or two; another process of the app (Teams' web view playing the hang-up sound for ~10 s, a
/// browser's other tabs) doesn't count.
public struct CallDetector: Sendable {
    public enum Event: Equatable, Sendable {
        case started(app: String)
        case ended(app: String)
    }

    /// One process of a call app, as Core Audio reports it.
    public struct AudioUse: Equatable, Sendable {
        public var app: String
        public var process: Int32
        public var input: Bool
        public var output: Bool
        public init(app: String, process: Int32, input: Bool, output: Bool) {
            self.app = app
            self.process = process
            self.input = input
            self.output = output
        }
    }

    /// Bundle ID → name for apps whose microphone use means a call.
    public static let callApps: [String: String] = [
        "us.zoom.xos": "Zoom", "com.microsoft.teams2": "Teams", "com.microsoft.teams": "Teams",
        "com.apple.FaceTime": "FaceTime", "com.cisco.webexmeetingsapp": "Webex", "com.webex.meetingmanager": "Webex",
        "com.tinyspeck.slackmacgap": "Slack", "com.hnc.Discord": "Discord", "net.whatsapp.WhatsApp": "WhatsApp",
        "com.google.Chrome": "Chrome", "com.apple.Safari": "Safari", "company.thebrowser.Browser": "Arc",
        "com.microsoft.edgemac": "Edge", "org.mozilla.firefox": "Firefox", "com.brave.Browser": "Brave",
    ]

    /// The call app a process belongs to. Mic use often shows up on a helper ("com.google.Chrome.helper",
    /// "us.zoom.CptHost"), and Safari's goes through WebKit.
    public static func appName(forBundleID bundleID: String) -> String? {
        if bundleID.hasPrefix("com.apple.WebKit") { return "Safari" }
        if bundleID.hasPrefix("us.zoom") { return "Zoom" }
        return callApps.first { bundleID == $0.key || bundleID.hasPrefix($0.key + ".") }?.value
    }

    public var startDelay: TimeInterval
    public var quickEndDelay: TimeInterval
    public var endDelay: TimeInterval
    private var since: [String: TimeInterval] = [:]
    private var lastSeen: [String: TimeInterval] = [:]
    private var announced: Set<String> = []
    /// The processes that had the mic during each app's call.
    private var micProcesses: [String: Set<Int32>] = [:]

    public init(startDelay: TimeInterval = 10, quickEndDelay: TimeInterval = 5, endDelay: TimeInterval = 20) {
        self.startDelay = startDelay
        self.quickEndDelay = quickEndDelay
        self.endDelay = endDelay
    }

    /// `uses`: the call apps' audio processes right now.
    public mutating func observe(_ uses: [AudioUse], at time: TimeInterval) -> [Event] {
        var events: [Event] = []
        let usingMic = Set(uses.filter(\.input).map(\.app))
        for use in uses where use.input { micProcesses[use.app, default: []].insert(use.process) }
        for app in usingMic {
            lastSeen[app] = time
            let start = since[app] ?? time
            since[app] = start
            if !announced.contains(app), time - start >= startDelay {
                announced.insert(app)
                events.append(.started(app: app))
            }
        }
        for (app, seen) in lastSeen where !usingMic.contains(app) {
            let holders = micProcesses[app] ?? []
            let silent = !uses.contains { $0.output && holders.contains($0.process) }
            if time - seen >= endDelay || silent && time - seen >= quickEndDelay {
                if announced.contains(app) { events.append(.ended(app: app)) }
                lastSeen[app] = nil
                since[app] = nil
                micProcesses[app] = nil
                announced.remove(app)
            } else if !announced.contains(app) {
                since[app] = nil // a blip before the call was confirmed: start over
            }
        }
        return events
    }
}
