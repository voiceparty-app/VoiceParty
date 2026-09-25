import AppKit
import CryptoKit
import Foundation
import Observation
import Security
import VoicePartyCore

/// Updates from GitHub Releases, without the App Store or a paid Apple certificate. Once a day (and on
/// "Check for Updates…") it asks GitHub for the latest version number — nothing about you is sent. An update
/// is installed only if its checksum matches and it's signed with the same certificate as this app, so a
/// tampered download (or a compromised release page) can't replace VoiceParty.
@MainActor
@Observable
final class Updater {
    enum State: Equatable {
        case idle
        case checking
        case available(version: String)
        case installing
        case failed(String)
    }

    private(set) var state: State = .idle
    @ObservationIgnored private unowned let app: AppModel
    @ObservationIgnored private var latest: ReleaseInfo?
    @ObservationIgnored private var timer: Timer?

    /// "owner/repo" from Info.plist (VoicePartyUpdateRepo); updates are off when it isn't set.
    static var repository: String? {
        let repo = Bundle.main.object(forInfoDictionaryKey: "VoicePartyUpdateRepo") as? String
        return repo?.contains("/") == true && repo?.contains("OWNER") == false ? repo : nil
    }

    static var currentVersion: AppVersion {
        AppVersion(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0") ?? AppVersion("0")!
    }

    init(app: AppModel) {
        self.app = app
    }

    /// Checks now if a day has passed, then keeps checking every few hours while the app runs.
    func startAutomaticChecks() {
        timer?.invalidate()
        guard Self.repository != nil else { return }
        checkIfDue()
        timer = Timer.scheduledTimer(withTimeInterval: 6 * 3600, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkIfDue() }
        }
    }

    private func checkIfDue() {
        guard app.settings.checkForUpdates, UpdateSchedule.isDue(lastCheck: app.settings.lastUpdateCheck) else { return }
        Task { await check(userInitiated: false) }
    }

