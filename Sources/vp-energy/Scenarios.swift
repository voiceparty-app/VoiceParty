import Darwin
import Foundation

// Scenarios against the running app (a development build with DebugURLs on): dictations through
// voiceparty://debug/dictate?live=1 — key-down loads and warms the models as a real dictation does, "speech" lasts as
// long as the audio, nothing is pasted and nothing goes into history — each measured from key-down until the text is
// ready plus a short tail. Audio is made with `say` from made-up text.

enum VoicePartyApp {
    static let support = FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Application Support/VoiceParty")
    static var debugLast: URL { support.appending(path: "debug-last.json") }

    static func open(_ url: String) {
        run("/usr/bin/open", ["-g", url])
    }
}

@discardableResult
func run(_ tool: String, _ arguments: [String]) -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: tool)
    process.arguments = arguments
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = FileHandle.nullDevice
    guard (try? process.run()) != nil else { return "" }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return String(decoding: data, as: UTF8.self)
}

/// The app's llama-server children and their ports (from their command lines).
func modelServers(of app: pid_t) -> [(pid: pid_t, port: Int, model: String)] {
    childPIDs(of: app).compactMap { pid in
        let command = run("/bin/ps", ["-ww", "-o", "command=", "-p", String(pid)])
        guard command.contains("llama-server"), let range = command.range(of: #"--port (\d+)"#, options: .regularExpression),
              let port = Int(command[range].split(separator: " ")[1]) else { return nil }
        return (pid, port, command.contains("Qwen") ? "strong" : "fast")
    }
}

func isHealthy(port: Int) -> Bool {
    var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/health")!)
    request.timeoutInterval = 1
    let done = DispatchSemaphore(value: 0)
    let healthy = Locked(false)
    URLSession.shared.dataTask(with: request) { _, response, _ in
        healthy.set((response as? HTTPURLResponse)?.statusCode == 200)
        done.signal()
    }.resume()
    done.wait()
    return healthy.get()
}

final class Locked<T>: @unchecked Sendable {
    private var value: T
    private let lock = NSLock()
    init(_ value: T) { self.value = value }
    func get() -> T { lock.withLock { value } }
    func set(_ new: T) { lock.withLock { value = new } }
}

/// Waits until `count` servers answer /health, then a few seconds more (the app warms each one up after loading).
func waitForServers(app: pid_t, count: Int, timeout: Double = 120) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        let servers = modelServers(of: app)
        if servers.count >= count, servers.allSatisfy({ isHealthy(port: $0.port) }) {
            Thread.sleep(forTimeInterval: 3)
            return true
        }
        Thread.sleep(forTimeInterval: 0.5)
    }
    return false
}

func waitForNoServers(app: pid_t, timeout: Double = 20) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if modelServers(of: app).isEmpty { return true }
        Thread.sleep(forTimeInterval: 0.25)
    }
    return false
}

// MARK: - Dictations

struct Utterance {
    var name: String
    var category: String
    var mode = "hold"
    var text: String
}

/// Made-up dictations (never real ones: this file is public). Aimed at each route: the router decides on the transcript,
/// so the route actually taken is reported, not assumed.
enum Utterances {
    static let asrOnly = Utterance(name: "asr-only", category: "personalMessage", text: "Sounds good.")
    static let skip = Utterance(name: "skip", category: "personalMessage", text: "Happy birthday, Sam! I hope you have a wonderful day with your family.")
    static let fast = Utterance(name: "fast", category: "workMessage",
                                text: "The new layout is, you know, a lot cleaner than the old one, and the team seems to like it too.")
    /// Parakeet writes the amount as "$45,000" itself, so this one needs no model.
    static let budget = Utterance(name: "budget", category: "workMessage",
                                  text: "The budget for the offsite is about forty five thousand dollars, including travel and the venue.")
    static let strong = Utterance(name: "strong", category: "aiPrompt",
                                  text: "Write a function that parses the date from the header, actually no, make it return an optional instead of throwing an error.")
    static let long = Utterance(name: "long", category: "document", mode: "handsFree", text: """
        So here is the plan for the launch next month. First we finish the onboarding flow and get it in front of five or six \
        testers by the end of this week, because the last round showed that people got stuck on the permissions screen and we \
        never really fixed that. Second, the pricing page needs another pass, the copy is too long and nobody reads the \
        comparison table. Third, we should record a short demo video, maybe two minutes, that shows the app working in email, \
        in a chat app and in a code editor. I think Tamaro can own the video and Priya can take the pricing page, and I will \
        handle the testers. Let's check in again on Thursday afternoon and see where everything stands.
        """)

