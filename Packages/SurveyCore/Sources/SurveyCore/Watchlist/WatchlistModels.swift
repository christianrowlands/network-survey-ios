import Foundation
import GRDB

/// A Wi-Fi network the user watches for, matched by SSID, BSSID or both (see
/// `WatchlistMatcher`). The fields follow the Network Survey Android app's
/// watchlist entry, so the MQTT messages and share links carry the same data.
public struct WatchlistEntry: Codable, Sendable, Equatable, Hashable, FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "watchlistEntry"
    /// The only match type there is: trimmed, case-insensitive equality.
    public static let matchTypeExact = "EXACT"
    /// Minimum time between two alerts for the same entry, as on Android.
    public static let defaultCooldownSeconds = 900

    /// Local to this device; nil until inserted.
    public var id: Int64?
    /// Stable across edits; carried in the MQTT messages so a server can follow an entry.
    public var uuid: String
    /// The display name. Defaults to the SSID, then the BSSID.
    public var label: String
    /// Trimmed, case preserved; nil when the entry watches by BSSID only.
    public var ssid: String?
    /// Lowercase, colon separated; nil when the entry watches by SSID only.
    public var bssid: String?
    public var matchType: String
    /// False mutes the entry without removing it.
    public var enabled: Bool
    public var cooldownSeconds: Int
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: Int64? = nil, uuid: String = UUID().uuidString.lowercased(), label: String, ssid: String?, bssid: String?,
        matchType: String = WatchlistEntry.matchTypeExact, enabled: Bool = true,
        cooldownSeconds: Int = WatchlistEntry.defaultCooldownSeconds, createdAt: Date, updatedAt: Date? = nil
    ) {
        self.id = id
        self.uuid = uuid
        self.label = label
        self.ssid = ssid
        self.bssid = bssid
        self.matchType = matchType
        self.enabled = enabled
        self.cooldownSeconds = cooldownSeconds
        self.createdAt = createdAt
        self.updatedAt = updatedAt ?? createdAt
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }

    /// Which field a sighting of this entry is reported as matching: the SSID
    /// when the entry has one, otherwise the BSSID (as on Android).
    public var matchedField: WatchlistMatchedField {
        WatchlistMatcher.normalizeSSID(ssid) != nil ? .ssid : .bssid
    }
}

public enum WatchlistMatchedField: String, Codable, Sendable, DatabaseValueConvertible {
    case ssid, bssid
}

/// One sighting of a watched network: when and where it was seen. The entry's
/// label is copied so the history reads the same after a rename.
public struct WatchlistHit: Codable, Sendable, Equatable, Hashable, FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "watchlistHit"
    /// How long sightings are kept, as on Android.
    public static let retentionDays = 90

    public var id: Int64?
    public var entryId: Int64
    public var label: String
    public var matchedField: WatchlistMatchedField
    public var ssid: String
    /// Lowercase, colon separated.
    public var bssid: String
    /// dBm; nil when the access point reported no signal.
    public var rssi: Int?
    /// Nil when the survey had no location, or the sighting was inside a privacy zone.
    public var latitude: Double?
    public var longitude: Double?
    public var timestamp: Date
    /// The survey the sighting was made in.
    public var missionId: String

    public init(
        id: Int64? = nil, entryId: Int64, label: String, matchedField: WatchlistMatchedField, ssid: String,
        bssid: String, rssi: Int?, latitude: Double?, longitude: Double?, timestamp: Date, missionId: String
    ) {
        self.id = id
        self.entryId = entryId
        self.label = label
        self.matchedField = matchedField
        self.ssid = ssid
        self.bssid = bssid
        self.rssi = rssi
        self.latitude = latitude
        self.longitude = longitude
        self.timestamp = timestamp
        self.missionId = missionId
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }

    public var hasLocation: Bool { latitude != nil && longitude != nil }
}

/// The watchlist tables. Sightings belong to their entry and go with it.
enum WatchlistSchema {
    static func register(in migrator: inout DatabaseMigrator) {
        migrator.registerMigration("watchlist") { db in
            try db.create(table: WatchlistEntry.databaseTableName) { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("uuid", .text).notNull().unique()
                t.column("label", .text).notNull()
                t.column("ssid", .text)
                t.column("bssid", .text)
                t.column("matchType", .text).notNull()
                t.column("enabled", .boolean).notNull()
                t.column("cooldownSeconds", .integer).notNull()
                t.column("createdAt", .datetime).notNull()
                t.column("updatedAt", .datetime).notNull()
            }
            try db.create(table: WatchlistHit.databaseTableName) { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("entryId", .integer).notNull().references(WatchlistEntry.databaseTableName, onDelete: .cascade)
                t.column("label", .text).notNull()
                t.column("matchedField", .text).notNull()
                t.column("ssid", .text).notNull()
                t.column("bssid", .text).notNull()
                t.column("rssi", .integer)
                t.column("latitude", .double)
                t.column("longitude", .double)
                t.column("timestamp", .datetime).notNull()
                t.column("missionId", .text).notNull()
            }
            try db.create(index: "watchlistHit_on_entry", on: WatchlistHit.databaseTableName, columns: ["entryId", "timestamp"])
        }
    }
}
