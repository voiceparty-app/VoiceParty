import CryptoKit
import Foundation
import Observation
import VoicePartyCore
import VoicePartyEngines

/// Downloads, verifies, installs and removes opt-in enhancements. The only network access VoiceParty
/// makes, and only when the user clicks Download.
@MainActor
@Observable
final class EnhancementManager {
    enum State: Equatable {
        case notInstalled
        case downloading(progress: Double, detail: String)
        case installing
        case installed
        case failed(String)
    }

    private(set) var states: [String: State] = [:]
    @ObservationIgnored var onChange: (() -> Void)?
    @ObservationIgnored private var tasks: [String: Task<Void, Never>] = [:]

    static var root: URL {
        let dir = Paths.appSupport.appending(path: "Enhancements", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    init() {
        refresh()
    }

    func state(_ id: String) -> State { states[id] ?? .notInstalled }
    func isInstalled(_ id: String) -> Bool { state(id) == .installed }

    func refresh() {
        for enhancement in EnhancementCatalog.all {
            switch states[enhancement.id] {
            case .downloading, .installing: continue
            default: states[enhancement.id] = enhancement.isInstalled(in: Self.root) ? .installed : .notInstalled
            }
        }
    }

    func install(_ id: String) {
        guard tasks[id] == nil else { return }
        tasks[id] = Task { [weak self] in
            guard let self else { return }
            defer { self.tasks[id] = nil }
            do {
                for enhancement in EnhancementCatalog.installOrder(for: id) where !enhancement.isInstalled(in: Self.root) {
                    if let external = enhancement.external {
                        try await self.installExternal(enhancement, external: external)
                    }
                    for file in enhancement.files {
                        try await self.installFile(file, for: id, label: enhancement.name)
                    }
                    self.states[enhancement.id] = .installed
                }
                self.states[id] = .installed
                self.onChange?()
            } catch is CancellationError {
                self.refresh()
            } catch {
                self.states[id] = .failed(error.localizedDescription)
            }
        }
    }

    func cancel(_ id: String) {
        tasks[id]?.cancel()
        tasks[id] = nil
        refresh()
    }

    func remove(_ id: String) {
        guard let enhancement = EnhancementCatalog.enhancement(id) else { return }
        if let external = enhancement.external {
            try? FileManager.default.removeItem(at: Self.root.appending(path: external.folder))
        }
        for file in enhancement.files {
            try? FileManager.default.removeItem(at: Self.root.appending(path: file.path))
        }
        // Remove support pieces nothing else needs.
        let stillNeeded = Set(EnhancementCatalog.all.filter { $0.id != id && isInstalled($0.id) && !$0.isSupport }.flatMap(\.requires))
        for dependency in enhancement.requires where !stillNeeded.contains(dependency) {
            EnhancementCatalog.enhancement(dependency)?.files.forEach { try? FileManager.default.removeItem(at: Self.root.appending(path: $0.path)) }
        }
        refresh()
        onChange?()
    }

    // MARK: - Download + verify

    /// Enhancements a library downloads itself (FluidAudio fetches Parakeet's CoreML models).
    private func installExternal(_ enhancement: Enhancement, external: Enhancement.External) async throws {
        states[enhancement.id] = .downloading(progress: 0, detail: enhancement.name)
        let folder = Self.root.appending(path: external.folder)
        let id = enhancement.id, name = enhancement.name
        switch enhancement.id {
        case EnhancementID.parakeetUnified:
            try await ParakeetUnifiedEngine.download(to: folder) { fraction in
                Task { @MainActor [weak self] in self?.states[id] = .downloading(progress: fraction, detail: name) }
            }
        case EnhancementID.parakeet:
            try await ParakeetEngine.download(to: folder) { fraction in
                Task { @MainActor [weak self] in self?.states[id] = .downloading(progress: fraction, detail: name) }
            }
        default:
            break
        }
        guard enhancement.isInstalled(in: Self.root) else { throw EnhancementError.extractFailed }
        let root = Self.root
        guard await Task.detached(priority: .utility, operation: { enhancement.filesAreIntact(in: root) }).value else {
            try? FileManager.default.removeItem(at: folder)
            throw EnhancementError.checksumMismatch(enhancement.name)
        }
    }

    private func installFile(_ file: EnhancementFile, for id: String, label: String) async throws {
        states[id] = .downloading(progress: 0, detail: label)
        let temporary = try await Downloader.download(file.url, expectedBytes: file.bytes) { [weak self] fraction in
            Task { @MainActor in self?.states[id] = .downloading(progress: fraction, detail: label) }
        }
        defer { try? FileManager.default.removeItem(at: temporary) }
        try Task.checkCancellation()
        states[id] = .installing
        let digest = try await Task.detached(priority: .utility) { try FileIntegrity.sha256(of: temporary) }.value
        guard digest == file.sha256 else { throw EnhancementError.checksumMismatch(label) }

        let destination = Self.root.appending(path: file.path)
        let fm = FileManager.default
        try? fm.removeItem(at: destination)
        if file.archive {
            try fm.createDirectory(at: destination, withIntermediateDirectories: true)
            try Self.run("/usr/bin/tar", ["-xzf", temporary.path, "-C", destination.path])
            // What was unpacked is exactly the pinned build (checked again before every start).
            let tree = try await Task.detached(priority: .utility) { try FileIntegrity.treeDigest(of: destination) }.value
            guard tree == file.treeSHA256 else {
                try? fm.removeItem(at: destination)
                throw EnhancementError.checksumMismatch(label)
            }
        } else {
            try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fm.moveItem(at: temporary, to: destination)
        }
    }

    nonisolated static func run(_ tool: String, _ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw EnhancementError.extractFailed }
    }
}

enum EnhancementError: LocalizedError {
    case checksumMismatch(String)
    case extractFailed
    case badResponse(Int)

    var errorDescription: String? {
        switch self {
        case .checksumMismatch(let name): "\(name) didn't match its expected checksum, so it wasn't installed. Try again."
        case .extractFailed: "Couldn't unpack the download."
        case .badResponse(let code): "The download server answered \(code)."
        }
    }
}

/// URLSession download with progress, cancellable through Swift concurrency.
enum Downloader {
    static func download(_ url: URL, expectedBytes: Int64, progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        let delegate = ProgressDelegate(expected: expectedBytes, progress: progress)
        let session = URLSession(configuration: .ephemeral, delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        let (location, response) = try await session.download(from: url, delegate: delegate)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw EnhancementError.badResponse(status) }
        let kept = FileManager.default.temporaryDirectory.appending(path: "voiceparty-\(UUID().uuidString)")
        try FileManager.default.moveItem(at: location, to: kept)
        return kept
    }

    final class ProgressDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
        let expected: Int64
        let progress: @Sendable (Double) -> Void
        private var lastReported = 0.0

        init(expected: Int64, progress: @escaping @Sendable (Double) -> Void) {
            self.expected = expected
            self.progress = progress
        }

        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                        totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
            let total = totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : expected
            let fraction = Double(totalBytesWritten) / Double(max(total, 1))
            if fraction - lastReported >= 0.005 || fraction >= 1 {
                lastReported = fraction
                progress(min(fraction, 1))
            }
        }

        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {}

        /// Hosting sites redirect to their CDNs; only ever to HTTPS (the checksum is verified either way).
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest) async -> URLRequest? {
            request.url?.scheme == "https" ? request : nil
        }
    }
}
