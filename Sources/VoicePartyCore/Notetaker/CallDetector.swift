import Foundation

/// Notices calls from which apps are using the microphone (Zoom, Teams, FaceTime…): suggests taking notes
/// once a call has had the mic for `startDelay`, and reports the call ending once the mic has been free
/// for `endDelay` (so a mute or a brief device switch doesn't end it).
public struct CallDetector: Sendable {
    public enum Event: Equatable, Sendable {
        case started(app: String)
        case ended(app: String)
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
    public var endDelay: TimeInterval
    private var since: [String: TimeInterval] = [:]
    private var lastSeen: [String: TimeInterval] = [:]
    private var announced: Set<String> = []

    public init(startDelay: TimeInterval = 10, endDelay: TimeInterval = 20) {
        self.startDelay = startDelay
        self.endDelay = endDelay
    }

    /// `usingMic`: names of call apps with the microphone on right now.
    public mutating func observe(usingMic: Set<String>, at time: TimeInterval) -> [Event] {
        var events: [Event] = []
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
            if time - seen >= endDelay {
                if announced.contains(app) { events.append(.ended(app: app)) }
                lastSeen[app] = nil
                since[app] = nil
                announced.remove(app)
            } else if !announced.contains(app) {
                since[app] = nil // a blip before the call was confirmed: start over
            }
        }
        return events
    }
}