    static let day: [(Utterance, cold: Bool)] = [
        (Utterance(name: "prompt", category: "aiPrompt",
                   text: "Can you refactor the settings screen so the toggles are grouped by section, and add a short description under each one?"), true),
        (Utterance(name: "late", category: "personalMessage", text: "Running ten minutes late, save me a seat."), false),
        (Utterance(name: "build", category: "workMessage",
                   text: "Hey Priya, um, the build is green again, so I think we can, uh, ship the beta to the testers this afternoon."), false),
        (Utterance(name: "contract", category: "email", text: """
            Hi Sam, thanks for sending the contract over. I read through it last night and it mostly looks good, but section four \
            still says thirty days and we agreed on forty five. Could you update that and send me a clean copy? Thanks, Tamaro.
            """), false),
        (asrOnly, true),
        (long, false),
        (strong, false),
        (Utterance(name: "code", category: "code", text: "rename the variable user count to active user count in the whole file"), false),
        (budget, true),
        (Utterance(name: "birthday", category: "personalMessage", text: "Happy birthday! Hope you have a great day."), false),
        (Utterance(name: "runon", category: "aiPrompt", text: """
            I want the sidebar to remember which sections were collapsed when you close the window and when you open it again it \
            should look exactly the same as before including the scroll position and the selected item
            """), false),
        (Utterance(name: "reminder", category: "email", text: "Hi team, quick reminder that the design review moved to Thursday at two."), false),
    ]
}

func fixture(_ utterance: Utterance, in folder: URL) -> URL {
    let url = folder.appending(path: "\(utterance.name).aiff")
    let textFile = folder.appending(path: "\(utterance.name).txt")
    if (try? String(contentsOf: textFile, encoding: .utf8)) != utterance.text || !FileManager.default.fileExists(atPath: url.path) {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        run("/usr/bin/say", ["-o", url.path, utterance.text])
        try? utterance.text.write(to: textFile, atomically: true, encoding: .utf8)
    }
    return url
}

struct DictationResult: Codable {
    var name: String
    var category: String
    var cold: Bool
    var route: String
    var polisher: String
    var readyFast: Bool
    var readyStrong: Bool
    var latencyMs: Double
    var asrMs: Double
    var cleanupMs: Double
    var usage: Usage
    var footprintAfterMB: Double
}

