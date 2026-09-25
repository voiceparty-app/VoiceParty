import Darwin
import Foundation
import VoicePartyCore
import VoicePartyEngines

/// Runs installed cleanup models in llama.cpp servers bound to 127.0.0.1 (random port, random API key),
/// restarts them if they crash, and stops them when VoiceParty quits. Before every start the runtime and the
/// model are checked against their pinned hashes, so files changed after download are never run.
@MainActor
final class LocalModelServer {
    struct Running {
        let process: Process
        let polisher: LocalLLMPolisher
    }

    private(set) var running: [String: Running] = [:]
    private var ready: Set<String> = []
    /// Being verified (a start is already on its way: don't launch a second server).
    private var starting: Set<String> = []
    private var stopping = false
    private var restarts: [String: Int] = [:]
    private var pendingRestarts: [String: Task<Void, Never>] = [:]
    /// Models that failed their integrity check this session: not started again until reinstalled.
    private var tampered: Set<String> = []
    /// After macOS runs short of memory, don't reload straight away (that would thrash).
    private var pressureCooldownUntil: ContinuousClock.Instant?
    /// The Notetaker keeps the notes model loaded through a meeting and its wrap-up.
    private var holds = 0
    var onChange: (() -> Void)?
    /// A model's files changed on disk: the app tells the user to reinstall it.
    var onIntegrityFailure: ((String) -> Void)?
    /// Unload after this long without dictating (nil = keep loaded).
    var idleUnload: Duration?
    private var lastUsed = ContinuousClock.now
    private var installedIDs: Set<String> = []
    private var idleTimer: Timer?
    private var pressureSource: DispatchSourceMemoryPressure?

    static var pidFile: URL { Paths.appSupport.appending(path: "model-servers.pid") }

    var fast: LocalLLMPolisher? { ready.contains(EnhancementID.fastCleanup) ? running[EnhancementID.fastCleanup]?.polisher : nil }
    var strong: LocalLLMPolisher? { ready.contains(EnhancementID.strongCleanup) ? running[EnhancementID.strongCleanup]?.polisher : nil }

    private var binary: URL? {
        guard let runtime = EnhancementCatalog.enhancement(EnhancementID.localRuntime)?.files.first else { return nil }
        let url = EnhancementManager.root.appending(path: runtime.path + "/" + (runtime.archiveCheck ?? ""))
        return FileManager.default.isExecutableFile(atPath: url.path) ? url : nil
    }

    /// Starts servers for installed models (unless loading on demand) and stops servers for removed ones.
    func sync(installed: (String) -> Bool) {
        killStaleServers()
        watchMemoryPressure()
        installedIDs = Set([EnhancementID.fastCleanup, EnhancementID.strongCleanup].filter { installed($0) && installed(EnhancementID.localRuntime) })
        tampered.subtract(installedIDs.subtracting(running.keys)) // a reinstall gets a fresh check
        for id in [EnhancementID.fastCleanup, EnhancementID.strongCleanup] where !installedIDs.contains(id) { stop(id) }
        if idleUnload == nil { ensureRunning() }
        scheduleIdleCheck()
    }

    /// Called when dictation starts: load models now so they're ready by the time you finish speaking.
    func ensureRunning() {
        lastUsed = .now
        if let until = pressureCooldownUntil, ContinuousClock.now < until { return }
        for id in installedIDs where running[id] == nil { start(id) }
    }

    /// Keep models loaded (no idle unload) until the matching `release()`.
    func hold() {
        holds += 1
        ensureRunning()
    }

    func release() {
        holds = max(0, holds - 1)
        lastUsed = .now
    }

