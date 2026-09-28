import Darwin
import Foundation

// vp-energy: what VoiceParty costs in energy, from the kernel's own accounting, without sudo.
//
//   vp-energy watch [--seconds 600] [--interval 2] [--pid N] [--json out.json]   # a window, then totals
//   vp-energy snap [--pid N]                                                        # cumulative counters now (JSON)
//   vp-energy diff before.json after.json [--label text] [--json out.json]          # what happened between two snaps
//
// It reads the app's resource coalition: VoiceParty and everything it launched (the llama-server model servers),
// including processes that have already exited, which is also how macOS attributes energy ("Using Significant
// Energy"). CPU, GPU and Neural Engine energy come from the kernel's energy counters (nanojoules on Apple
// Silicon); memory is the coalition's physical footprint. Only the same user's processes can be read.

// MARK: - Kernel interfaces (libsystem_kernel; not in the public SDK headers)

@_silgen_name("coalition_info_resource_usage")
private func coalition_info_resource_usage(_ cid: UInt64, _ buffer: UnsafeMutableRawPointer, _ size: Int) -> Int32

/// `struct coalition_resource_usage` as uint64 slots (xnu, macOS 26). Checked at run time: slot 23 is the number of
/// QoS classes (7), and the counters must be non-decreasing.
private enum Slot {
    static let tasksStarted = 0, tasksExited = 1, cpuTime = 3, interruptWakeups = 4, idleWakeups = 5
    static let bytesRead = 6, bytesWritten = 7, gpuTimeNs = 8, cpuEnergyNj = 11, cpuPTime = 22, qosCount = 23
    static let aneTime = 38, aneEnergyNj = 39, footprint = 40, gpuEnergyNj = 41
    static let count = 64
}

private let ticksToSeconds: Double = {
    var info = mach_timebase_info_data_t()
    mach_timebase_info(&info)
    return Double(info.numer) / Double(info.denom) / 1e9
}()

private func coalitionID(of pid: pid_t) -> UInt64? {
    var ids = [UInt64](repeating: 0, count: 5) // proc_pidcoalitioninfo: ids per type (resource, jetsam) + reserved
    let size = Int32(ids.count * 8)
    guard proc_pidinfo(pid, 20 /* PROC_PIDCOALITIONINFO */, 0, &ids, size) == size, ids[0] != 0 else { return nil }
    return ids[0]
}

private func string(_ buffer: [CChar]) -> String {
    String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
}

private func processName(_ pid: pid_t) -> String {
    var buffer = [CChar](repeating: 0, count: 256)
    proc_name(pid, &buffer, UInt32(buffer.count))
    return string(buffer)
}

private func processPath(_ pid: pid_t) -> String {
    var buffer = [CChar](repeating: 0, count: 4096)
    guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return "" }
    return string(buffer)
}

private func allPIDs() -> [pid_t] {
    var pids = [pid_t](repeating: 0, count: 8192)
    let count = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
    return Array(pids.prefix(Int(max(count, 0))))
}

private func parentPID(_ pid: pid_t) -> pid_t? {
    var info = proc_bsdinfo()
    let size = Int32(MemoryLayout<proc_bsdinfo>.size)
    guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
    return pid_t(info.pbi_ppid)
}

func childPIDs(of pid: pid_t) -> [pid_t] {
    allPIDs().filter { parentPID($0) == pid }
}

/// The running VoiceParty app (the bundle's binary, not vp-bench or a test runner).
private func findApp() -> pid_t? {
    allPIDs().first { processName($0) == "VoiceParty" && processPath($0).hasSuffix(".app/Contents/MacOS/VoiceParty") }
}

// MARK: - Samples

struct Usage: Codable {
    var cpuEnergyJ = 0.0, gpuEnergyJ = 0.0, aneEnergyJ = 0.0
    var cpuSeconds = 0.0, pCoreSeconds = 0.0, gpuSeconds = 0.0, aneSeconds = 0.0
    var idleWakeups = 0.0, interruptWakeups = 0.0
    var bytesRead = 0.0, bytesWritten = 0.0
    var tasksStarted = 0.0, tasksExited = 0.0
    /// A level, not a counter: the coalition's physical memory footprint.
    var footprintMB = 0.0

    var energyJ: Double { cpuEnergyJ + gpuEnergyJ + aneEnergyJ }

