import Foundation
import GRDB

/// The portable backup file (`voiceparty-profile.json`). Documented in docs/profile-schema.md.
public struct VoicePartyProfile: Codable, Sendable, Equatable {
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    public var app: String
    public var exportedAt: Date
    public var dictionary: [DictionaryEntry]
    public var snippets: [Snippet]
    public var transforms: [TransformDefinition]
    /// Preferences; shortcuts are included only when the user opts in (they're per-keyboard).
    public var settings: AppSettings?

    public init(dictionary: [DictionaryEntry], snippets: [Snippet], transforms: [TransformDefinition], settings: AppSettings?, exportedAt: Date = Date()) {
        schemaVersion = Self.currentSchemaVersion
        app = "VoiceParty"
        self.exportedAt = exportedAt
        self.dictionary = dictionary
        self.snippets = snippets
        self.transforms = transforms
        self.settings = settings
    }

    public static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    public static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    public func encoded() throws -> Data { try Self.encoder.encode(self) }

    public static func decode(_ data: Data) throws -> VoicePartyProfile {
        let profile = try decoder.decode(VoicePartyProfile.self, from: data)
        guard profile.schemaVersion <= currentSchemaVersion else {
            throw ProfileError.newerSchema(profile.schemaVersion)
        }
        return profile
    }
}

public enum ProfileError: Error, LocalizedError {
    case newerSchema(Int)
    case wisprDatabaseNotFound
    case wisprTableMissing

    public var errorDescription: String? {
        switch self {
        case .newerSchema(let v): "This profile was made by a newer VoiceParty (schema \(v)). Update VoiceParty to import it."
        case .wisprDatabaseNotFound: "Couldn't find Wispr Flow's data on this Mac."
        case .wisprTableMissing: "Wispr Flow's database doesn't have a Dictionary table."
        }
    }
}

public struct MergeSummary: Sendable, Equatable {
    public var dictionaryAdded = 0
    public var dictionaryUpdated = 0
    public var snippetsAdded = 0
    public var snippetsUpdated = 0
    public var transformsAdded = 0

    public var description: String {
        "\(dictionaryAdded) words added, \(dictionaryUpdated) updated · \(snippetsAdded) snippets added, \(snippetsUpdated) updated"
            + (transformsAdded > 0 ? " · \(transformsAdded) transforms added" : "")
    }
}

/// Merges incoming personalization into the store. Same phrase / trigger (ignoring case) = same item.
public enum ProfileMerger {
    public static func merge(dictionary incoming: [DictionaryEntry], snippets incomingSnippets: [Snippet],
                             transforms incomingTransforms: [TransformDefinition] = [], into store: VoicePartyStore) throws -> MergeSummary {
        var summary = MergeSummary()
        try store.dbQueue.write { db in
            let existing = try DictionaryEntry.fetchAll(db)
            var byPhrase = Dictionary(existing.map { ($0.phrase.lowercased(), $0) }, uniquingKeysWith: { a, _ in a })
            for entry in incoming where !entry.phrase.trimmingCharacters(in: .whitespaces).isEmpty {
                let key = entry.phrase.lowercased()
                if var current = byPhrase[key] {
                    let newReplacement = entry.replacement ?? current.replacement
                    let starred = current.isStarred || entry.isStarred
                    let betterCasing = entry.phrase.filter(\.isUppercase).count > current.phrase.filter(\.isUppercase).count
                    guard newReplacement != current.replacement || starred != current.isStarred || betterCasing else { continue }
                    current.replacement = newReplacement
                    current.isStarred = starred
                    // Keep whichever spelling carries more capitals ("iPhone" beats an imported "iphone").
                    if entry.phrase.filter(\.isUppercase).count > current.phrase.filter(\.isUppercase).count {
                        current.phrase = entry.phrase
                    }
                    try current.update(db)
                    byPhrase[key] = current
                    summary.dictionaryUpdated += 1
                } else {
                    var fresh = entry
                    fresh.id = UUID()
                    try fresh.insert(db)
                    byPhrase[key] = fresh
                    summary.dictionaryAdded += 1
                }
            }

            let existingSnippets = try Snippet.fetchAll(db)
            var byTrigger = Dictionary(existingSnippets.map { (TextTools.normalizePhrase($0.trigger), $0) }, uniquingKeysWith: { a, _ in a })
            for snippet in incomingSnippets {
                let key = TextTools.normalizePhrase(snippet.trigger)
                guard !key.isEmpty else { continue }
                if var current = byTrigger[key] {
                    guard current.expansion != snippet.expansion else { continue }
                    current.expansion = snippet.expansion
                    try current.update(db)
                    byTrigger[key] = current
                    summary.snippetsUpdated += 1
                } else {
                    var fresh = snippet
                    fresh.id = UUID()
                    try fresh.insert(db)
                    byTrigger[key] = fresh
                    summary.snippetsAdded += 1
                }
            }

            let existingTransforms = try TransformDefinition.fetchAll(db)
            for transform in incomingTransforms where transform.kind == .custom {
                guard !existingTransforms.contains(where: { $0.name == transform.name && $0.instructions == transform.instructions }) else { continue }
                var fresh = transform
                fresh.id = UUID()
                if existingTransforms.contains(where: { $0.slot == fresh.slot }) { fresh.slot = nil }
                try fresh.insert(db)
                summary.transformsAdded += 1
            }
        }
        return summary
    }
}

