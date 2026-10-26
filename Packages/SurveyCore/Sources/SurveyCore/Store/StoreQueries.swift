import BoardProtocol
import Foundation
import GRDB

public enum ListSort: String, Sendable, CaseIterable {
    /// Strongest last RSSI first.
    case rssi
    case lastSeen
    /// Most frames first.
    case count
    case name
}

/// Search, sort and filters shared by the AP, client and BLE lists.
public struct ListQuery: Sendable, Equatable {
    public var search: String
    public var sort: ListSort
    /// Empty means every band.
    public var bands: Set<NSBBand>
    /// Empty means every security type (APs only).
    public var securities: Set<NSBSecurityType>
    public var hideRandomized: Bool
    /// At most this many rows (a long survey can see tens of thousands).
    public var limit: Int?

    public init(
        search: String = "", sort: ListSort = .rssi, bands: Set<NSBBand> = [], securities: Set<NSBSecurityType> = [],
        hideRandomized: Bool = false, limit: Int? = 5000
    ) {
        self.search = search
        self.sort = sort
        self.bands = bands
        self.securities = securities
        self.hideRandomized = hideRandomized
        self.limit = limit
    }
}

/// A client with the SSID of its associated AP, when that AP was seen.
public struct ClientListItem: Sendable, Equatable, FetchableRecord {
    public var client: ClientRow
    public var associatedSSID: String?

    public init(row: Row) throws {
        client = try ClientRow(row: row)
        associatedSSID = row["associatedSSID"]
    }
}

/// Unique identities in a session, merged across boards.
public struct SurveyCounts: Sendable, Equatable {
    public var accessPoints = 0
    public var clients = 0
    /// Unique (client, SSID) probe pairs.
    public var probes = 0
    public var bleDevices = 0
    public var observations = 0

    public init() {}
}

public struct RSSIPoint: Sendable, Equatable {
    public var time: Date
    public var rssi: Int
    public var boardId: String
    public var channel: Int
}

public struct AccessPointDetail: Sendable, Equatable {
    public var accessPoint: AccessPointRow
    public var rssiHistory: [RSSIPoint]
    /// Channels it was heard on, ascending.
    public var channels: [Int]
    public var associatedClients: [ClientRow]
}

public struct AssociatedAP: Sendable, Equatable {
    public var bssid: String
    public var ssid: String?
}

public struct ClientDetail: Sendable, Equatable {
    public var client: ClientRow
    /// The preferred network list: SSIDs it probed for, wildcard probes last.
    public var probes: [ProbeRow]
    public var associatedAPs: [AssociatedAP]
    public var rssiHistory: [RSSIPoint]
}

public struct BLEDeviceDetail: Sendable, Equatable {
    public var device: BLEDeviceRow
    public var rssiHistory: [RSSIPoint]
}

/// A map marker: where an item was strongest.
public struct MapPoint: Sendable, Equatable, Identifiable {
    public var kind: ObservationKind
    public var identity: String
    public var label: String?
    public var latitude: Double
    public var longitude: Double
    public var rssi: Int
    public var band: Int
    public var randomized: Bool

    public var id: String { "\(kind.rawValue)-\(identity)" }

    public init(
        kind: ObservationKind, identity: String, label: String?, latitude: Double, longitude: Double, rssi: Int,
        band: Int, randomized: Bool
    ) {
        self.kind = kind
        self.identity = identity
        self.label = label
        self.latitude = latitude
        self.longitude = longitude
        self.rssi = rssi
        self.band = band
        self.randomized = randomized
    }
}

/// Read queries. Each takes a `Database` so the UI can run them once through
/// `SurveyStore.read` or keep them live with GRDB `ValueObservation`.
public enum StoreQueries {
    public static func sessions(_ db: Database) throws -> [SessionRow] {
        try SessionRow.order(Column("startedAt").desc).fetchAll(db)
    }

    public static func counts(_ db: Database, sessionID: String) throws -> SurveyCounts {
        var counts = SurveyCounts()
        let row = try Row.fetchOne(db, sql: """
            SELECT (SELECT COUNT(*) FROM accessPoint WHERE sessionId = :s) AS ap,
                   (SELECT COUNT(*) FROM client WHERE sessionId = :s) AS client,
                   (SELECT COUNT(*) FROM probe WHERE sessionId = :s) AS probe,
                   (SELECT COUNT(*) FROM bleDevice WHERE sessionId = :s) AS ble,
                   (SELECT recordCount FROM session WHERE id = :s) AS observations
            """, arguments: ["s": sessionID])
        guard let row else { return counts }
        counts.accessPoints = row["ap"]
        counts.clients = row["client"]
        counts.probes = row["probe"]
        counts.bleDevices = row["ble"]
        counts.observations = row["observations"] ?? 0
        return counts
    }

