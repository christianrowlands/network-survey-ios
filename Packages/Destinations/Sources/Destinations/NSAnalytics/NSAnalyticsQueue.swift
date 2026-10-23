import Foundation
import GRDB

/// The persisted NS Analytics upload queue: a small SQLite database owned by
/// this package (Application Support, not the user-visible Documents folder).
/// It keeps records until the server accepts them, per-record retry counts for
/// definitive rejections, the batch in flight and the upload state.
public final class NSAnalyticsQueue: Sendable {
    struct Entry: Equatable {
        let id: Int64
        let type: String
        let json: String
        let retryCount: Int
    }

    private let db: DatabaseQueue

    /// Opens (or creates) the queue at `url`; pass nil for an in-memory queue.
    public init(url: URL?) throws {
        if let url {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            db = try DatabaseQueue(path: url.path)
        } else {
            db = try DatabaseQueue()
        }
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1") { db in
            try db.execute(sql: """
                CREATE TABLE record (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    type TEXT NOT NULL,
                    json TEXT NOT NULL,
                    createdAt DOUBLE NOT NULL,
                    retryCount INTEGER NOT NULL DEFAULT 0,
                    batchId TEXT
                );
                CREATE INDEX record_upload ON record(retryCount, id);
                CREATE TABLE batch (id TEXT PRIMARY KEY, startedAt DOUBLE NOT NULL);
                CREATE TABLE meta (key TEXT PRIMARY KEY, value TEXT NOT NULL);
                """)
        }
        try migrator.migrate(db)
    }

    /// The default location in Application Support.
    public static func defaultURL() throws -> URL {
        try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("NSAnalytics", isDirectory: true)
            .appendingPathComponent("upload-queue.sqlite")
    }

    func enqueue(_ records: [(type: String, json: String)], at date: Date = Date()) throws {
        guard !records.isEmpty else { return }
        try db.write { db in
            let statement = try db.makeStatement(sql: "INSERT INTO record (type, json, createdAt) VALUES (?, ?, ?)")
            for record in records {
                try statement.execute(arguments: [record.type, record.json, date.timeIntervalSince1970])
            }
        }
    }

    /// Records at or under the retry cap that are not in a batch in flight, oldest first.
    func uploadable(limit: Int, maxRetryCount: Int) throws -> [Entry] {
        try db.read { db in
            try Row.fetchAll(db, sql: """
                SELECT id, type, json, retryCount FROM record
                WHERE retryCount <= ? AND batchId IS NULL ORDER BY id LIMIT ?
                """, arguments: [maxRetryCount, limit]).map {
                Entry(id: $0["id"], type: $0["type"], json: $0["json"], retryCount: $0["retryCount"])
            }
        }
    }

    /// Records counted toward the "pending" figure (excludes ones past the retry cap).
    public func pendingCount(maxRetryCount: Int = NSAnalyticsUploader.maxRetryCount) throws -> Int {
        try db.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM record WHERE retryCount <= ?", arguments: [maxRetryCount]) ?? 0
        }
    }

    /// Deletes records rejected more often than the cap. Returns how many.
    func purge(overRetryCount maxRetryCount: Int) throws -> Int {
        try db.write { db in
            try db.execute(sql: "DELETE FROM record WHERE retryCount > ?", arguments: [maxRetryCount])
            return db.changesCount
        }
    }

    /// Marks records as part of a batch being uploaded.
    func beginBatch(_ batchID: String, ids: [Int64], at date: Date = Date()) throws {
        try db.write { db in
            try db.execute(sql: "INSERT INTO batch (id, startedAt) VALUES (?, ?)", arguments: [batchID, date.timeIntervalSince1970])
            try db.execute(sql: "UPDATE record SET batchId = ? WHERE id IN (\(ids.map(String.init).joined(separator: ",")))",
                           arguments: [batchID])
        }
    }

    /// The server accepted the batch: its records are done.
    func completeBatch(_ batchID: String) throws -> Int {
        try db.write { db in
            try db.execute(sql: "DELETE FROM record WHERE batchId = ?", arguments: [batchID])
            let count = db.changesCount
            try db.execute(sql: "DELETE FROM batch WHERE id = ?", arguments: [batchID])
            return count
        }
    }

    /// The batch failed: its records return to the queue, with one more retry
    /// counted if the server rejected them definitively.
    func failBatch(_ batchID: String, countRetry: Bool) throws {
        try db.write { db in
            let retry = countRetry ? ", retryCount = retryCount + 1" : ""
            try db.execute(sql: "UPDATE record SET batchId = NULL\(retry) WHERE batchId = ?", arguments: [batchID])
            try db.execute(sql: "DELETE FROM batch WHERE id = ?", arguments: [batchID])
        }
    }

    func batchExists(_ batchID: String) throws -> Bool {
        try db.read { db in try Bool.fetchOne(db, sql: "SELECT 1 FROM batch WHERE id = ?", arguments: [batchID]) ?? false }
    }

    /// Releases batches whose upload never reported back (the app was ended
    /// while a background upload was pending and the system dropped it).
    func releaseStaleBatches(olderThan date: Date) throws {
        try db.write { db in
            let stale = try String.fetchAll(db, sql: "SELECT id FROM batch WHERE startedAt < ?", arguments: [date.timeIntervalSince1970])
            for id in stale {
                try db.execute(sql: "UPDATE record SET batchId = NULL WHERE batchId = ?", arguments: [id])
                try db.execute(sql: "DELETE FROM batch WHERE id = ?", arguments: [id])
            }
        }
    }

    func meta(_ key: String) throws -> String? {
        try db.read { db in try String.fetchOne(db, sql: "SELECT value FROM meta WHERE key = ?", arguments: [key]) }
    }

    func setMeta(_ key: String, _ value: String?) throws {
        try db.write { db in
            if let value {
                try db.execute(sql: "INSERT OR REPLACE INTO meta (key, value) VALUES (?, ?)", arguments: [key, value])
            } else {
                try db.execute(sql: "DELETE FROM meta WHERE key = ?", arguments: [key])
            }
        }
    }

    /// Test hook: the retry counts of all records, by id.
    func retryCounts() throws -> [Int64: Int] {
        try db.read { db in
            Dictionary(uniqueKeysWithValues: try Row.fetchAll(db, sql: "SELECT id, retryCount FROM record").map {
                ($0["id"] as Int64, $0["retryCount"] as Int)
            })
        }
    }
}