/// Bulk import formats (CSV word lists, JSON snippet lists).
public enum BulkImport {
    /// One entry per line: `phrase` or `phrase,replacement`. A header line `phrase,replacement` is skipped.
    public static func dictionary(csv: String) -> [DictionaryEntry] {
        csv.split(whereSeparator: \.isNewline).compactMap { line in
            let fields = parseCSVLine(String(line))
            guard let phrase = fields.first?.trimmingCharacters(in: .whitespaces), !phrase.isEmpty else { return nil }
            if phrase.lowercased() == "phrase" { return nil }
            let replacement = fields.count > 1 ? fields[1].trimmingCharacters(in: .whitespaces) : nil
            return DictionaryEntry(phrase: phrase, replacement: replacement, source: .imported)
        }
    }

    /// A JSON array of `{"name": trigger, "text": expansion}` (also accepts `trigger`/`expansion`).
    public static func snippets(json: Data) throws -> [Snippet] {
        struct Item: Decodable {
            var name: String?, text: String?, trigger: String?, expansion: String?
        }
        return try JSONDecoder().decode([Item].self, from: json).compactMap { item in
            guard let trigger = item.name ?? item.trigger, let text = item.text ?? item.expansion else { return nil }
            return Snippet(trigger: trigger, expansion: text)
        }
    }

    static func parseCSVLine(_ line: String) -> [String] {
        var fields: [String] = []
        var current = ""
        var quoted = false
        var iterator = line.makeIterator()
        while let ch = iterator.next() {
            if ch == "\"" {
                if quoted, let next = iterator.next() {
                    if next == "\"" { current.append("\"") } else { quoted = false; if next == "," { fields.append(current); current = "" } else { current.append(next) } }
                } else {
                    quoted.toggle()
                }
            } else if ch == ",", !quoted {
                fields.append(current)
                current = ""
            } else {
                current.append(ch)
            }
        }
        fields.append(current)
        return fields
    }
}

/// Reads dictionary words, replacements and snippets from Wispr Flow's local database.
/// Works on a temporary copy so Wispr Flow's files are never touched.
public enum WisprFlowImporter {
    public static var defaultDatabaseURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/Application Support/Wispr Flow/flow.sqlite")
    }

    public static func read(databaseURL: URL = defaultDatabaseURL) throws -> (dictionary: [DictionaryEntry], snippets: [Snippet]) {
        let fm = FileManager.default
        guard fm.fileExists(atPath: databaseURL.path) else { throw ProfileError.wisprDatabaseNotFound }

        let tmp = fm.temporaryDirectory.appending(path: "voiceparty-wispr-import-\(UUID().uuidString)")
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tmp) }
        let copy = tmp.appending(path: "flow.sqlite")
        try fm.copyItem(at: databaseURL, to: copy)
        for suffix in ["-wal", "-shm"] {
            let side = URL(fileURLWithPath: databaseURL.path + suffix)
            if fm.fileExists(atPath: side.path) { try? fm.copyItem(at: side, to: URL(fileURLWithPath: copy.path + suffix)) }
        }

        let db = try DatabaseQueue(path: copy.path)
        return try db.read { db in
            guard try db.tableExists("Dictionary") else { throw ProfileError.wisprTableMissing }
            let columns = Set(try db.columns(in: "Dictionary").map(\.name))
            func has(_ c: String) -> Bool { columns.contains(c) }
            let select = ["phrase", "replacement", "isSnippet", "isStarred", "source", "isDeleted", "manualEntry"].filter(has).joined(separator: ", ")
            let rows = try Row.fetchAll(db, sql: "SELECT \(select) FROM Dictionary")

            var words: [DictionaryEntry] = []
            var snippets: [Snippet] = []
            for row in rows {
                if has("isDeleted"), (row["isDeleted"] as Bool?) == true { continue }
                guard let phrase: String = row["phrase"], !phrase.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
                let replacement: String? = has("replacement") ? row["replacement"] : nil
                let isSnippet = has("isSnippet") && (row["isSnippet"] as Bool?) == true
                if isSnippet, let replacement, !replacement.isEmpty {
                    snippets.append(Snippet(trigger: phrase, expansion: replacement))
                } else {
                    let starred = has("isStarred") && (row["isStarred"] as Bool?) == true
                    let source: String? = has("source") ? row["source"] : nil
                    words.append(DictionaryEntry(phrase: phrase, replacement: replacement, source: source == "manual" ? .manual : .imported, isStarred: starred))
                }
            }
            return (words, snippets)
        }
    }
}