    static func - (a: Usage, b: Usage) -> Usage {
        Usage(cpuEnergyJ: a.cpuEnergyJ - b.cpuEnergyJ, gpuEnergyJ: a.gpuEnergyJ - b.gpuEnergyJ, aneEnergyJ: a.aneEnergyJ - b.aneEnergyJ,
              cpuSeconds: a.cpuSeconds - b.cpuSeconds, pCoreSeconds: a.pCoreSeconds - b.pCoreSeconds,
              gpuSeconds: a.gpuSeconds - b.gpuSeconds, aneSeconds: a.aneSeconds - b.aneSeconds,
              idleWakeups: a.idleWakeups - b.idleWakeups, interruptWakeups: a.interruptWakeups - b.interruptWakeups,
              bytesRead: a.bytesRead - b.bytesRead, bytesWritten: a.bytesWritten - b.bytesWritten,
              tasksStarted: a.tasksStarted - b.tasksStarted, tasksExited: a.tasksExited - b.tasksExited,
              footprintMB: a.footprintMB)
    }
}

struct ProcessSample: Codable {
    var pid: Int32
    var name: String
    var footprintMB: Double
    var cpuSeconds: Double
    var cpuEnergyJ: Double
    var idleWakeups: Double
    var interruptWakeups: Double
}

struct Snapshot: Codable {
    var time: Double
    var pid: Int32
    var coalition: UInt64
    var usage: Usage
    var processes: [ProcessSample]
}

enum SampleError: Error, CustomStringConvertible {
    case noApp, noCoalition(pid_t), unreadable(UInt64), unexpectedLayout(UInt64)
    var description: String {
        switch self {
        case .noApp: "VoiceParty isn't running (or pass --pid)."
        case .noCoalition(let pid): "Couldn't read process \(pid)'s coalition (another user's process?)."
        case .unreadable(let id): "Couldn't read coalition \(id)."
        case .unexpectedLayout(let n): "This macOS lays out coalition usage differently (QoS count \(n), expected 7): update Slot."
        }
    }
}

func usage(ofCoalition id: UInt64) throws -> Usage {
    var raw = [UInt64](repeating: 0, count: Slot.count)
    guard raw.withUnsafeMutableBytes({ coalition_info_resource_usage(id, $0.baseAddress!, $0.count) }) == 0 else {
        throw SampleError.unreadable(id)
    }
    guard raw[Slot.qosCount] == 7 else { throw SampleError.unexpectedLayout(raw[Slot.qosCount]) }
    let d = { (slot: Int) in Double(raw[slot]) }
    return Usage(cpuEnergyJ: d(Slot.cpuEnergyNj) / 1e9, gpuEnergyJ: d(Slot.gpuEnergyNj) / 1e9, aneEnergyJ: d(Slot.aneEnergyNj) / 1e9,
                 cpuSeconds: d(Slot.cpuTime) * ticksToSeconds, pCoreSeconds: d(Slot.cpuPTime) * ticksToSeconds,
                 gpuSeconds: d(Slot.gpuTimeNs) / 1e9, aneSeconds: d(Slot.aneTime) * ticksToSeconds,
                 idleWakeups: d(Slot.idleWakeups), interruptWakeups: d(Slot.interruptWakeups),
                 bytesRead: d(Slot.bytesRead), bytesWritten: d(Slot.bytesWritten),
                 tasksStarted: d(Slot.tasksStarted), tasksExited: d(Slot.tasksExited),
                 footprintMB: d(Slot.footprint) / 1_048_576)
}

func processSample(_ pid: pid_t) -> ProcessSample? {
    var info = rusage_info_v6()
    let ok = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V6, $0) }
    }
    guard ok == 0 else { return nil }
    return ProcessSample(pid: pid, name: processName(pid), footprintMB: Double(info.ri_phys_footprint) / 1_048_576,
                         cpuSeconds: Double(info.ri_user_time + info.ri_system_time) * ticksToSeconds,
                         cpuEnergyJ: Double(info.ri_energy_nj) / 1e9,
                         idleWakeups: Double(info.ri_pkg_idle_wkups), interruptWakeups: Double(info.ri_interrupt_wkups))
}

func snapshot(pid: pid_t) throws -> Snapshot {
    guard let id = coalitionID(of: pid) else { throw SampleError.noCoalition(pid) }
    let children = childPIDs(of: pid)
    return Snapshot(time: Date().timeIntervalSince1970, pid: pid, coalition: id, usage: try usage(ofCoalition: id),
                    processes: ([pid] + children.sorted()).compactMap(processSample))
}

// MARK: - Reports

func format(_ value: Double, _ digits: Int = 1) -> String { String(format: "%.\(digits)f", value) }

struct Report: Codable {
    var label: String?
    var seconds: Double
    var delta: Usage
    var footprintStartMB: Double
    var footprintEndMB: Double
    var footprintPeakMB: Double
    var processes: [ProcessReport]

    struct ProcessReport: Codable {
        var pid: Int32
        var name: String
        var status: String // "running", "started", "exited"
        var cpuSeconds: Double
        var cpuEnergyJ: Double
        var idleWakeups: Double
        var interruptWakeups: Double
        var footprintMB: Double
        var peakFootprintMB: Double
    }

