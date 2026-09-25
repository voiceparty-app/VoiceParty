import Foundation

/// Optional, opt-in downloads that make VoiceParty better. Nothing here ships inside the app: each one is fetched
/// only when the user chooses it, pinned to an exact version, verified (a file's SHA-256, or a digest of the whole
/// folder for the runtime and Parakeet) when installed and again before each use, and runs only on this Mac.
public struct Enhancement: Sendable, Identifiable, Equatable {
    public var id: String
    public var name: String
    /// One line: what gets better.
    public var summary: String
    /// Plain-language explanation shown before downloading.
    public var details: String
    public var files: [EnhancementFile]
    public var requires: [String]
    /// Attribution the model's license asks for.
    public var credit: String?
    /// The license it's downloaded under, linked from its card.
    public var licenseName: String?
    public var licenseURL: URL?
    /// Minimum memory for a good experience (bytes); 0 = no requirement.
    public var recommendedMemory: UInt64
    /// Hidden support pieces (the local runtime) are installed automatically, not shown as cards.
    public var isSupport: Bool
    /// Installed by a library's own downloader (e.g. FluidAudio for Parakeet) instead of `files`.
    public var external: External?

    public struct External: Sendable, Equatable {
        /// Folder (relative to the enhancements root) the library installs into.
        public var folder: String
        /// A file or folder inside it whose presence means "installed".
        public var check: String
        public var approximateBytes: Int64
        /// Where the library downloads from, and the exact commit (never a moving branch).
        public var repository: String?
        public var revision: String?
        /// `FileIntegrity.treeDigest` of the installed folder (without `bookkeeping`), checked after download and before loading.
        public var treeSHA256: String?

        /// Files the downloader writes for itself (FluidAudio's revision marker).
        public static let bookkeeping: Set<String> = [".fluidaudio-revision"]

        public init(folder: String, check: String, approximateBytes: Int64, repository: String? = nil, revision: String? = nil,
                    treeSHA256: String? = nil) {
            self.folder = folder
            self.check = check
            self.approximateBytes = approximateBytes
            self.repository = repository
            self.revision = revision
            self.treeSHA256 = treeSHA256
        }
    }

    public init(id: String, name: String, summary: String, details: String, files: [EnhancementFile], requires: [String] = [],
                credit: String? = nil, licenseName: String? = nil, licenseURL: URL? = nil, recommendedMemory: UInt64 = 0,
                isSupport: Bool = false, external: External? = nil) {
        self.external = external
        self.licenseName = licenseName
        self.licenseURL = licenseURL
        self.id = id
        self.name = name
        self.summary = summary
        self.details = details
        self.files = files
        self.requires = requires
        self.credit = credit
        self.recommendedMemory = recommendedMemory
        self.isSupport = isSupport
    }

    public var bytes: Int64 { files.reduce(0) { $0 + $1.bytes } }
    /// Download size to show (external installers report an estimate).
    public var displayBytes: Int64 { external?.approximateBytes ?? bytes }

    public func isInstalled(in root: URL) -> Bool {
        if let external {
            return FileManager.default.fileExists(atPath: root.appending(path: external.folder + "/" + external.check).path)
        }
        return files.allSatisfy { file in
            let url = root.appending(path: file.installedMarkerPath)
            guard let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int64 else { return false }
            return file.archive || size == file.bytes
        }
    }
}

public struct EnhancementFile: Sendable, Equatable {
    public var url: URL
    public var sha256: String
    public var bytes: Int64
    /// Where the download goes, relative to the enhancements folder (for archives: the folder to extract into).
    public var path: String
    /// A .tar.gz that gets extracted into `path`.
    public var archive: Bool
    /// For archives: a file inside the extracted folder that proves installation.
    public var archiveCheck: String?
    /// For archives: `FileIntegrity.treeDigest` of the extracted folder, checked after extracting and before each use.
    public var treeSHA256: String?

    public init(url: URL, sha256: String, bytes: Int64, path: String, archive: Bool, archiveCheck: String? = nil, treeSHA256: String? = nil) {
        self.url = url
        self.sha256 = sha256
        self.bytes = bytes
        self.path = path
        self.archive = archive
        self.archiveCheck = archiveCheck
        self.treeSHA256 = treeSHA256
    }

    var installedMarkerPath: String { archive ? path + "/" + (archiveCheck ?? "") : path }
}

public enum EnhancementID {
    public static let localRuntime = "local-ai-runtime"
    public static let fastCleanup = "cleanup-fast"
    public static let strongCleanup = "cleanup-strong"
    public static let parakeet = "speech-parakeet"
}