    private func scheduleIdleCheck() {
        idleTimer?.invalidate()
        guard idleUnload != nil else { return }
        idleTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.holds == 0, let limit = self.idleUnload, ContinuousClock.now - self.lastUsed > limit else { return }
                self.unloadAll()
            }
        }
    }

    private func unloadAll() {
        for id in Array(running.keys) { stop(id) }
    }

    /// macOS is short on memory: free the models immediately; they reload on the next dictation.
    private func watchMemoryPressure() {
        guard pressureSource == nil else { return }
        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .main)
        source.setEventHandler { [weak self, weak source] in
            let critical = source?.data.contains(.critical) == true
            MainActor.assumeIsolated {
                guard let self, critical || self.holds == 0 else { return } // a meeting's notes model stays unless it's critical
                self.pressureCooldownUntil = .now + .seconds(120)
                self.unloadAll()
            }
        }
        source.resume()
        pressureSource = source
    }

    func stopAll() {
        stopping = true
        for task in pendingRestarts.values { task.cancel() }
        pendingRestarts.removeAll()
        for id in Array(running.keys) { stop(id) }
        try? FileManager.default.removeItem(at: Self.pidFile)
    }

    /// Checks the files off the main thread (≈1 s for the 2.5 GB model), then launches.
    private func start(_ id: String) {
        guard running[id] == nil, !starting.contains(id), !tampered.contains(id), !stopping,
              let runtime = EnhancementCatalog.enhancement(EnhancementID.localRuntime),
              let enhancement = EnhancementCatalog.enhancement(id) else { return }
        starting.insert(id)
        let root = EnhancementManager.root
        Task { [weak self] in
            let intact = await Task.detached(priority: .userInitiated) {
                runtime.filesAreIntact(in: root) && enhancement.filesAreIntact(in: root)
            }.value
            guard let self else { return }
            self.starting.remove(id)
            guard intact else {
                self.tampered.insert(id)
                self.onIntegrityFailure?(id)
                return
            }
            guard self.installedIDs.contains(id), !self.stopping else { return }
            self.launch(id)
        }
    }

    private func launch(_ id: String) {
        guard running[id] == nil, let binary, let enhancement = EnhancementCatalog.enhancement(id), let file = enhancement.files.first else { return }
        let model = EnhancementManager.root.appending(path: file.path)
        let port = Int.random(in: 49_152...65_000)
        let apiKey = UUID().uuidString
        // The key goes in the environment, not the command line: any user on this Mac can list command lines.
        // No /slots endpoint (it would show the last prompt, i.e. what you said) and no web UI.
        var arguments = ["-m", model.path, "--host", "127.0.0.1", "--port", String(port),
                         "--jinja", "-ngl", "99", "-np", "1", "--temp", "0", "--no-webui", "--no-slots"]
        let format: LocalLLMPolisher.Format
        if id == EnhancementID.fastCleanup {
            format = .s1mini
            // Cleanup output mostly copies the input, so n-gram speculation (as on the smart tier) cuts median latency
            // about a third with identical output. `-cram 0`: dictations share no prompt prefix, so llama-server's
            // prompt cache never helped here and only grew (0.8 → 4.1 GB after ~330 dictations; measured Sept 2026).
            arguments += ["-c", "2048", "--chat-template-kwargs", #"{"enable_thinking":false}"#, "--top-k", "1",
                          "--spec-type", "ngram-simple", "--spec-ngram-simple-size-n", "3", "--spec-ngram-simple-size-m", "16",
                          "-cram", "0"]
        } else {
            format = .instruct
            arguments += ["-c", "4096", "--top-k", "1", "--spec-type", "ngram-simple",
                          "--spec-ngram-simple-size-n", "3", "--spec-ngram-simple-size-m", "16"]
        }
        guard let polisher = try? LocalLLMPolisher(baseURL: URL(string: "http://127.0.0.1:\(port)")!, model: id, format: format,
                                                  apiKey: apiKey, timeout: 4) else { return }
        let process = Process()
        process.executableURL = binary
        process.arguments = arguments
        process.environment = ["LLAMA_API_KEY": apiKey, "PATH": "/usr/bin:/bin", "HOME": NSHomeDirectory(), "TMPDIR": NSTemporaryDirectory()]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.terminationHandler = { [weak self] exited in
            let pid = exited.processIdentifier
            Task { @MainActor in self?.handleExit(id, pid: pid) }
        }
        do {
            try process.run()
        } catch {
            return
        }
        running[id] = Running(process: process, polisher: polisher)
        writePidFile()
        Task { [weak self] in
            for _ in 0..<120 { // a cold 2.5 GB load can take a while on a busy Mac
                guard self?.running[id]?.process === process else { return } // stopped or replaced meanwhile
                if await polisher.isReachable() {
                    await polisher.prewarm()
                    self?.ready.insert(id)
                    self?.restarts[id] = 0
                    self?.onChange?()
                    return
                }
                try? await Task.sleep(for: .milliseconds(500))
            }
        }
    }

    private func stop(_ id: String) {
        pendingRestarts.removeValue(forKey: id)?.cancel()
        guard let entry = running.removeValue(forKey: id) else { return }
        ready.remove(id)
        entry.process.terminationHandler = nil
        entry.process.terminate()
        writePidFile()
        onChange?()
    }

    /// Only the exit of the server we're tracking counts (an old one exiting late mustn't drop its replacement).
    private func handleExit(_ id: String, pid: Int32) {
        guard let entry = running[id], entry.process.processIdentifier == pid else { return }
        running[id] = nil
        ready.remove(id)
        writePidFile()
        onChange?()
        guard !stopping, installedIDs.contains(id) else { return }
        let attempt = (restarts[id] ?? 0) + 1
        restarts[id] = attempt
        guard attempt <= 5 else { return }
        pendingRestarts[id]?.cancel()
        pendingRestarts[id] = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Double(attempt * attempt)))
            guard !Task.isCancelled, let self else { return }
            self.pendingRestarts[id] = nil
            self.start(id)
        }
    }

    private func writePidFile() {
        let pids = running.values.map { String($0.process.processIdentifier) }.joined(separator: "\n")
        try? pids.write(to: Self.pidFile, atomically: true, encoding: .utf8)
    }

    /// Servers orphaned by a crash of a previous VoiceParty run.
    private func killStaleServers() {
        guard running.isEmpty, let text = try? String(contentsOf: Self.pidFile, encoding: .utf8) else { return }
        for line in text.split(separator: "\n") {
            guard let pid = Int32(line), pid > 0 else { continue }
            // PIDs get reused: only stop it if it's still our llama-server.
            var buffer = [CChar](repeating: 0, count: 4096)
            guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0,
                  String(cString: buffer).hasPrefix(EnhancementManager.root.path) else { continue }
            kill(pid, SIGTERM)
        }
        try? FileManager.default.removeItem(at: Self.pidFile)
    }
}
