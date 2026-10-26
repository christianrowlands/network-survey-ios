import Foundation
import GRDB

/// One network name from probe requests, across the clients that looked for it.
public struct ProbeNetworkRow: Sendable, Equatable, FetchableRecord {
    /// Empty for wildcard probes.
    public var ssid: String
    public var clientCount: Int
    /// Probe requests, summed over the clients.
    public var frameCount: Int
    /// The strongest last signal among the clients.
    public var rssiLast: Int
    public var firstSeen: Date
    public var lastSeen: Date
    /// Access points heard advertising this name.
    public var accessPointCount: Int

    public var isWildcard: Bool { ssid.isEmpty }

    public init(row: Row) throws {
        ssid = row["ssid"]
        clientCount = row["clientCount"]
        frameCount = row["frameCount"]
        rssiLast = row["rssiLast"]
        firstSeen = row["firstSeen"]
        lastSeen = row["lastSeen"]
        accessPointCount = row["accessPointCount"] ?? 0
    }
}

/// One client that sent probe requests, with the network names it looked for.
public struct ProbeClientRow: Sendable, Equatable, FetchableRecord {
    public var mac: String
    public var randomized: Bool
    /// Network names it looked for, by name; wildcard probes are not included.
    public var ssids: [String]
    public var sentWildcard: Bool
    /// Probe requests, summed over the networks.
    public var frameCount: Int
    /// The signal of its most recent probe request.
    public var rssiLast: Int
    public var firstSeen: Date
    public var lastSeen: Date

    public init(row: Row) throws {
        mac = row["clientMac"]
        randomized = row["randomized"]
        let json: String = row["ssids"] ?? "[]"
        ssids = try JSONDecoder().decode([String].self, from: Data(json.utf8))
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        sentWildcard = row["sentWildcard"]
        frameCount = row["frameCount"]
        rssiLast = row["rssiLast"]
        firstSeen = row["firstSeen"]
        lastSeen = row["lastSeen"]
    }
}

public struct ProbeNetworkDetail: Sendable, Equatable {
    public var network: ProbeNetworkRow
    /// The clients that looked for it, strongest first, at most `limit`.
    public var clients: [ProbeRow]
    /// Access points heard advertising this name, strongest first.
    public var accessPoints: [AccessPointRow]
}

extension StoreQueries {
    /// Probe requests grouped by network name. Band and randomized filters
    /// apply to the probes, so the counts cover only the probes shown.
    public static func probeNetworks(
        _ db: Database, sessionID: String, query: ListQuery = ListQuery()
    ) throws -> [ProbeNetworkRow] {
        var args: [String: (any DatabaseValueConvertible)?] = ["s": sessionID]
        var filter = probeFilter(query, table: "p")
        if !query.search.isEmpty {
            filter += " AND p.ssid LIKE :q ESCAPE '\\'"
            args["q"] = likePattern(query.search)
        }
        let order = switch query.sort {
        case .rssi: "rssiLast DESC, p.ssid"
        case .lastSeen: "lastSeen DESC, p.ssid"
        case .count: "clientCount DESC, frameCount DESC, p.ssid"
        case .name: "p.ssid = '', p.ssid COLLATE NOCASE, p.ssid"
        }
        let sql = probeNetworkSQL(filter: filter) + " ORDER BY \(order)" + limit(query.limit)
        return try ProbeNetworkRow.fetchAll(db, sql: sql, arguments: StatementArguments(args))
    }

    /// Probe requests grouped by client. A search matches the client's MAC
    /// or any network it looked for, and keeps all of its networks.
    public static func probeClients(
        _ db: Database, sessionID: String, query: ListQuery = ListQuery()
    ) throws -> [ProbeClientRow] {
        var args: [String: (any DatabaseValueConvertible)?] = ["s": sessionID]
        var filter = probeFilter(query)
        if !query.search.isEmpty {
            filter += """
                 AND clientMac IN (SELECT clientMac FROM probe WHERE sessionId = :s
                    AND (clientMac LIKE :q ESCAPE '\\' OR ssid LIKE :q ESCAPE '\\'))
                """
            args["q"] = likePattern(query.search)
        }
        let order = switch query.sort {
        case .rssi: "rssiLast DESC, clientMac"
        case .lastSeen: "lastSeen DESC, clientMac"
        case .count: "networkCount DESC, frameCount DESC, clientMac"
        case .name: "clientMac"
        }
        let sql = """
            SELECT clientMac, MAX(randomized) AS randomized,
                   json_group_array(ssid) FILTER (WHERE ssid <> '') AS ssids,
                   COUNT(*) FILTER (WHERE ssid <> '') AS networkCount,
                   MAX(ssid = '') AS sentWildcard, SUM(frameCount) AS frameCount,
                   (SELECT latest.rssiLast FROM probe latest
                    WHERE latest.sessionId = :s AND latest.clientMac = p.clientMac\(probeFilter(query, table: "latest"))
                    ORDER BY latest.lastSeen DESC LIMIT 1) AS rssiLast,
                   MIN(firstSeen) AS firstSeen, MAX(lastSeen) AS lastSeen
            FROM probe p WHERE sessionId = :s\(filter)
            GROUP BY clientMac ORDER BY \(order)
            """ + limit(query.limit)
        return try ProbeClientRow.fetchAll(db, sql: sql, arguments: StatementArguments(args))
    }

    /// One probed network name (empty for wildcard probes).
    public static func probeNetworkDetail(
        _ db: Database, sessionID: String, ssid: String, limit: Int = 1000
    ) throws -> ProbeNetworkDetail? {
        let args: StatementArguments = ["s": sessionID, "ssid": ssid]
        guard let network = try ProbeNetworkRow.fetchOne(
            db, sql: probeNetworkSQL(filter: " AND p.ssid = :ssid"), arguments: args
        ) else { return nil }
        let clients = try ProbeRow.fetchAll(db, sql: """
            SELECT * FROM probe WHERE sessionId = ? AND ssid = ? ORDER BY rssiLast DESC, clientMac LIMIT ?
            """, arguments: [sessionID, ssid, max(limit, 0)])
        let accessPoints = ssid.isEmpty ? [] : try AccessPointRow.fetchAll(db, sql: """
            SELECT * FROM accessPoint WHERE sessionId = ? AND ssid = ? ORDER BY rssiLast DESC, bssid
            """, arguments: [sessionID, ssid])
        return ProbeNetworkDetail(network: network, clients: clients, accessPoints: accessPoints)
    }

    private static func probeNetworkSQL(filter: String) -> String {
        """
        SELECT p.ssid, COUNT(*) AS clientCount, SUM(frameCount) AS frameCount, MAX(rssiLast) AS rssiLast,
               MIN(firstSeen) AS firstSeen, MAX(lastSeen) AS lastSeen, aps.count AS accessPointCount
        FROM probe p
        LEFT JOIN (SELECT ssid, COUNT(*) AS count FROM accessPoint WHERE sessionId = :s AND ssid <> '' GROUP BY ssid) aps
            ON aps.ssid = p.ssid
        WHERE p.sessionId = :s\(filter)
        GROUP BY p.ssid
        """
    }

    private static func probeFilter(_ query: ListQuery, table: String? = nil) -> String {
        let prefix = table.map { "\($0)." } ?? ""
        var filter = inFilter("\(prefix)band", query.bands.map { $0.rawValue })
        if query.hideRandomized { filter += " AND \(prefix)randomized = 0" }
        return filter
    }
}