    public static func accessPoints(_ db: Database, sessionID: String, query: ListQuery = ListQuery()) throws -> [AccessPointRow] {
        var sql = "SELECT * FROM accessPoint WHERE sessionId = :s"
        var args: [String: (any DatabaseValueConvertible)?] = ["s": sessionID]
        if !query.search.isEmpty {
            sql += " AND (ssid LIKE :q ESCAPE '\\' OR bssid LIKE :q ESCAPE '\\')"
            args["q"] = likePattern(query.search)
        }
        sql += inFilter("band", query.bands.map { $0.rawValue })
        sql += inFilter("security", query.securities.map { $0.rawValue })
        if query.hideRandomized { sql += " AND randomized = 0" }
        sql += orderBy(query.sort, name: "COALESCE(ssid, '')", identity: "bssid") + limit(query.limit)
        return try AccessPointRow.fetchAll(db, sql: sql, arguments: StatementArguments(args))
    }

    public static func clients(_ db: Database, sessionID: String, query: ListQuery = ListQuery()) throws -> [ClientListItem] {
        var sql = """
            SELECT c.*, ap.ssid AS associatedSSID FROM client c
            LEFT JOIN accessPoint ap ON ap.sessionId = c.sessionId AND ap.bssid = c.associatedBssid
            WHERE c.sessionId = :s
            """
        var args: [String: (any DatabaseValueConvertible)?] = ["s": sessionID]
        if !query.search.isEmpty {
            sql += " AND (c.mac LIKE :q ESCAPE '\\' OR c.associatedBssid LIKE :q ESCAPE '\\' OR ap.ssid LIKE :q ESCAPE '\\')"
            args["q"] = likePattern(query.search)
        }
        sql += inFilter("c.band", query.bands.map { $0.rawValue })
        if query.hideRandomized { sql += " AND c.randomized = 0" }
        sql += orderBy(query.sort, name: "c.mac", identity: "c.mac", prefix: "c.") + limit(query.limit)
        return try ClientListItem.fetchAll(db, sql: sql, arguments: StatementArguments(args))
    }

    public static func bleDevices(_ db: Database, sessionID: String, query: ListQuery = ListQuery()) throws -> [BLEDeviceRow] {
        var sql = "SELECT * FROM bleDevice WHERE sessionId = :s"
        var args: [String: (any DatabaseValueConvertible)?] = ["s": sessionID]
        if !query.search.isEmpty {
            sql += " AND (name LIKE :q ESCAPE '\\' OR address LIKE :q ESCAPE '\\')"
            args["q"] = likePattern(query.search)
        }
        if query.hideRandomized { sql += " AND randomized = 0" }
        sql += orderBy(query.sort, name: "COALESCE(name, '')", identity: "address") + limit(query.limit)
        return try BLEDeviceRow.fetchAll(db, sql: sql, arguments: StatementArguments(args))
    }

    public static func accessPointDetail(_ db: Database, sessionID: String, bssid: String) throws -> AccessPointDetail? {
        guard let ap = try AccessPointRow.fetchOne(
            db, sql: "SELECT * FROM accessPoint WHERE sessionId = ? AND bssid = ?", arguments: [sessionID, bssid]
        ) else { return nil }
        let channels = try Int.fetchAll(db, sql: """
            SELECT DISTINCT channel FROM observation WHERE sessionId = ? AND kind = 'ap' AND identity = ? ORDER BY channel
            """, arguments: [sessionID, bssid])
        let clients = try ClientRow.fetchAll(db, sql: """
            SELECT * FROM client WHERE sessionId = ? AND associatedBssid = ? ORDER BY rssiLast DESC
            """, arguments: [sessionID, bssid])
        return AccessPointDetail(
            accessPoint: ap, rssiHistory: try rssiHistory(db, sessionID: sessionID, kind: .ap, identity: bssid),
            channels: channels, associatedClients: clients
        )
    }

    public static func clientDetail(_ db: Database, sessionID: String, mac: String) throws -> ClientDetail? {
        guard let client = try ClientRow.fetchOne(
            db, sql: "SELECT * FROM client WHERE sessionId = ? AND mac = ?", arguments: [sessionID, mac]
        ) else { return nil }
        let probes = try ProbeRow.fetchAll(db, sql: """
            SELECT * FROM probe WHERE sessionId = ? AND clientMac = ? ORDER BY ssid = '', ssid
            """, arguments: [sessionID, mac])
        let associated = try Row.fetchAll(db, sql: """
            SELECT o.bssid AS bssid, ap.ssid AS ssid FROM observation o
            LEFT JOIN accessPoint ap ON ap.sessionId = o.sessionId AND ap.bssid = o.bssid
            WHERE o.sessionId = ? AND o.kind = 'client' AND o.identity = ? AND o.bssid IS NOT NULL
            GROUP BY o.bssid ORDER BY MAX(o.time) DESC
            """, arguments: [sessionID, mac]).map { AssociatedAP(bssid: $0["bssid"], ssid: $0["ssid"]) }
        return ClientDetail(
            client: client, probes: probes, associatedAPs: associated,
            rssiHistory: try rssiHistory(db, sessionID: sessionID, kind: .client, identity: mac)
        )
    }

