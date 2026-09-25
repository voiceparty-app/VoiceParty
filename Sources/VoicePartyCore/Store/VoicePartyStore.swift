import Foundation
import GRDB

extension HistoryItem: FetchableRecord, PersistableRecord {
    public static let databaseTableName = "history"
}

extension DictionaryEntry: FetchableRecord, PersistableRecord {
    public static let databaseTableName = "dictionaryEntry"
}

extension Snippet: FetchableRecord, PersistableRecord {
    public static let databaseTableName = "snippet"
}

extension MeetingNote: FetchableRecord, PersistableRecord {
    public static let databaseTableName = "meetingNote"
}

extension TransformDefinition: FetchableRecord, PersistableRecord {
    public static let databaseTableName = "transform"
}

/// Local SQLite database (`voiceparty.sqlite`). Everything the user creates lives here; nothing is synced.
public final class VoicePartyStore: Sendable {
    public let dbQueue: DatabaseQueue

    public init(url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var configuration = Configuration()
        // Deleted rows are overwritten, not left readable in free pages.
        configuration.prepareDatabase { try $0.execute(sql: "PRAGMA secure_delete = ON") }
        dbQueue = try DatabaseQueue(path: url.path, configuration: configuration)
        try Self.migrator.migrate(dbQueue)
    }

    public init(inMemory: Void = ()) throws {
        dbQueue = try DatabaseQueue()
        try Self.migrator.migrate(dbQueue)
    }

