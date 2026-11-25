import Foundation
import GRDB

/// The outcome of adding or editing a watchlist entry.
public enum WatchlistSaveResult: Sendable, Equatable {
    case saved(WatchlistEntry)
    /// Another entry already watches the same SSID and BSSID.
    case duplicate
    /// Neither an SSID nor a BSSID was given.
    case invalid
}

/// A watched network with how often and when it was last seen.
public struct WatchlistEntrySummary: Sendable, Equatable, Identifiable {
    public var entry: WatchlistEntry
    public var sightings: Int
    public var lastSeen: Date?
    /// dBm of the latest sighting, nil when unknown or never seen.
    public var lastRssi: Int?
    public var id: String { entry.uuid }

    public init(entry: WatchlistEntry, sightings: Int, lastSeen: Date?, lastRssi: Int?) {
        self.entry = entry
        self.sightings = sightings
        self.lastSeen = lastSeen
        self.lastRssi = lastRssi
    }
}

/// The sightings of one watched network, for the history screen.
public struct WatchlistHistoryGroup: Sendable, Equatable, Identifiable {
    public var entry: WatchlistEntry
    public var sightings: Int
    public var lastSeen: Date
    /// The strongest signal of any sighting, nil when none reported one.
    public var bestRssi: Int?
    public var id: String { entry.uuid }

    public init(entry: WatchlistEntry, sightings: Int, lastSeen: Date, bestRssi: Int?) {
        self.entry = entry
        self.sightings = sightings
        self.lastSeen = lastSeen
        self.bestRssi = bestRssi
    }
}

/// Read queries for the watchlist screens, for `SurveyStore.observe`.
public enum WatchlistQueries {
    /// Newest first.
    public static func entries(_ db: Database) throws -> [WatchlistEntry] {
        try WatchlistEntry.order(sql: "createdAt DESC, id DESC").fetchAll(db)
    }

    public static func summaries(_ db: Database) throws -> [WatchlistEntrySummary] {
        let rows = try Row.fetchAll(db, sql: """
            SELECT e.*, COUNT(h.id) AS sightings, MAX(h.timestamp) AS lastSeen,
                   (SELECT rssi FROM watchlistHit WHERE entryId = e.id ORDER BY timestamp DESC, id DESC LIMIT 1) AS lastRssi
            FROM watchlistEntry e LEFT JOIN watchlistHit h ON h.entryId = e.id
            GROUP BY e.id ORDER BY e.createdAt DESC, e.id DESC
            """)
        return try rows.map { row in
            WatchlistEntrySummary(
                entry: try WatchlistEntry(row: row), sightings: row["sightings"], lastSeen: row["lastSeen"],
                lastRssi: row["lastRssi"]
            )
        }
    }

    /// One group per watched network that was seen, most recent first.
    public static func historyGroups(_ db: Database) throws -> [WatchlistHistoryGroup] {
        let rows = try Row.fetchAll(db, sql: """
            SELECT e.*, COUNT(h.id) AS sightings, MAX(h.timestamp) AS lastSeen, MAX(h.rssi) AS bestRssi
            FROM watchlistHit h JOIN watchlistEntry e ON e.id = h.entryId
            GROUP BY e.id ORDER BY lastSeen DESC
            """)
        return try rows.map { row in
            WatchlistHistoryGroup(
                entry: try WatchlistEntry(row: row), sightings: row["sightings"], lastSeen: row["lastSeen"],
                bestRssi: row["bestRssi"]
            )
        }
    }

    /// How many watched networks were seen in one survey.
    public static func networksSeen(_ db: Database, missionID: String) throws -> Int {
        try Int.fetchOne(db, sql: "SELECT COUNT(DISTINCT entryId) FROM watchlistHit WHERE missionId = ?",
                         arguments: [missionID]) ?? 0
    }

    /// Sightings newest first; every entry's when `entryID` is nil.
    public static func hits(_ db: Database, entryID: Int64? = nil) throws -> [WatchlistHit] {
        var request = WatchlistHit.order(sql: "timestamp DESC, id DESC")
        if let entryID { request = request.filter(sql: "entryId = ?", arguments: [entryID]) }
        return try request.fetchAll(db)
    }
}

extension SurveyStore {
    // MARK: - Entries

    public func watchlistEntries() async throws -> [WatchlistEntry] {
        try await read(WatchlistQueries.entries)
    }