    public static func bleDeviceDetail(_ db: Database, sessionID: String, address: String) throws -> BLEDeviceDetail? {
        guard let device = try BLEDeviceRow.fetchOne(
            db, sql: "SELECT * FROM bleDevice WHERE sessionId = ? AND address = ?", arguments: [sessionID, address]
        ) else { return nil }
        return BLEDeviceDetail(
            device: device, rssiHistory: try rssiHistory(db, sessionID: sessionID, kind: .ble, identity: address)
        )
    }

    /// Signal over time, oldest first, at most `limit` most recent points.
    public static func rssiHistory(
        _ db: Database, sessionID: String, kind: ObservationKind, identity: String, limit: Int = 500
    ) throws -> [RSSIPoint] {
        try Row.fetchAll(db, sql: """
            SELECT * FROM (SELECT time, rssi, boardId, channel FROM observation
                WHERE sessionId = ? AND kind = ? AND identity = ? ORDER BY time DESC LIMIT ?)
            ORDER BY time
            """, arguments: [sessionID, kind.rawValue, identity, limit]
        ).map { RSSIPoint(time: $0["time"], rssi: $0["rssi"], boardId: $0["boardId"], channel: $0["channel"]) }
    }

    /// Strongest-observed positions of APs, clients and BLE devices.
    public static func mapPoints(
        _ db: Database, sessionID: String, kinds: Set<ObservationKind> = [.ap, .client, .ble], bands: Set<NSBBand> = []
    ) throws -> [MapPoint] {
        let bandFilter = inFilter("band", bands.map { $0.rawValue })
        var parts: [String] = []
        if kinds.contains(.ap) {
            parts.append("""
                SELECT 'ap' AS kind, bssid AS identity, ssid AS label, bestLatitude, bestLongitude, bestRssi, band, randomized
                FROM accessPoint WHERE sessionId = :s AND bestLatitude IS NOT NULL\(bandFilter)
                """)
        }
        if kinds.contains(.client) {
            parts.append("""
                SELECT 'client', mac, NULL, bestLatitude, bestLongitude, bestRssi, band, randomized
                FROM client WHERE sessionId = :s AND bestLatitude IS NOT NULL\(bandFilter)
                """)
        }
        if kinds.contains(.ble) && bands.isEmpty {
            parts.append("""
                SELECT 'ble', address, name, bestLatitude, bestLongitude, bestRssi, 0, randomized
                FROM bleDevice WHERE sessionId = :s AND bestLatitude IS NOT NULL
                """)
        }
        guard !parts.isEmpty else { return [] }
        return try Row.fetchAll(db, sql: parts.joined(separator: " UNION ALL "), arguments: ["s": sessionID]).compactMap { row in
            guard let kind = ObservationKind(rawValue: row["kind"]) else { return nil }
            return MapPoint(
                kind: kind, identity: row["identity"], label: row["label"], latitude: row["bestLatitude"],
                longitude: row["bestLongitude"], rssi: row["bestRssi"], band: row["band"], randomized: row["randomized"]
            )
        }
    }

    public static func trackPoints(_ db: Database, sessionID: String) throws -> [TrackPointRow] {
        try TrackPointRow.filter(Column("sessionId") == sessionID).order(Column("time")).fetchAll(db)
    }

    public static func gapEvents(_ db: Database, sessionID: String) throws -> [GapEventRow] {
        try GapEventRow.filter(Column("sessionId") == sessionID).order(Column("startedAt")).fetchAll(db)
    }

    // MARK: - Helpers

    static func likePattern(_ text: String) -> String {
        let escaped = text
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
        return "%\(escaped)%"
    }

    static func inFilter(_ column: String, _ values: [Int]) -> String {
        values.isEmpty ? "" : " AND \(column) IN (\(values.sorted().map(String.init).joined(separator: ",")))"
    }

    private static func orderBy(_ sort: ListSort, name: String, identity: String, prefix: String = "") -> String {
        switch sort {
        case .rssi: " ORDER BY \(prefix)rssiLast DESC, \(identity)"
        case .lastSeen: " ORDER BY \(prefix)lastSeen DESC, \(identity)"
        case .count: " ORDER BY \(prefix)frameCount DESC, \(identity)"
        case .name: " ORDER BY \(name) = '', \(name) COLLATE NOCASE, \(identity)"
        }
    }

    static func limit(_ limit: Int?) -> String {
        limit.map { " LIMIT \(max($0, 0))" } ?? ""
    }
}

extension SurveyStore {
    /// Runs read queries, for example `store.read { try StoreQueries.counts($0, sessionID: id) }`.
    public func read<T: Sendable>(_ body: @escaping @Sendable (Database) throws -> T) async throws -> T {
        try await writer.read(body)
    }

    /// A live query that re-runs whenever the tables it reads change.
    public func observe<T: Sendable>(
        _ body: @escaping @Sendable (Database) throws -> T
    ) -> AsyncValueObservation<T> {
        ValueObservation.tracking(body).values(in: writer, bufferingPolicy: .bufferingNewest(1))
    }
}