    func check(userInitiated: Bool) async {
        guard let repo = Self.repository else {
            if userInitiated { app.dictationBar.toast("This build doesn't have an update source.", duration: 3) }
            return
        }
        guard state != .checking, state != .installing else { return }
        state = .checking
        app.settings.lastUpdateCheck = Date()
        // Debug builds can point at a local test feed (never used unless DebugURLs is on).
        let testFeed = DebugURLs.enabled ? UserDefaults.standard.string(forKey: "UpdateFeedURL").flatMap(URL.init) : nil
        var request = URLRequest(url: testFeed ?? URL(string: "https://api.github.com/repos/\(repo)/releases/latest")!)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("VoiceParty-Updater", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 20
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let release = testFeed.map({ ReleaseInfo.parse(data, trustedHost: $0.host ?? "", allowHTTP: true) }) ?? ReleaseInfo.parse(data) else {
            state = .idle
            if userInitiated { app.dictationBar.toast("Couldn't reach GitHub to check for updates.", style: .error, duration: 4) }
            return
        }
        guard release.version > Self.currentVersion else {
            state = .idle
            if userInitiated { app.dictationBar.toast("VoiceParty \(Self.currentVersion) is the latest version.", duration: 3) }
            return
        }
        latest = release
        state = .available(version: release.version.description)
        app.dictationBar.toast("VoiceParty \(release.version) is available", action: "Install", duration: 12) { [weak self] in
            Task { await self?.install() }
        }
    }

    // MARK: Install

    func install() async {
        guard let release = latest, state != .installing else { return }
        guard UpdateSwap.canInstallNow(dictating: app.dictation.state != .idle, takingNotes: app.notetaker.state != .idle) else {
            app.dictationBar.toast("VoiceParty \(release.version) will install when you've finished recording.", duration: 4)
            waitForIdleThenOffer()
            return
        }
        state = .installing
        app.dictationBar.toast("Downloading VoiceParty \(release.version)…", duration: 4)
        let fm = FileManager.default
        let work = fm.temporaryDirectory.appending(path: "voiceparty-update-\(UUID().uuidString)", directoryHint: .isDirectory)
        do {
            try fm.createDirectory(at: work, withIntermediateDirectories: true)
            let (downloaded, _) = try await URLSession.shared.download(from: release.zipURL)
            let zip = work.appending(path: "VoiceParty.zip")
            try fm.moveItem(at: downloaded, to: zip)

            if let checksumURL = release.checksumURL {
                let (expected, _) = try await URLSession.shared.data(from: checksumURL)
                let want = String(decoding: expected, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines).prefix(64)
                let have = SHA256.hash(data: try Data(contentsOf: zip)).map { String(format: "%02x", $0) }.joined()
                guard want == have else { throw UpdateError.checksum }
            }

            try Self.run("/usr/bin/ditto", ["-x", "-k", zip.path, work.appending(path: "unpacked").path])
            let newApp = work.appending(path: "unpacked/VoiceParty.app")
            let type = try fm.attributesOfItem(atPath: newApp.path)[.type] as? FileAttributeType
            guard type == .typeDirectory else { throw UpdateError.signature } // a link to some other app
            try Self.verifySameSigner(newApp)
            // The bundle must really be the newer version (no "updating" back to an old, signed build).
            let bundled = Bundle(url: newApp)?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
            guard let bundledVersion = bundled.flatMap(AppVersion.init), bundledVersion == release.version,
                  bundledVersion > Self.currentVersion else { throw UpdateError.version }
            try replaceAndRelaunch(with: newApp, work: work)
        } catch {
            try? fm.removeItem(at: work)
            state = .failed(error.localizedDescription)
            app.dictationBar.toast("Update failed: \(error.localizedDescription)", style: .error, duration: 6)
        }
    }

    /// The new app must be validly signed AND satisfy this app's own designated requirement (same identifier,
    /// same signing certificate) — the check that keeps anyone else's build from being installed.
    static func verifySameSigner(_ newApp: URL) throws {
        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(newApp as CFURL, [], &staticCode) == errSecSuccess, let staticCode else { throw UpdateError.signature }
        var selfCode: SecCode?
        var selfStatic: SecStaticCode?
        var requirement: SecRequirement?
        guard SecCodeCopySelf([], &selfCode) == errSecSuccess, let selfCode,
              SecCodeCopyStaticCode(selfCode, [], &selfStatic) == errSecSuccess, let selfStatic,
              SecCodeCopyDesignatedRequirement(selfStatic, [], &requirement) == errSecSuccess, let requirement else { throw UpdateError.signature }
        let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSStrictValidate | kSecCSCheckNestedCode)
        guard SecStaticCodeCheckValidity(staticCode, flags, requirement) == errSecSuccess else { throw UpdateError.signature }
    }

    /// Offers the install again once the dictation or meeting in progress is over.
    private func waitForIdleThenOffer() {
        Task { [weak self] in
            while let self, !UpdateSwap.canInstallNow(dictating: self.app.dictation.state != .idle,
                                                       takingNotes: self.app.notetaker.state != .idle) {
                try? await Task.sleep(for: .seconds(5))
            }
            guard let self, let release = self.latest else { return }
            self.app.dictationBar.toast("VoiceParty \(release.version) is ready to install", action: "Install", duration: 12) { [weak self] in
                Task { await self?.install() }
            }
        }
    }

    /// Swaps the app bundle after VoiceParty quits (a running app can't replace itself), then reopens it.
    private func replaceAndRelaunch(with newApp: URL, work: URL) throws {
        let current = Bundle.main.bundleURL
        guard FileManager.default.isWritableFile(atPath: current.deletingLastPathComponent().path) else { throw UpdateError.notWritable }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", UpdateSwap.script, "voiceparty-update", String(ProcessInfo.processInfo.processIdentifier),
                             current.path, newApp.path, "1", work.path]
        try process.run() // keeps running after we quit
        app.dictationBar.toast("Installing the update — VoiceParty will reopen in a moment", duration: 3)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { NSApp.terminate(nil) }
    }

    private static func run(_ tool: String, _ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw UpdateError.unpack }
    }

    enum UpdateError: LocalizedError {
        case checksum, signature, unpack, notWritable, version
        var errorDescription: String? {
            switch self {
            case .checksum: "the download didn't match its checksum"
            case .signature: "the update isn't signed by the same developer as this copy"
            case .unpack: "couldn't unpack the download"
            case .notWritable: "VoiceParty's folder isn't writable; run the install command again"
            case .version: "the download isn't the newer version it claims to be"
            }
        }
    }
}