    /// Adds a network after normalizing it (SSID trimmed, BSSID trimmed and
    /// lowercase) unless an entry already watches the same SSID and BSSID.
    public func addWatchlistEntry(
        label: String?, ssid: String?, bssid: String?, enabled: Bool = true, now: Date = Date()
    ) async throws -> WatchlistSaveResult {
        let ssid = WatchlistMatcher.normalizeSSID(ssid), bssid = WatchlistMatcher.normalizeBSSID(bssid)
        guard ssid != nil || bssid != nil else { return .invalid }
        return try await writer.write { db in
            guard try !Self.isDuplicate(ssid: ssid, bssid: bssid, except: nil, db: db) else { return .duplicate }
            var entry = WatchlistEntry(
                label: WatchlistMatcher.resolveLabel(label, ssid: ssid, bssid: bssid), ssid: ssid, bssid: bssid,
                enabled: enabled, createdAt: now
            )
            try entry.insert(db)
            return .saved(entry)
        }
    }

    /// Changes an entry's label and identifiers, keeping its UUID and sightings.
    public func updateWatchlistEntry(
        id: Int64, label: String?, ssid: String?, bssid: String?, now: Date = Date()
    ) async throws -> WatchlistSaveResult {
        let ssid = WatchlistMatcher.normalizeSSID(ssid), bssid = WatchlistMatcher.normalizeBSSID(bssid)
        guard ssid != nil || bssid != nil else { return .invalid }
        return try await writer.write { db in
            guard var entry = try WatchlistEntry.fetchOne(db, key: id) else { return .invalid }
            guard try !Self.isDuplicate(ssid: ssid, bssid: bssid, except: id, db: db) else { return .duplicate }
            entry.label = WatchlistMatcher.resolveLabel(label, ssid: ssid, bssid: bssid)
            entry.ssid = ssid
            entry.bssid = bssid
            entry.updatedAt = now
            try entry.update(db)
            return .saved(entry)
        }
    }

    public func setWatchlistEntry(id: Int64, enabled: Bool, now: Date = Date()) async throws {
        try await writer.write { db in
            try db.execute(
                sql: "UPDATE watchlistEntry SET enabled = ?, updatedAt = ? WHERE id = ? AND enabled != ?",
                arguments: [enabled, now, id, enabled]
            )
        }
    }

    /// Removes the entry and its sightings.
    public func deleteWatchlistEntry(id: Int64) async throws {
        _ = try await writer.write { try WatchlistEntry.deleteOne($0, key: id) }
    }

    /// Removes every entry and every sighting.
    public func clearWatchlist() async throws {
        _ = try await writer.write { try WatchlistEntry.deleteAll($0) }
    }

    static func isDuplicate(ssid: String?, bssid: String?, except id: Int64?, db: Database) throws -> Bool {
        let key = WatchlistMatcher.dedupKey(ssid: ssid, bssid: bssid)
        return try WatchlistEntry.fetchAll(db).contains {
            $0.id != id && WatchlistMatcher.dedupKey(ssid: $0.ssid, bssid: $0.bssid) == key
        }
    }

    // MARK: - Sightings

    /// Stores a sighting; returns it with its id. A sighting whose entry was
    /// removed in the meantime is not stored (nil).
    @discardableResult
    public func insertWatchlistHit(_ hit: WatchlistHit) async throws -> WatchlistHit? {
        try await writer.write { db in
            guard try WatchlistEntry.exists(db, key: hit.entryId) else { return nil }
            var stored = hit
            try stored.insert(db)
            return stored
        }
    }

    /// Removes sightings, of one entry or of all; the entries stay.
    public func clearWatchlistHistory(entryID: Int64? = nil) async throws {
        try await writer.write { db in
            if let entryID {
                try db.execute(sql: "DELETE FROM watchlistHit WHERE entryId = ?", arguments: [entryID])
            } else {
                try db.execute(sql: "DELETE FROM watchlistHit")
            }
        }
    }

    /// Removes sightings older than `date`; returns how many.
    @discardableResult
    public func pruneWatchlistHits(before date: Date) async throws -> Int {
        try await writer.write { db in
            try db.execute(sql: "DELETE FROM watchlistHit WHERE timestamp < ?", arguments: [date])
            return db.changesCount
        }
    }
}
