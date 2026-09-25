import Foundation

/// A dotted version ("0.2.0", "v1.3"), compared numerically; missing parts count as 0.
public struct AppVersion: Comparable, CustomStringConvertible, Sendable {
    public let parts: [Int]

    public init?(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespaces).drop { $0 == "v" || $0 == "V" }
        let parts = trimmed.split(separator: ".").map { Int($0) }
        guard !parts.isEmpty, parts.allSatisfy({ $0 != nil }) else { return nil }
        self.parts = parts.compactMap { $0 }
    }

    public var description: String { parts.map(String.init).joined(separator: ".") }

    private func padded(_ count: Int) -> [Int] { parts + Array(repeating: 0, count: max(0, count - parts.count)) }

    public static func < (a: AppVersion, b: AppVersion) -> Bool {
        let n = max(a.parts.count, b.parts.count)
        return a.padded(n).lexicographicallyPrecedes(b.padded(n))
    }

    public static func == (a: AppVersion, b: AppVersion) -> Bool {
        let n = max(a.parts.count, b.parts.count)
        return a.padded(n) == b.padded(n)
    }
}

/// The latest GitHub release, from `GET /repos/{owner}/{repo}/releases/latest`.
public struct ReleaseInfo: Equatable, Sendable {
    public var version: AppVersion
    public var zipURL: URL
    public var checksumURL: URL?
    public var notes: String

    /// nil for drafts, pre-releases, releases without `VoiceParty.zip`, or downloads not hosted by GitHub.
    /// (`trustedHost`/`allowHTTP` exist for tests against a local server.)
    public static func parse(_ data: Data, trustedHost: String = "github.com", allowHTTP: Bool = false) -> ReleaseInfo? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              json["draft"] as? Bool != true, json["prerelease"] as? Bool != true,
              let tag = json["tag_name"] as? String, let version = AppVersion(tag),
              let assets = json["assets"] as? [[String: Any]] else { return nil }
        func asset(_ name: String) -> URL? {
            guard let raw = assets.first(where: { $0["name"] as? String == name })?["browser_download_url"] as? String,
                  let url = URL(string: raw), url.scheme == "https" || (allowHTTP && url.scheme == "http"),
                  url.host == trustedHost else { return nil }
            return url
        }
        guard let zip = asset("VoiceParty.zip") else { return nil }
        return ReleaseInfo(version: version, zipURL: zip, checksumURL: asset("VoiceParty.zip.sha256"), notes: json["body"] as? String ?? "")
    }
}

public enum UpdateSchedule {
    public static let interval: TimeInterval = 24 * 3600

    public static func isDue(lastCheck: Date?, now: Date = Date()) -> Bool {
        guard let lastCheck else { return true }
        return now.timeIntervalSince(lastCheck) >= interval
    }
}

/// Replacing the app bundle after VoiceParty quits (a running app can't replace itself).
public enum UpdateSwap {
    /// A fixed script; every path arrives as an argument, never as shell code:
    /// `sh -c script voiceparty-update <pid> <current.app> <new.app> <relaunch 1|0> <download folder>`.
    /// Waits for the app to quit, copies the new bundle next to the old one, swaps them, and on any failure
    /// keeps (or restores) the old app. Links are refused. The download folder is removed afterwards.
    public static let script = #"""
    pid="$1"; current="$2"; new="$3"; relaunch="$4"; work="$5"
    while kill -0 "$pid" 2>/dev/null; do sleep 0.2; done
    done_with() {
        case "$work" in "${TMPDIR%/}"/?*) rm -rf "$work" ;; esac
        if [ "$relaunch" = 1 ]; then
            if [ "$1" = 0 ]; then open -g "$current" --args --background --updated; else open -g "$current" --args --background; fi
        fi
        exit "$1"
    }
    case "$current" in *.app) ;; *) done_with 1 ;; esac
    if [ -L "$new" ] || [ -L "$current" ] || [ ! -d "$new" ]; then done_with 1; fi
    staging="$current.staging"
    rm -rf "$staging" "$current.old"
    if ! ditto "$new" "$staging"; then rm -rf "$staging"; done_with 1; fi
    if ! mv "$current" "$current.old"; then rm -rf "$staging"; done_with 1; fi
    if ! mv "$staging" "$current"; then mv "$current.old" "$current"; rm -rf "$staging"; done_with 1; fi
    rm -rf "$current.old"
    xattr -dr com.apple.quarantine "$current" 2>/dev/null
    done_with 0
    """#

    /// Installing quits VoiceParty: never in the middle of a dictation or a meeting.
    public static func canInstallNow(dictating: Bool, takingNotes: Bool) -> Bool {
        !dictating && !takingNotes
    }
}
