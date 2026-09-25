import CryptoKit
import Foundation

/// Checks that downloaded Enhancements are still exactly what was verified: a model file by its SHA-256,
/// the runtime folder by one digest over every file and link in it. Run before each server start, so a
/// library or model swapped in Application Support afterwards is never loaded.
public enum FileIntegrity {
    public enum Failure: Error, Equatable {
        case unreadable(String)
        /// A link pointing outside the folder (absolute, or climbing out with "..").
        case linkEscapes(String)
    }

    /// SHA-256 of a file, streamed (models are gigabytes).
    public static func sha256(of file: URL) throws -> String {
        guard let handle = try? FileHandle(forReadingFrom: file) else { throw Failure.unreadable(file.lastPathComponent) }
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 8 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        return hex(hasher.finalize())
    }

    /// One digest over the folder: each file's relative path and content hash, and each link's path and target,
    /// in sorted order. Links must stay inside the folder.
    /// `ignoring`: top-level bookkeeping files a downloader writes (not loaded, not part of what's verified).
    public static func treeDigest(of folder: URL, ignoring: Set<String> = []) throws -> String {
        let fm = FileManager.default
        let base = folder.standardizedFileURL.path
        guard let paths = fm.subpaths(atPath: base) else { throw Failure.unreadable(folder.lastPathComponent) }
        var lines: [String] = []
        for relative in paths.sorted() where !ignoring.contains(relative) {
            let path = base + "/" + relative
            let attributes = try fm.attributesOfItem(atPath: path)
            switch attributes[.type] as? FileAttributeType {
            case .typeSymbolicLink?:
                let target = try fm.destinationOfSymbolicLink(atPath: path)
                // Only links within the folder ("libllama.0.dylib" -> "libllama.0.5.0.dylib").
                guard !target.hasPrefix("/"), !target.split(separator: "/").contains("..") else { throw Failure.linkEscapes(relative) }
                lines.append("L \(relative) -> \(target)")
            case .typeRegular?:
                lines.append("F \(relative) \(try sha256(of: URL(fileURLWithPath: path)))")
            case .typeDirectory?:
                lines.append("D \(relative)")
            default:
                throw Failure.unreadable(relative) // sockets, devices: never part of a download
            }
        }
        return hex(SHA256.hash(data: Data(lines.joined(separator: "\n").utf8)))
    }

    static func hex<D: Sequence>(_ digest: D) -> String where D.Element == UInt8 {
        digest.map { String(format: "%02x", $0) }.joined()
    }
}

extension Enhancement {
    /// Every file is still the verified download. Slow for big models (~1 s per 2.5 GB): call off the main thread.
    public func filesAreIntact(in root: URL) -> Bool {
        if let external {
            guard let pinned = external.treeSHA256 else { return false }
            return (try? FileIntegrity.treeDigest(of: root.appending(path: external.folder), ignoring: Enhancement.External.bookkeeping)) == pinned
        }
        return files.allSatisfy { file in
            let url = root.appending(path: file.path)
            if file.archive {
                guard let pinned = file.treeSHA256 else { return false }
                return (try? FileIntegrity.treeDigest(of: url)) == pinned
            }
            return (try? FileIntegrity.sha256(of: url)) == file.sha256
        }
    }
}