    static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1") { db in
            try db.create(table: "history") { t in
                t.primaryKey("id", .blob)
                t.column("createdAt", .datetime).notNull().indexed()
                t.column("mode", .text).notNull()
                t.column("status", .text).notNull()
                t.column("appBundleID", .text)
                t.column("appName", .text)
                t.column("windowTitle", .text)
                t.column("url", .text)
                t.column("category", .text).notNull()
                t.column("rawText", .text).notNull()
                t.column("formattedText", .text).notNull()
                t.column("pastedText", .text).notNull()
                t.column("editedText", .text)
                t.column("audioPath", .text)
                t.column("duration", .double).notNull()
                t.column("speechDuration", .double).notNull()
                t.column("wordCount", .integer).notNull()
                t.column("latencyMs", .integer).notNull()
                t.column("engine", .text).notNull()
                t.column("polisher", .text)
                t.column("cleanupLevel", .text).notNull()
                t.column("style", .text).notNull()
                t.column("wordsCorrected", .integer).notNull()
                t.column("dictionaryReplacements", .integer).notNull()
                t.column("revertedAI", .boolean).notNull()
            }
            try db.create(table: "dictionaryEntry") { t in
                t.primaryKey("id", .blob)
                t.column("phrase", .text).notNull()
                t.column("replacement", .text)
                t.column("source", .text).notNull()
                t.column("isStarred", .boolean).notNull()
                t.column("createdAt", .datetime).notNull()
                t.column("useCount", .integer).notNull()
                t.column("lastUsedAt", .datetime)
            }
            try db.create(table: "snippet") { t in
                t.primaryKey("id", .blob)
                t.column("trigger", .text).notNull()
                t.column("expansion", .text).notNull()
                t.column("createdAt", .datetime).notNull()
                t.column("useCount", .integer).notNull()
            }
            try db.create(table: "transform") { t in
                t.primaryKey("id", .blob)
                t.column("kind", .text).notNull()
                t.column("name", .text).notNull()
                t.column("summary", .text).notNull()
                t.column("instructions", .text).notNull()
                t.column("rules", .text).notNull()
                t.column("slot", .integer)
            }
            for transform in TransformDefinition.defaults {
                try transform.insert(db)
            }
        }
        migrator.registerMigration("v2-notetaker") { db in
            try db.create(table: "meetingNote") { t in
                t.primaryKey("id", .blob)
                t.column("title", .text).notNull()
                t.column("startedAt", .datetime).notNull().indexed()
                t.column("endedAt", .datetime)
                t.column("appName", .text)
                t.column("status", .text).notNull()
                t.column("segments", .text).notNull()     // JSON
                t.column("summary", .text)
                t.column("decisions", .text).notNull()    // JSON
                t.column("actionItems", .text).notNull()  // JSON
                t.column("micAudioPath", .text)
                t.column("systemAudioPath", .text)
            }
        }
        migrator.registerMigration("v3-notetaker-calendar-notepad") { db in
            try db.alter(table: "meetingNote") { t in
                t.add(column: "attendees", .text).notNull().defaults(to: "[]") // JSON
                t.add(column: "userNotes", .text)
            }
        }
        migrator.registerMigration("v4-builtin-transform-wording") { db in
            // Built-in transforms keep their ids; refresh their default name/summary unless the user edited them.
            for (id, oldName, name, oldSummary, summary) in [
                (TransformDefinition.builtInPromptEngineer.id, "Prompt Engineer", "AI Prompt", "Constructs optimal prompts",
                 TransformDefinition.builtInPromptEngineer.summary),
                (TransformDefinition.builtInPolish.id, "Polish", "Polish", "Improve clarity and conciseness", TransformDefinition.builtInPolish.summary),
            ] {
                try db.execute(sql: "UPDATE transform SET name = ? WHERE id = ? AND name = ?", arguments: [name, id, oldName])
                try db.execute(sql: "UPDATE transform SET summary = ? WHERE id = ? AND summary = ?", arguments: [summary, id, oldSummary])
            }
        }
        return migrator
    }

    // MARK: Meeting notes

    public func save(_ note: MeetingNote) throws {
        try dbQueue.write { try note.save($0) }
    }

    public func notes() throws -> [MeetingNote] {
        try dbQueue.read { try MeetingNote.order(Column("startedAt").desc).fetchAll($0) }
    }

    public func deleteNote(id: UUID) throws {
        _ = try dbQueue.write { try MeetingNote.deleteOne($0, key: id) }
    }

    // MARK: History

    public func save(_ item: HistoryItem) throws {
        try dbQueue.write { try item.save($0) }
    }

    public func history(limit: Int = 200, search: String? = nil) throws -> [HistoryItem] {
        try dbQueue.read { db in
            var request = HistoryItem.order(Column("createdAt").desc)
            if let search, !search.isEmpty {
                let pattern = "%\(search)%"
                request = request.filter(Column("pastedText").like(pattern) || Column("rawText").like(pattern))
            }
            return try request.limit(limit).fetchAll(db)
        }
    }

    public func allHistory() throws -> [HistoryItem] {
        try dbQueue.read { try HistoryItem.order(Column("createdAt").desc).fetchAll($0) }
    }

    public func lastHistoryItem() throws -> HistoryItem? {
        try dbQueue.read { db in
            try HistoryItem.filter(Column("pastedText") != "").order(Column("createdAt").desc).fetchOne(db)
        }
    }

    /// Replaces a dictation's text in place (Retry transcript).
    public func updateTranscript(id: UUID, raw: String, formatted: String, status: TranscriptStatus, polisher: String?) throws {
        try dbQueue.write { db in
            guard var item = try HistoryItem.fetchOne(db, key: id) else { return }
            item.rawText = raw
            item.formattedText = formatted
            item.pastedText = formatted
            item.status = status
            item.polisher = polisher
            item.revertedAI = false
            item.wordCount = TextTools.wordCount(formatted)
            try item.update(db)
        }
    }

    public func deleteHistory(id: UUID) throws {
        _ = try dbQueue.write { try HistoryItem.deleteOne($0, key: id) }
    }

    public func deleteAllHistory() throws {
        _ = try dbQueue.write { try HistoryItem.deleteAll($0) }
    }

    /// Rebuilds the database file so deleted text doesn't linger in free pages.
    public func vacuum() throws {
        try dbQueue.writeWithoutTransaction { try $0.execute(sql: "VACUUM") }
    }

    /// Deletes rows older than `date`; returns their audio paths so the caller can delete the files.
    @discardableResult
    public func purgeHistory(olderThan date: Date) throws -> [String] {
        try dbQueue.write { db in
            let old = HistoryItem.filter(Column("createdAt") < date)
            let paths = try old.fetchAll(db).compactMap(\.audioPath)
            try old.deleteAll(db)
            return paths
        }
    }

    // MARK: Dictionary

    public func dictionary() throws -> [DictionaryEntry] {
        try dbQueue.read { try DictionaryEntry.order(Column("createdAt").desc).fetchAll($0) }
    }

    public func save(_ entry: DictionaryEntry) throws {
        try dbQueue.write { try entry.save($0) }
    }

    public func deleteDictionaryEntry(id: UUID) throws {
        _ = try dbQueue.write { try DictionaryEntry.deleteOne($0, key: id) }
    }

    /// Deletes several entries in one transaction; returns them as they were (for Undo).
    @discardableResult
    public func deleteDictionaryEntries(ids: [UUID]) throws -> [DictionaryEntry] {
        try dbQueue.write { db in
            let entries = try DictionaryEntry.fetchAll(db, keys: ids)
            _ = try DictionaryEntry.deleteAll(db, keys: ids)
            return entries
        }
    }

    /// Puts deleted entries back exactly as they were.
    public func restoreDictionaryEntries(_ entries: [DictionaryEntry]) throws {
        try dbQueue.write { db in
            for entry in entries { try entry.save(db) }
        }
    }

    /// Adds a word unless a same-spelled entry exists. Returns the inserted entry.
    @discardableResult
    public func addWordIfNew(_ phrase: String, source: DictionaryEntry.Source) throws -> DictionaryEntry? {
        try dbQueue.write { db in
            let exists = try DictionaryEntry.filter(Column("phrase").collating(.nocase) == phrase).fetchCount(db) > 0
            guard !exists else { return nil }
            let entry = DictionaryEntry(phrase: phrase, source: source)
            try entry.insert(db)
            return entry
        }
    }

    public func markDictionaryUsed(ids: [UUID]) throws {
        guard !ids.isEmpty else { return }
        try dbQueue.write { db in
            for id in ids {
                guard var entry = try DictionaryEntry.fetchOne(db, key: id) else { continue }
                entry.useCount += 1
                entry.lastUsedAt = Date()
                try entry.update(db)
            }
        }
    }

    // MARK: Snippets

    public func snippets() throws -> [Snippet] {
        try dbQueue.read { try Snippet.order(Column("createdAt").desc).fetchAll($0) }
    }

    public func save(_ snippet: Snippet) throws {
        try dbQueue.write { try snippet.save($0) }
    }

    public func deleteSnippet(id: UUID) throws {
        _ = try dbQueue.write { try Snippet.deleteOne($0, key: id) }
    }

    // MARK: Transforms

    public func transforms() throws -> [TransformDefinition] {
        try dbQueue.read { try TransformDefinition.order(Column("slot")).fetchAll($0) }
    }

    public func save(_ transform: TransformDefinition) throws {
        try dbQueue.write { try transform.save($0) }
    }

    public func deleteTransform(id: UUID) throws {
        _ = try dbQueue.write { try TransformDefinition.deleteOne($0, key: id) }
    }

    public func resetTransformsToDefaults() throws {
        try dbQueue.write { db in
            try TransformDefinition.deleteAll(db)
            for transform in TransformDefinition.defaults { try transform.insert(db) }
        }
    }
}