    init(label: String?, before: Snapshot, after: Snapshot, peaks: [Int32: Double] = [:], coalitionPeakMB: Double? = nil) {
        self.label = label
        seconds = after.time - before.time
        delta = after.usage - before.usage
        footprintStartMB = before.usage.footprintMB
        footprintEndMB = after.usage.footprintMB
        footprintPeakMB = max(coalitionPeakMB ?? 0, before.usage.footprintMB, after.usage.footprintMB)
        var list: [ProcessReport] = []
        let old = Dictionary(uniqueKeysWithValues: before.processes.map { ($0.pid, $0) })
        for process in after.processes {
            let base = old[process.pid]
            list.append(ProcessReport(pid: process.pid, name: process.name, status: base == nil ? "started" : "running",
                                      cpuSeconds: process.cpuSeconds - (base?.cpuSeconds ?? 0),
                                      cpuEnergyJ: process.cpuEnergyJ - (base?.cpuEnergyJ ?? 0),
                                      idleWakeups: process.idleWakeups - (base?.idleWakeups ?? 0),
                                      interruptWakeups: process.interruptWakeups - (base?.interruptWakeups ?? 0),
                                      footprintMB: process.footprintMB, peakFootprintMB: max(peaks[process.pid] ?? 0, process.footprintMB)))
        }
        let current = Set(after.processes.map(\.pid))
        for process in before.processes where !current.contains(process.pid) {
            list.append(ProcessReport(pid: process.pid, name: process.name, status: "exited", cpuSeconds: 0, cpuEnergyJ: 0,
                                      idleWakeups: 0, interruptWakeups: 0, footprintMB: 0,
                                      peakFootprintMB: max(peaks[process.pid] ?? 0, process.footprintMB)))
        }
        processes = list
    }

    func print() {
        let d = delta
        let seconds = max(self.seconds, 0.001)
        if let label { Swift.print("== \(label)") }
        Swift.print("window        \(format(self.seconds)) s")
        Swift.print("energy        \(format(d.energyJ, 2)) J  (CPU \(format(d.cpuEnergyJ, 2)) J, GPU \(format(d.gpuEnergyJ, 2)) J, ANE \(format(d.aneEnergyJ, 2)) J)"
                    + "  = \(format(d.energyJ / seconds * 1000, 0)) mW average")
        Swift.print("cpu time      \(format(d.cpuSeconds, 2)) s  (P-cores \(format(d.pCoreSeconds, 2)) s)   gpu \(format(d.gpuSeconds, 2)) s   ane \(format(d.aneSeconds, 3)) s")
        Swift.print("wakeups       \(format(d.idleWakeups + d.interruptWakeups, 0))  (\(format((d.idleWakeups + d.interruptWakeups) / seconds, 1))/s;"
                    + " package idle \(format(d.idleWakeups, 0)), interrupt \(format(d.interruptWakeups, 0)))")
        Swift.print("disk          read \(format(d.bytesRead / 1_048_576)) MB, written \(format(d.bytesWritten / 1_048_576)) MB")
        Swift.print("processes     \(format(d.tasksStarted, 0)) started, \(format(d.tasksExited, 0)) exited")
        Swift.print("memory        \(format(footprintStartMB, 0)) → \(format(footprintEndMB, 0)) MB (peak \(format(footprintPeakMB, 0)) MB)")
        for p in processes {
            Swift.print("  \(String(p.pid).padding(toLength: 6, withPad: " ", startingAt: 0)) \(p.name.padding(toLength: 13, withPad: " ", startingAt: 0))"
                        + " \(p.status.padding(toLength: 8, withPad: " ", startingAt: 0)) cpu \(format(p.cpuSeconds, 2)) s, \(format(p.cpuEnergyJ, 2)) J,"
                        + " wakeups \(format(p.idleWakeups + p.interruptWakeups, 0)), memory \(format(p.footprintMB, 0)) MB (peak \(format(p.peakFootprintMB, 0)))")
        }
    }
}

// MARK: - Commands

func option(_ name: String, in args: [String]) -> String? {
    guard let index = args.firstIndex(of: name), index + 1 < args.count else { return nil }
    return args[index + 1]
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(2)
}

func targetPID(_ args: [String]) -> pid_t {
    if let value = option("--pid", in: args) {
        guard let pid = pid_t(value) else { fail("bad --pid") }
        return pid
    }
    guard let pid = findApp() else { fail(SampleError.noApp.description) }
    return pid
}

func write<T: Encodable>(_ value: T, to path: String?) {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    guard let data = try? encoder.encode(value) else { return }
    if let path { FileManager.default.createFile(atPath: path, contents: data) } else { print(String(decoding: data, as: UTF8.self)) }
}

func read(_ path: String) -> Snapshot {
    guard let data = FileManager.default.contents(atPath: path), let snap = try? JSONDecoder().decode(Snapshot.self, from: data) else {
        fail("Couldn't read a snapshot from \(path)")
    }
    return snap
}