func modificationDate(_ url: URL) -> Date? {
    (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
}

/// One dictation: key-down → speech → text, then `tail` seconds for the servers to go quiet (`untilLoaded`: until every
/// model the app started has loaded and warmed up, so a cold start pays for all of its loading).
func dictate(_ utterance: Utterance, file: URL, app: pid_t, cold: Bool, tail: Double = 1.5, untilLoaded: Bool = false) throws -> DictationResult {
    if cold {
        VoicePartyApp.open("voiceparty://debug/unload-models")
        guard waitForNoServers(app: app) else { fail("The models didn't unload (held by a bench or a meeting?).") }
        Thread.sleep(forTimeInterval: 1)
    }
    let previous = modificationDate(VoicePartyApp.debugLast)
    let before = try snapshot(pid: app)
    var components = URLComponents(string: "voiceparty://debug/dictate")!
    components.queryItems = [.init(name: "file", value: file.path), .init(name: "category", value: utterance.category),
                             .init(name: "mode", value: utterance.mode), .init(name: "live", value: "1"), .init(name: "tiers", value: "0")]
    VoicePartyApp.open(components.url!.absoluteString)
    let deadline = Date().addingTimeInterval(180)
    var report: [String: Any]?
    while Date() < deadline {
        Thread.sleep(forTimeInterval: 0.1)
        guard let date = modificationDate(VoicePartyApp.debugLast), date != previous,
              let data = FileManager.default.contents(atPath: VoicePartyApp.debugLast.path),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
        report = json
        break
    }
    guard let report else { fail("No result from debug/dictate (a development build with DebugURLs on?).") }
    if let error = report["error"] { fail("debug/dictate failed: \(error)") }
    if untilLoaded { _ = waitForServers(app: app, count: modelServers(of: app).count, timeout: 90) }
    Thread.sleep(forTimeInterval: tail)
    let after = try snapshot(pid: app)
    let ready = report["readyAtKeyUp"] as? [String: Bool] ?? [:]
    let number = { (key: String) in (report[key] as? NSNumber)?.doubleValue ?? -1 }
    let polisher = (report["polisher"] as? String ?? "?").replacingOccurrences(of: "local-llm:cleanup-", with: "")
    return DictationResult(name: utterance.name, category: utterance.category, cold: cold, route: report["route"] as? String ?? "?",
                           polisher: polisher, readyFast: ready["fast"] ?? false, readyStrong: ready["strong"] ?? false,
                           latencyMs: number("keyUpToTextMs"), asrMs: number("asrMs"), cleanupMs: number("cleanupMs"),
                           usage: after.usage - before.usage, footprintAfterMB: after.usage.footprintMB)
}

func printHeader() {
    print("name       category         cold route  model        ready  latency   energy J (CPU/GPU/ANE)       cpu s  gpu s  wakeups  memory MB")
}

func printRow(_ r: DictationResult) {
    let u = r.usage
    let ready = (r.readyFast ? "f" : "-") + (r.readyStrong ? "s" : "-")
    let energy = "\(format(u.energyJ, 2)) (\(format(u.cpuEnergyJ, 2))/\(format(u.gpuEnergyJ, 2))/\(format(u.aneEnergyJ, 2)))"
    print([r.name.padding(toLength: 10, withPad: " ", startingAt: 0), r.category.padding(toLength: 16, withPad: " ", startingAt: 0),
           (r.cold ? "cold" : "    "), r.route.padding(toLength: 6, withPad: " ", startingAt: 0),
           r.polisher.padding(toLength: 12, withPad: " ", startingAt: 0), ready.padding(toLength: 5, withPad: " ", startingAt: 0),
           "\(format(r.latencyMs, 0)) ms".padding(toLength: 9, withPad: " ", startingAt: 0), energy.padding(toLength: 28, withPad: " ", startingAt: 0),
           format(u.cpuSeconds, 2).padding(toLength: 6, withPad: " ", startingAt: 0), format(u.gpuSeconds, 2).padding(toLength: 6, withPad: " ", startingAt: 0),
           format(u.idleWakeups + u.interruptWakeups, 0).padding(toLength: 8, withPad: " ", startingAt: 0), format(r.footprintAfterMB, 0)]
        .joined(separator: " "))
}

func median(_ values: [Double]) -> Double {
    guard !values.isEmpty else { return 0 }
    let sorted = values.sorted()
    return sorted.count % 2 == 1 ? sorted[sorted.count / 2] : (sorted[sorted.count / 2 - 1] + sorted[sorted.count / 2]) / 2
}

struct ScenarioOutput: Codable {
    var scenario: String
    var label: String?
    var dictations: [DictationResult]
    var total: Report
}

func fixturesFolder(_ args: [String]) -> URL {
    URL(fileURLWithPath: option("--fixtures", in: args) ?? NSTemporaryDirectory() + "vp-energy-fixtures")
}

/// Per route: one warm-up, then `repeats` warm dictations (median energy and latency), then cold ones.
func runRoutes(app: pid_t, args: [String]) throws {
    let repeats = Int(option("--repeats", in: args) ?? "5") ?? 5
    let folder = fixturesFolder(args)
    let only = option("--only", in: args).map { Set($0.split(separator: ",").map(String.init)) }
    let set = [Utterances.asrOnly, Utterances.skip, Utterances.fast, Utterances.strong, Utterances.long].filter { only?.contains($0.name) ?? true }
    let files = set.map { fixture($0, in: folder) }
    VoicePartyApp.open("voiceparty://debug/hold-models?pid=\(getpid())") // loaded and warm for the warm runs
    defer { VoicePartyApp.open("voiceparty://debug/release-models?pid=\(getpid())") }
    guard waitForServers(app: app, count: 2) else { fail("The model servers didn't start.") }
    let start = try snapshot(pid: app)
    var results: [DictationResult] = []
    printHeader()
    for (utterance, file) in zip(set, files) {
        _ = try dictate(utterance, file: file, app: app, cold: false) // warm-up (ASR caches, prompt cache)
        for _ in 0..<repeats {
            let result = try dictate(utterance, file: file, app: app, cold: false)
            printRow(result)
            results.append(result)
            Thread.sleep(forTimeInterval: 2)
        }
    }
    print("\nmedians (warm)")
    for utterance in set {
        let rows = results.filter { $0.name == utterance.name }
        print("  \(utterance.name.padding(toLength: 9, withPad: " ", startingAt: 0)) route \(rows.first?.route ?? "?"), model \(rows.first?.polisher ?? "?"):"
              + " \(format(median(rows.map(\.usage.energyJ)), 2)) J (CPU \(format(median(rows.map(\.usage.cpuEnergyJ)), 2)),"
              + " GPU \(format(median(rows.map(\.usage.gpuEnergyJ)), 2)), ANE \(format(median(rows.map(\.usage.aneEnergyJ)), 2))),"
              + " latency \(format(median(rows.map(\.latencyMs)), 0)) ms")
    }
    // Cold: the models unloaded (as after 5 idle minutes) — released first so the unload isn't refused.
    VoicePartyApp.open("voiceparty://debug/release-models?pid=\(getpid())")
    Thread.sleep(forTimeInterval: 1)
    print("\ncold (models unloaded before each)")
    printHeader()
    for (utterance, file) in zip(set, files) where ["skip", "fast", "strong"].contains(utterance.name) && !args.contains("--warm-only") {
        let result = try dictate(utterance, file: file, app: app, cold: true, untilLoaded: true)
        printRow(result)
        results.append(result)
    }
    VoicePartyApp.open("voiceparty://debug/hold-models?pid=\(getpid())") // balanced by the deferred release
    let total = Report(label: option("--label", in: args), before: start, after: try snapshot(pid: app))
    if let path = option("--json", in: args) { write(ScenarioOutput(scenario: "routes", label: option("--label", in: args), dictations: results, total: total), to: path) }
}

/// A dozen varied dictations 20 s apart; three start with the models unloaded (as after a 5-minute pause).
func runDay(app: pid_t, args: [String]) throws {
    let gap = Double(option("--gap", in: args) ?? "20") ?? 20
    let folder = fixturesFolder(args)
    let files = Utterances.day.map { fixture($0.0, in: folder) }
    let start = try snapshot(pid: app)
    var results: [DictationResult] = []
    printHeader()
    for ((utterance, cold), file) in zip(Utterances.day, files) {
        let result = try dictate(utterance, file: file, app: app, cold: cold)
        printRow(result)
        results.append(result)
        Thread.sleep(forTimeInterval: gap)
    }
    let end = try snapshot(pid: app)
    let total = Report(label: option("--label", in: args), before: start, after: end)
    print("")
    total.print()
    let sum = results.reduce(0) { $0 + $1.usage.energyJ }
    print("dictation windows: \(format(sum, 1)) J over \(results.count) dictations = \(format(sum / Double(results.count), 2)) J each;"
          + " median latency \(format(median(results.map(\.latencyMs)), 0)) ms, mean \(format(results.map(\.latencyMs).reduce(0, +) / Double(results.count), 0)) ms")
    if let path = option("--json", in: args) { write(ScenarioOutput(scenario: "day", label: option("--label", in: args), dictations: results, total: total), to: path) }
}

/// What loading each model costs (as a dictation after the idle unload would): unload, load, wait until it answers and
/// the app has warmed it up.
func runLoads(app: pid_t, args: [String]) throws {
    let repeats = Int(option("--repeats", in: args) ?? "3") ?? 3
    print("which        energy J (CPU/GPU)          cpu s  gpu s  ready after  memory MB")
    for _ in 0..<repeats {
        for which in ["fast", "strong", "fast,strong"] {
            VoicePartyApp.open("voiceparty://debug/unload-models")
            guard waitForNoServers(app: app) else { fail("The models didn't unload (held?).") }
            Thread.sleep(forTimeInterval: 3)
            let before = try snapshot(pid: app)
            let started = Date()
            VoicePartyApp.open("voiceparty://debug/load-models?which=\(which)")
            let count = which.split(separator: ",").count
            var readyAfter = -1.0
            while Date().timeIntervalSince(started) < 90 {
                let servers = modelServers(of: app)
                if servers.count >= count, servers.allSatisfy({ isHealthy(port: $0.port) }) {
                    readyAfter = Date().timeIntervalSince(started)
                    break
                }
                Thread.sleep(forTimeInterval: 0.1)
            }
            Thread.sleep(forTimeInterval: 4) // the app's warm-up request, then quiet
            let after = try snapshot(pid: app)
            let u = after.usage - before.usage
            print([which.padding(toLength: 12, withPad: " ", startingAt: 0),
                   "\(format(u.energyJ, 2)) (\(format(u.cpuEnergyJ, 2))/\(format(u.gpuEnergyJ, 2)))".padding(toLength: 27, withPad: " ", startingAt: 0),
                   format(u.cpuSeconds, 2).padding(toLength: 6, withPad: " ", startingAt: 0), format(u.gpuSeconds, 2).padding(toLength: 6, withPad: " ", startingAt: 0),
                   "\(format(readyAfter, 2)) s".padding(toLength: 12, withPad: " ", startingAt: 0), format(after.usage.footprintMB, 0)].joined(separator: " "))
        }
    }
}

/// Idle: `loaded` holds the models loaded for the window (else they stay as they are).
func runIdle(app: pid_t, args: [String], loaded: Bool) throws {
    let seconds = Double(option("--seconds", in: args) ?? "600") ?? 600
    if loaded {
        VoicePartyApp.open("voiceparty://debug/hold-models?pid=\(getpid())")
        guard waitForServers(app: app, count: 2) else { fail("The model servers didn't start.") }
        Thread.sleep(forTimeInterval: 5)
    }
    defer { if loaded { VoicePartyApp.open("voiceparty://debug/release-models?pid=\(getpid())") } }
    let start = try snapshot(pid: app)
    var peaks: [Int32: Double] = [:]
    var coalitionPeak = start.usage.footprintMB
    var last = start
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
        Thread.sleep(forTimeInterval: min(5, max(deadline.timeIntervalSinceNow, 0.01)))
        let sample = try snapshot(pid: app)
        guard sample.coalition == start.coalition else { fail("VoiceParty relaunched during the window.") }
        for process in sample.processes { peaks[process.pid] = max(peaks[process.pid] ?? 0, process.footprintMB) }
        coalitionPeak = max(coalitionPeak, sample.usage.footprintMB)
        last = sample
    }
    let report = Report(label: option("--label", in: args) ?? (loaded ? "idle, models loaded" : "idle"), before: start, after: last,
                        peaks: peaks, coalitionPeakMB: coalitionPeak)
    report.print()
    if let path = option("--json", in: args) { write(report, to: path) }
}
