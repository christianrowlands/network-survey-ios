import Foundation
import GRDB

/// The access points that share a network name (SSID), summed up for the
/// grouped access point list. A hidden or unnamed network cannot be matched
/// to others, so each such BSSID is a group of its own (as on Android).
public struct AccessPointGroup: Sendable, Equatable, Identifiable {
    /// "ssid:<name>", or "bssid:<address>" for a hidden or unnamed network.
    public var key: String
    /// Nil for a hidden or unnamed network.
    public var ssid: String?
    /// Some access point in the group hides its name.
    public var hidden: Bool
    /// The lowest BSSID: the access point itself when `ssid` is nil.
    public var bssid: String
    public var accessPointCount: Int
    /// The strongest last RSSI in the group.
    public var rssiLast: Int
    public var lastSeen: Date
    public var frameCount: Int
    /// `NSBBand` raw values, ascending.
    public var bands: [Int]
    /// `NSBSecurityType` raw values, ascending.
    public var securities: [Int]
    /// The access points, only for groups asked for as expanded.
    public var members: [AccessPointRow]

    public var id: String { key }

    public init(
        key: String, ssid: String?, hidden: Bool, bssid: String, accessPointCount: Int, rssiLast: Int, lastSeen: Date,
        frameCount: Int, bands: [Int], securities: [Int], members: [AccessPointRow] = []
    ) {
        self.key = key
        self.ssid = ssid
        self.hidden = hidden
        self.bssid = bssid
        self.accessPointCount = accessPointCount
        self.rssiLast = rssiLast
        self.lastSeen = lastSeen
        self.frameCount = frameCount
        self.bands = bands
        self.securities = securities
        self.members = members
    }

    /// The group an access point belongs to.
    public static func key(ssid: String?, bssid: String) -> String {
        if let ssid, !ssid.isEmpty { return "ssid:\(ssid)" }
        return "bssid:\(bssid)"
    }

    /// The same as `key(ssid:bssid:)`, in SQL over the accessPoint table.
    static let keySQL = "CASE WHEN COALESCE(ssid, '') = '' THEN 'bssid:' || bssid ELSE 'ssid:' || ssid END"
}

extension StoreQueries {
    /// The access points `query` keeps, grouped by SSID. Groups are ordered by
    /// their strongest signal, latest sighting, total frames or name; `limit`
    /// counts groups. The access points of the groups in `expanded` come with
    /// them, by signal (for the name sort) or by the chosen sort.
    public static func accessPointGroups(
        _ db: Database, sessionID: String, query: ListQuery = ListQuery(), expanded: Set<String> = []
    ) throws -> [AccessPointGroup] {
        let (filter, args) = accessPointFilter(sessionID: sessionID, query: query)
        let sql = """
            SELECT \(AccessPointGroup.keySQL) AS groupKey, NULLIF(MAX(ssid), '') AS groupSSID,
                   MAX(ssidHidden) AS groupHidden, MIN(bssid) AS groupBSSID, COUNT(*) AS groupCount,
                   MAX(rssiLast) AS groupRSSI, MAX(lastSeen) AS groupLastSeen, SUM(frameCount) AS groupFrames,
                   GROUP_CONCAT(DISTINCT band) AS groupBands, GROUP_CONCAT(DISTINCT security) AS groupSecurities
            FROM accessPoint\(filter)
            GROUP BY groupKey
            """ + groupOrder(query.sort) + limit(query.limit)
        var groups = try Row.fetchAll(db, sql: sql, arguments: StatementArguments(args)).map { row in
            AccessPointGroup(
                key: row["groupKey"], ssid: row["groupSSID"], hidden: row["groupHidden"], bssid: row["groupBSSID"],
                accessPointCount: row["groupCount"], rssiLast: row["groupRSSI"], lastSeen: row["groupLastSeen"],
                frameCount: row["groupFrames"], bands: numbers(row["groupBands"]),
                securities: numbers(row["groupSecurities"])
            )
        }
        let open = groups.indices.filter { expanded.contains(groups[$0].key) }
        guard !open.isEmpty else { return groups }

        var memberArgs = args
        var placeholders: [String] = []
        for (number, index) in open.enumerated() {
            placeholders.append(":k\(number)")
            memberArgs["k\(number)"] = groups[index].key
        }
        let memberSQL = "SELECT *, \(AccessPointGroup.keySQL) AS groupKey FROM accessPoint\(filter)"
            + " AND (\(AccessPointGroup.keySQL)) IN (\(placeholders.joined(separator: ",")))" + memberOrder(query.sort)
        var members: [String: [AccessPointRow]] = [:]
        for row in try Row.fetchAll(db, sql: memberSQL, arguments: StatementArguments(memberArgs)) {
            members[row["groupKey"], default: []].append(try AccessPointRow(row: row))
        }
        for index in open {
            groups[index].members = members[groups[index].key] ?? []
        }
        return groups
    }

    private static func groupOrder(_ sort: ListSort) -> String {
        switch sort {
        case .rssi: " ORDER BY groupRSSI DESC, groupKey"
        case .lastSeen: " ORDER BY groupLastSeen DESC, groupKey"
        case .count: " ORDER BY groupFrames DESC, groupKey"
        case .name: " ORDER BY groupSSID IS NULL, groupSSID COLLATE NOCASE, groupKey"
        }
    }

    /// Inside a group every access point has the same name, so the name sort
    /// falls back to signal.
    private static func memberOrder(_ sort: ListSort) -> String {
        switch sort {
        case .rssi, .name: " ORDER BY rssiLast DESC, bssid"
        case .lastSeen: " ORDER BY lastSeen DESC, bssid"
        case .count: " ORDER BY frameCount DESC, bssid"
        }
    }

    /// "2,1" from GROUP_CONCAT as [1, 2].
    private static func numbers(_ list: String?) -> [Int] {
        (list ?? "").split(separator: ",").compactMap { Int($0) }.sorted()
    }
}