public enum EnhancementCatalog {
    public static let all: [Enhancement] = [
        Enhancement(
            id: EnhancementID.localRuntime,
            name: "Local AI engine",
            summary: "Runs downloaded AI models on this Mac.",
            details: "llama.cpp, an open-source engine that runs AI models on your Mac's GPU. It only listens to VoiceParty on this computer.",
            files: [EnhancementFile(
                url: URL(string: "https://github.com/ggml-org/llama.cpp/releases/download/b11146/llama-b11146-bin-macos-arm64.tar.gz")!,
                sha256: "1ad3f9eff80edb9dbef4259ad564d1720612ef7eea48fa4afed0e54f5f3d5711",
                bytes: 11_189_714, path: "runtime", archive: true, archiveCheck: "llama-b11146/llama-server",
                treeSHA256: "3e478b0f1b29c5b85e8d10f90c8bb8d186b92ad3ae34b79b095ed48dea04e170")],
            credit: "llama.cpp", licenseName: "MIT", licenseURL: URL(string: "https://github.com/ggml-org/llama.cpp/blob/master/LICENSE"),
            isSupport: true
        ),
        Enhancement(
            id: EnhancementID.fastCleanup,
            name: "Fast cleanup",
            summary: "Cleaner text in about a tenth of a second.",
            details: "A small AI model made specifically for tidying dictation: it removes \"um\"s and false starts, fixes punctuation and writes numbers properly, while keeping your words. Faster and more accurate than Apple Intelligence on real dictation.",
            files: [EnhancementFile(
                url: URL(string: "https://huggingface.co/superwhisper/s1-mini-GGUF/resolve/34add00a48a2e5d24e5a4ee5405a99620a3a240c/s1-mini-q4_k_m.gguf")!,
                sha256: "3b41ebe2502cbd03e811d5d16b022f5ab551eda58d62597d152f89535003c634",
                bytes: 484_219_808, path: "models/s1-mini-q4_k_m.gguf", archive: false)],
            requires: [EnhancementID.localRuntime],
            credit: "S1-mini by Superwhisper",
            licenseName: "Apache-2.0 + naming terms", licenseURL: URL(string: "https://huggingface.co/superwhisper/s1-mini-GGUF/blob/main/LICENSE"),
            recommendedMemory: 8 << 30
        ),
        Enhancement(
            id: EnhancementID.strongCleanup,
            name: "Smart cleanup for your words & code",
            summary: "Handles corrections, your dictionary, emails and code.",
            details: "A larger general AI model (Qwen3 4B) used when a dictation needs more thought: \"actually, make that six\", names from your dictionary, email layout, and code or file names. Needs about 3 GB of memory while VoiceParty runs.",
            files: [EnhancementFile(
                url: URL(string: "https://huggingface.co/unsloth/Qwen3-4B-Instruct-2507-GGUF/resolve/a06e946bb6b655725eafa393f4a9745d460374c9/Qwen3-4B-Instruct-2507-Q4_K_M.gguf")!,
                sha256: "3605803b982cb64aead44f6c1b2ae36e3acdb41d8e46c8a94c6533bc4c67e597",
                bytes: 2_497_281_120, path: "models/Qwen3-4B-Instruct-2507-Q4_K_M.gguf", archive: false)],
            requires: [EnhancementID.localRuntime],
            credit: "Qwen3 by Alibaba Cloud",
            licenseName: "Apache-2.0", licenseURL: URL(string: "https://huggingface.co/Qwen/Qwen3-4B-Instruct-2507/blob/main/LICENSE"),
            recommendedMemory: 16 << 30
        ),
        Enhancement(
            id: EnhancementID.parakeet,
            name: "More accurate speech recognition",
            summary: "Fewer misheard words, and it finishes in a twentieth of a second.",
            details: "NVIDIA's Parakeet speech model running on your Mac's Neural Engine. On real dictation it misheard fewer words than Apple's built-in engines (10.6% vs 11.4% word errors) and transcribes about three times faster. English only. Once downloaded, it becomes your speech engine; you can switch back in Settings.",
            files: [],
            credit: "NVIDIA Parakeet TDT 0.6B v2, converted for Apple devices by FluidInference",
            licenseName: "CC-BY-4.0", licenseURL: URL(string: "https://creativecommons.org/licenses/by/4.0/"),
            external: .init(folder: "parakeet-tdt-0.6b-v2", check: "Encoder.mlmodelc", approximateBytes: 473_000_000,
                            repository: "FluidInference/parakeet-tdt-0.6b-v2-coreml",
                            revision: "ee09c569f73759e6d44c9bd16766f477b2b36d39",
                            treeSHA256: "7922d8f055d2f9f4119fcb01f0991bfa95aca4a0bb289c0bcbcbf1b6b37031ce")
        ),
    ]

    public static func enhancement(_ id: String) -> Enhancement? { all.first { $0.id == id } }

    /// The enhancement and everything it needs, dependencies first.
    public static func installOrder(for id: String) -> [Enhancement] {
        guard let target = enhancement(id) else { return [] }
        var order: [Enhancement] = []
        for dependency in target.requires {
            for item in installOrder(for: dependency) where !order.contains(item) { order.append(item) }
        }
        order.append(target)
        return order
    }

    public static func totalBytes(for id: String) -> Int64 {
        installOrder(for: id).reduce(0) { $0 + $1.displayBytes }
    }

    /// What the card shows: the enhancement itself plus whatever it needs that isn't installed yet.
    public static func downloadBytes(for id: String, installed: Set<String>) -> Int64 {
        installOrder(for: id).filter { $0.id == id || !installed.contains($0.id) }.reduce(0) { $0 + $1.displayBytes }
    }
}
