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
    /// Who keeps the models loaded past their idle unload: the Notetaker through a meeting and its wrap-up, a benchmark.
    private var holds = ModelHolds()
    private var lastHold = ContinuousClock.now
    var onChange: (() -> Void)?
    /// A model's files changed on disk: the app tells the user to reinstall it.
    var onIntegrityFailure: ((String) -> Void)?
    /// Settings → Model memory: how long each model stays loaded unused (Automatic: shorter as free memory drops).
    var memoryPolicy = ModelMemoryPolicy.automatic
    /// When each model was last asked for (a dictation starting, a meeting, a hold).
    private var lastUsed: [String: ContinuousClock.Instant] = [:]
    /// When each server last did any work, whoever asked (its CPU time moved): a benchmark the app can't see counts.
    private var lastActivity: [String: ContinuousClock.Instant] = [:]
    private var cpuSeconds: [String: Double] = [:]
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
        // Models kept loaded for good start now; the others load when a dictation needs them.
        ensureRunning(installedIDs.filter { idleLimit(for: $0, freeMemory: nil) == nil })
        scheduleIdleCheck()
    }

    var isInstalled: (fast: Bool, strong: Bool) {
        (installedIDs.contains(EnhancementID.fastCleanup), installedIDs.contains(EnhancementID.strongCleanup))
    }

    /// Called when dictation starts: load the models it may use now, so they're ready by the time you finish speaking
    /// (nil: every installed model).
    func ensureRunning(_ ids: Set<String>? = nil) {
        let wanted = ids.map { installedIDs.intersection($0) } ?? installedIDs
        let now = ContinuousClock.now
        for id in wanted { lastUsed[id] = now }
        if let until = pressureCooldownUntil, now < until { return }
        for id in wanted where running[id] == nil { start(id) }
    }

    /// Keep every model loaded (no idle unload) until the matching `release`.
    func hold(_ owner: ModelHolds.Owner) {
        holds.hold(owner)
        lastHold = .now
        ensureRunning()
    }

    func release(_ owner: ModelHolds.Owner) {
        holds.release(owner)
        let now = ContinuousClock.now
        for id in running.keys { lastUsed[id] = now }
    }

    /// Every 30 s while a server runs: note which servers worked, end holds whose owner is gone, unload idle models.
    private func scheduleIdleCheck() {
        idleTimer?.invalidate()
        idleTimer = nil
        guard !running.isEmpty, memoryPolicy != .alwaysReady else { return }
        let timer = Timer(timeInterval: 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkIdle() }
        }
        timer.tolerance = 5
        RunLoop.main.add(timer, forMode: .common)
        idleTimer = timer
    }

    private func checkIdle() {
        noteServerActivity()
        let now = ContinuousClock.now
        let lastWork = lastActivity.values.reduce(lastHold) { max($0, $1) }
        holds.expire(idleFor: Self.seconds(now - lastWork), isRunning: { kill($0, 0) == 0 || errno == EPERM })
        guard !holds.isHeld else { return }
        let free = Self.freeMemoryPercent()
        for id in Array(running.keys) {
            guard let limit = idleLimit(for: id, freeMemory: free) else { continue }
            let used = max(lastUsed[id] ?? now, lastActivity[id] ?? now)
            if now - used > limit { stop(id) }
        }
    }

    private func idleLimit(for id: String, freeMemory: Int?) -> Duration? {
        memoryPolicy.idleUnload(for: id == EnhancementID.fastCleanup ? .fast : .strong, freeMemoryPercent: freeMemory)
    }

    /// macOS's own "memory free" percentage (what `memory_pressure` prints): one cheap sysctl per idle check.
    static func freeMemoryPercent() -> Int? {
        #if VOICEPARTY_DEBUG_URLS
        if let simulated = debugFreeMemoryPercent { return simulated }
        #endif
        var level: Int32 = 0
        var size = MemoryLayout<Int32>.size
        return sysctlbyname("kern.memorystatus_level", &level, &size, nil, 0) == 0 ? Int(level) : nil
    }

    #if VOICEPARTY_DEBUG_URLS
    /// Debug (debug/memory?free=20): pretend macOS reports this much free memory, to test Automatic without filling RAM.
    static var debugFreeMemoryPercent: Int?

    /// Debug: which models are loaded and what Automatic would do with them now.
    func debugMemoryReport() -> [String: Any] {
        let free = Self.freeMemoryPercent()
        let now = ContinuousClock.now
        var models: [String: Any] = [:]
        for id in [EnhancementID.fastCleanup, EnhancementID.strongCleanup] {
            let idle = lastUsed[id].map { Self.seconds(now - max($0, lastActivity[id] ?? $0)) }
            models[id] = ["loaded": running[id] != nil, "idleSeconds": idle as Any,
                          "unloadAfterSeconds": idleLimit(for: id, freeMemory: free).map { Self.seconds($0) } as Any]
        }
        return ["freeMemoryPercent": free as Any, "policy": memoryPolicy.rawValue, "held": holds.isHeld, "models": models]
    }
    #endif

    /// A server that used more than half a second of CPU since the last check (30 s) was busy answering someone else's
    /// requests, e.g. a benchmark (the app's own dictations count through `lastUsed`). An idle server uses ~0.1 s per
    /// 30 s, one cleanup ~20 ms, 150 cleanups ~3 s.
    private func noteServerActivity() {
        let now = ContinuousClock.now
        for (id, entry) in running {
            guard let seconds = Self.cpuSeconds(of: entry.process.processIdentifier) else { continue }
            if seconds - (cpuSeconds[id] ?? seconds) > 0.5 { lastActivity[id] = now }
            cpuSeconds[id] = seconds
        }
    }

    static func cpuSeconds(of pid: pid_t) -> Double? {
        var info = rusage_info_v4()
        let status = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V4, $0) }
        }
        guard status == 0 else { return nil }
        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)
        return Double(info.ri_user_time + info.ri_system_time) * Double(timebase.numer) / Double(timebase.denom) / 1e9
    }

    static func seconds(_ duration: Duration) -> TimeInterval {
        Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
    }

    #if VOICEPARTY_DEBUG_URLS
    /// Debug (flag experiments): extra llama-server arguments per model, in memory only; the servers restart with them.
    var debugArguments: [String: [String]] = [:] {
        didSet { for id in Array(running.keys) { stop(id) } }
    }
    /// Debug (flag experiments): extra environment variables for both servers (e.g. GGML_METAL_… switches).
    var debugEnvironment: [String: String] = [:]
    #endif

    /// Debug: unload now, as the idle timer would (models held by a meeting or a benchmark stay).
    func unloadIfNotHeld() {
        guard !holds.isHeld else { return }
        unloadAll()
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
                guard let self, critical || !self.holds.isHeld else { return } // a meeting's notes model stays unless it's critical
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
        // The whole model runs on the GPU, so llama.cpp's CPU threads have nothing to do but spin-wait for the next step
        // (`--poll 50`): 12 cores busy through every request, ~94% of the servers' CPU energy (150 cleanups: 187 → 12 J of
        // CPU, 18% less energy in all, identical outputs; docs/energy.md). The fast model runs without them (`-t 1`); the
        // strong one keeps them asleep between steps (`--poll 0`): each was the quickest for its model.
        var arguments = ["-m", model.path, "--host", "127.0.0.1", "--port", String(port),
                         "--jinja", "-ngl", "99", "-np", "1", "--temp", "0", "--no-webui", "--no-slots"]
        let format: LocalLLMPolisher.Format
        if id == EnhancementID.fastCleanup {
            format = .s1mini
            // Cleanup output mostly copies the input, so n-gram speculation (as on the smart tier) cuts median latency
            // about a third with identical output. `-cram 0`: dictations share no prompt prefix, so llama-server's
            // prompt cache never helped here and only grew (0.8 → 4.1 GB after ~330 dictations; measured Sept 2026).
            arguments += ["-t", "1", "-c", "2048", "--chat-template-kwargs", #"{"enable_thinking":false}"#, "--top-k", "1",
                          "--spec-type", "ngram-simple", "--spec-ngram-simple-size-n", "3", "--spec-ngram-simple-size-m", "16",
                          "-cram", "0"]
        } else {
            format = .instruct
            arguments += ["--poll", "0"]
            // `-cram 2048`: the prompt cache brings back the cleanup instructions (or a meeting's transcript) after another
            // prompt came between, instead of re-reading them (2,500 tokens: 1.7 s of GPU); cleanup, second-language and
            // notes prompts together use ~0.9 GB. The default cap (8 GB) let it grow to ~9 GB in the process after
            // benchmarks with many different prompts.
            arguments += ["-c", "4096", "--top-k", "1", "--spec-type", "ngram-simple",
                          "--spec-ngram-simple-size-n", "3", "--spec-ngram-simple-size-m", "16", "-cram", "2048"]
        }
        #if VOICEPARTY_DEBUG_URLS
        arguments += debugArguments[id] ?? [] // flag experiments (debug/model-args); later flags override earlier ones
        #endif
        guard let polisher = try? LocalLLMPolisher(baseURL: URL(string: "http://127.0.0.1:\(port)")!, model: id, format: format,
                                                  apiKey: apiKey, timeout: 4) else { return }
        let process = Process()
        process.executableURL = binary
        process.arguments = arguments
        // Metal residency sets stay on: their keep-alive thread wakes an idle server ~150 times a second (~0.2 mW), but
        // without them a strong-model cleanup a few seconds after the last one was ~50 ms slower and ~0.4 J dearer
        // (GGML_METAL_NO_RESIDENCY=1; docs/energy.md).
        var environment = ["LLAMA_API_KEY": apiKey, "PATH": "/usr/bin:/bin", "HOME": NSHomeDirectory(), "TMPDIR": NSTemporaryDirectory()]
        #if VOICEPARTY_DEBUG_URLS
        for (name, value) in debugEnvironment { environment[name] = value == "-" ? nil : value } // "-" removes a variable
        #endif
        process.environment = environment
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
        cpuSeconds[id] = nil
        lastActivity[id] = .now
        if idleTimer == nil { scheduleIdleCheck() }
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
        if running.isEmpty { scheduleIdleCheck() } // nothing left to watch: no timer
        writePidFile()
        onChange?()
    }

    /// Only the exit of the server we're tracking counts (an old one exiting late mustn't drop its replacement).
    private func handleExit(_ id: String, pid: Int32) {
        guard let entry = running[id], entry.process.processIdentifier == pid else { return }
        running[id] = nil
        ready.remove(id)
        if running.isEmpty { scheduleIdleCheck() }
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