setvbuf(stdout, nil, _IOLBF, 0) // results appear as they come, also when written to a file
let args = Array(CommandLine.arguments.dropFirst())
switch args.first {
case "snap":
    do { write(try snapshot(pid: targetPID(args)), to: nil) } catch { fail("\(error)") }
case "diff":
    guard args.count >= 3 else { fail("usage: vp-energy diff before.json after.json [--label text] [--json out.json]") }
    let before = read(args[1]), after = read(args[2])
    guard before.coalition == after.coalition else { fail("The app was relaunched between the two snapshots (different coalitions).") }
    let report = Report(label: option("--label", in: args), before: before, after: after)
    report.print()
    if let path = option("--json", in: args) { write(report, to: path) }
case "watch":
    let pid = targetPID(args)
    let seconds = Double(option("--seconds", in: args) ?? "600") ?? 600
    let interval = Double(option("--interval", in: args) ?? "2") ?? 2
    do {
        let start = try snapshot(pid: pid)
        var peaks: [Int32: Double] = [:]
        var coalitionPeak = start.usage.footprintMB
        var last = start
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            Thread.sleep(forTimeInterval: min(interval, max(deadline.timeIntervalSinceNow, 0.01)))
            guard let sample = try? snapshot(pid: pid), sample.coalition == start.coalition else { fail("VoiceParty quit or relaunched during the window.") }
            for process in sample.processes { peaks[process.pid] = max(peaks[process.pid] ?? 0, process.footprintMB) }
            coalitionPeak = max(coalitionPeak, sample.usage.footprintMB)
            last = sample
        }
        let report = Report(label: option("--label", in: args), before: start, after: last, peaks: peaks, coalitionPeakMB: coalitionPeak)
        report.print()
        if let path = option("--json", in: args) { write(report, to: path) }
    } catch {
        fail("\(error)")
    }
case "trace":
    // One line per interval: where the energy went, when (shows how late the kernel attributes GPU energy).
    let pid = targetPID(args)
    let seconds = Double(option("--seconds", in: args) ?? "30") ?? 30
    let interval = Double(option("--interval", in: args) ?? "0.5") ?? 0.5
    do {
        let start = try snapshot(pid: pid)
        var last = start
        print("     t   cpu J   gpu J   ane J   cpu s   gpu s  wakeups")
        while Date().timeIntervalSince1970 - start.time < seconds {
            Thread.sleep(forTimeInterval: interval)
            let now = try snapshot(pid: pid)
            let d = now.usage - last.usage
            print(String(format: "%6.1f %7.3f %7.3f %7.3f %7.3f %7.3f %8.0f", now.time - start.time, d.cpuEnergyJ, d.gpuEnergyJ, d.aneEnergyJ,
                         d.cpuSeconds, d.gpuSeconds, d.idleWakeups + d.interruptWakeups))
            last = now
        }
    } catch {
        fail("\(error)")
    }
case "idle", "idle-loaded":
    do { try runIdle(app: targetPID(args), args: args, loaded: args.first == "idle-loaded") } catch { fail("\(error)") }
case "routes":
    do { try runRoutes(app: targetPID(args), args: args) } catch { fail("\(error)") }
case "day":
    do { try runDay(app: targetPID(args), args: args) } catch { fail("\(error)") }
case "loads":
    do { try runLoads(app: targetPID(args), args: args) } catch { fail("\(error)") }
case "fixtures":
    let folder = fixturesFolder(args)
    for utterance in [Utterances.asrOnly, Utterances.skip, Utterances.fast, Utterances.strong, Utterances.long] + Utterances.day.map(\.0) {
        print(fixture(utterance, in: folder).path)
    }
default:
    print("""
    usage: vp-energy watch [--seconds 600] [--interval 2] [--pid N] [--label text] [--json out.json]
           vp-energy snap [--pid N] > before.json
           vp-energy diff before.json after.json [--label text] [--json out.json]
           vp-energy trace [--seconds 30] [--interval 0.5]   one line per interval (when the energy is billed)
    scenarios (a development build with DebugURLs on; nothing else using the model servers):
           vp-energy idle [--seconds 600]          models as they are
           vp-energy idle-loaded [--seconds 600]   models loaded and held
           vp-energy routes [--repeats 5]          energy + latency per dictation: ASR only, skip, fast, strong, long; warm and cold
                            [--only fast,strong] [--warm-only]
           vp-energy loads [--repeats 3]           loading the fast model, the strong one, both (energy, time to ready)
           vp-energy day [--gap 20]                a dozen varied dictations, three after the models unloaded
           vp-energy fixtures                      just make the audio (say)
    common: [--label text] [--json out.json] [--fixtures dir]
    """)
    exit(args.isEmpty ? 0 : 2)
}
