import BoardProtocol
import Foundation
import GRDB

/// A board record ready to store: privacy-filtered, with wall time and location.
public struct StoredRecord: Sendable {
    public var boardID: String
    public var time: Date
    public var location: LocationSample?
    public var kind: NSBRecord.OneOf_Kind
    /// False when the pipeline thinned this record: the entity row is updated
    /// but no `observation` row is written.
    public var keepObservation: Bool

    public init(
        boardID: String, time: Date, location: LocationSample?, kind: NSBRecord.OneOf_Kind, keepObservation: Bool = true
    ) {
        self.boardID = boardID
        self.time = time
        self.location = location
        self.kind = kind
        self.keepObservation = keepObservation
    }
}

/// The local record database (GRDB/SQLite). Writes come from the record
/// pipeline in batches; the UI reads through the query methods.
public final class SurveyStore: Sendable {
    public let writer: any DatabaseWriter

    /// Opens (or creates) the database file and runs pending migrations.
    public convenience init(url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var config = Configuration()
        config.foreignKeysEnabled = true
        config.prepareDatabase { db in
            // Must run before WAL mode writes the file header; a no-op on an
            // existing database. Lets deleted sessions give space back.
            if !db.configuration.readonly { try db.execute(sql: "PRAGMA auto_vacuum = INCREMENTAL") }
        }
        try self.init(writer: DatabasePool(path: url.path, configuration: config))
    }

    public init(writer: any DatabaseWriter) throws {
        self.writer = writer
        try StoreSchema.migrator.migrate(writer)
    }

    /// An empty in-memory database, for tests and previews.
    public static func inMemory() throws -> SurveyStore {
        var config = Configuration()
        config.foreignKeysEnabled = true
        return try SurveyStore(writer: DatabaseQueue(configuration: config))
    }

    // MARK: - Sessions

    public func insertSession(_ session: SessionRow) async throws {
        try await writer.write { try session.insert($0) }
    }

    public func finishSession(_ id: String, stoppedAt: Date) async throws {
        try await writer.write { db in
            try db.execute(sql: "UPDATE session SET stoppedAt = ? WHERE id = ?", arguments: [stoppedAt, id])
            // Gaps still open when the session ends close with it.
            try db.execute(
                sql: "UPDATE gapEvent SET endedAt = ? WHERE sessionId = ? AND endedAt IS NULL",
                arguments: [stoppedAt, id]
            )
        }
    }

    /// Deletes a session and everything in it. Observations go in chunks so a
    /// running survey's writes are not blocked for long; freed pages are then
    /// returned to the file system (incremental auto-vacuum).
    public func deleteSession(_ id: String) async throws {
        while try await writer.write({ db -> Int in
            try db.execute(
                sql: "DELETE FROM observation WHERE id IN (SELECT id FROM observation WHERE sessionId = ? LIMIT 20000)",
                arguments: [id]
            )
            return db.changesCount
        }) > 0 {}
        _ = try await writer.write { try SessionRow.deleteOne($0, key: id) }
        try await writer.writeWithoutTransaction { try $0.execute(sql: "PRAGMA incremental_vacuum") }
    }

    /// Closes gaps left open by a previous launch and records the time the app
    /// was not running as an `appRelaunch` gap. Returns that gap's start.
    @discardableResult
    public func noteRelaunch(sessionID: String, at date: Date) async throws -> Date {
        try await writer.write { db in
            let last = try Date.fetchOne(db, sql: """
                SELECT MAX(t) FROM (
                    SELECT MAX(lastSeen) AS t FROM accessPoint WHERE sessionId = :s
                    UNION ALL SELECT MAX(lastSeen) FROM client WHERE sessionId = :s
                    UNION ALL SELECT MAX(lastSeen) FROM probe WHERE sessionId = :s
                    UNION ALL SELECT MAX(lastSeen) FROM bleDevice WHERE sessionId = :s
                    UNION ALL SELECT MAX(time) FROM trackPoint WHERE sessionId = :s
                    UNION ALL SELECT startedAt FROM session WHERE id = :s)
                """, arguments: ["s": sessionID]) ?? date
            let start = min(last, date)
            try db.execute(
                sql: "UPDATE gapEvent SET endedAt = MAX(startedAt, ?) WHERE sessionId = ? AND endedAt IS NULL",
                arguments: [start, sessionID]
            )
            var gap = GapEventRow(
                id: nil, sessionId: sessionID, boardId: "", startedAt: start, endedAt: date, reason: "appRelaunch",
                missedNotifications: 0
            )
            try gap.insert(db)
            return start
        }
    }

    @discardableResult
    public func openGap(sessionID: String, boardID: String, at date: Date, reason: String) async throws -> Int64 {
        try await writer.write { db in
            var gap = GapEventRow(
                id: nil, sessionId: sessionID, boardId: boardID, startedAt: date, endedAt: nil,
                reason: reason, missedNotifications: 0
            )
            try gap.insert(db)
            return gap.id ?? 0
        }
    }

    /// Closes a gap. A board that was given up (stale bond, incompatible,
    /// user disconnect) is marked as not resumed.
    public func closeGap(_ id: Int64, at date: Date, resumed: Bool = true) async throws {
        try await writer.write { db in
            try db.execute(
                sql: "UPDATE gapEvent SET endedAt = ?, reason = CASE WHEN ? THEN reason ELSE reason || ',notResumed' END WHERE id = ?",
                arguments: [date, resumed, id]
            )
        }
    }

    /// Records lost without a disconnect: notifications lost on the link
    /// (`notificationsLost`) or records the board dropped (`boardDropped`).
    public func recordLoss(sessionID: String, boardID: String, count: Int, reason: String, at date: Date) async throws {
        try await writer.write { db in
            var gap = GapEventRow(
                id: nil, sessionId: sessionID, boardId: boardID, startedAt: date, endedAt: date,
                reason: reason, missedNotifications: count
            )
            try gap.insert(db)
        }
    }

    // MARK: - Records

    /// Stores records and track points in one transaction.
    public func write(
        sessionID: String, records: [StoredRecord], trackPoints: [LocationSample], filteredCount: Int = 0,
        recordNumbers: RecordNumbers? = nil
    ) async throws {
        guard !records.isEmpty || !trackPoints.isEmpty || filteredCount > 0 || recordNumbers != nil else { return }
        try await writer.write { db in
            for record in records {
                try Self.insert(record, sessionID: sessionID, db: db)
            }
            for sample in trackPoints {
                var point = TrackPointRow(
                    id: nil, sessionId: sessionID, time: sample.timestamp, latitude: sample.latitude,
                    longitude: sample.longitude, altitude: sample.altitude, accuracy: sample.horizontalAccuracy,
                    speed: sample.speed, source: sample.source.rawValue
                )
                try point.insert(db)
            }
            try db.execute(
                sql: "UPDATE session SET recordCount = recordCount + ?, filteredCount = filteredCount + ? WHERE id = ?",
                arguments: [records.count, filteredCount, sessionID]
            )
            if let recordNumbers {
                try db.execute(
                    sql: "UPDATE session SET recordNumbers = ? WHERE id = ?", arguments: [recordNumbers.json, sessionID]
                )
            }
        }
    }

    private static func insert(_ record: StoredRecord, sessionID: String, db: Database) throws {
        let location = record.location
        let common = { (rssiLast: Int32, rssiMax: Int32, frames: UInt32) -> [(any DatabaseValueConvertible)?] in
            [
                record.time, record.time, 1, Int(frames), Int(rssiLast), Int(rssiMax), record.boardID,
                location == nil ? nil : Int(rssiMax), location?.latitude, location?.longitude,
            ]
        }
        switch record.kind {
        case .ap(let ap):
            let bssid = MACAddress.string(ap.bssid)
            let ssid = ap.ssidHidden ? nil : String(decoding: ap.ssid, as: UTF8.self)
            let values: [(any DatabaseValueConvertible)?] = [
                sessionID, bssid, ssid, ap.ssidHidden, ap.band.rawValue, Int(ap.channel), Int(ap.frequencyMhz),
                ap.security.rawValue, Int(ap.groupCipher), joined(ap.pairwiseCiphers), joined(ap.akmSuites),
                ap.channelWidth.rawValue, Int(ap.phyFlags), ap.wps, ap.passpoint,
                ap.hasBeaconIntervalTu ? Int(ap.beaconIntervalTu) : nil,
                ap.hasStationCount ? Int(ap.stationCount) : nil,
                ap.hasChannelUtilization ? Int(ap.channelUtilization) : nil,
                MACAddress.isLocallyAdministered(ap.bssid),
            ]
            let frames = ap.beaconCount + ap.probeResponseCount
            try db.cachedStatement(sql: UpsertSQL.accessPoint)
                .execute(arguments: StatementArguments(values + common(ap.rssiLast, ap.rssiMax, max(frames, 1))))
            try insertObservation(
                record, kind: .ap, identity: bssid, rssi: ap.rssiLast, rssiMax: ap.rssiMax, channel: ap.channel,
                frequency: ap.frequencyMhz, band: ap.band, ssid: ssid, bssid: nil, sessionID: sessionID, db: db
            )

        case .client(let client):
            let mac = MACAddress.string(client.clientMac)
            let associated = client.associatedBssid.isEmpty ? nil : MACAddress.string(client.associatedBssid)
            let values: [(any DatabaseValueConvertible)?] = [
                sessionID, mac, client.locallyAdministered || MACAddress.isLocallyAdministered(client.clientMac),
                associated, Int(client.sourceFlags), client.band.rawValue, Int(client.channel),
            ]
            try db.cachedStatement(sql: UpsertSQL.client)
                .execute(arguments: StatementArguments(values + common(client.rssiLast, client.rssiMax, max(client.frameCount, 1))))
            try insertObservation(
                record, kind: .client, identity: mac, rssi: client.rssiLast, rssiMax: client.rssiMax,
                channel: client.channel, frequency: client.frequencyMhz, band: client.band, ssid: nil,
                bssid: associated, sessionID: sessionID, db: db
            )

        case .probe(let probe):
            let mac = MACAddress.string(probe.clientMac)
            let ssid = String(decoding: probe.ssid, as: UTF8.self)
            let target = probe.bssid.isEmpty || probe.bssid.allSatisfy({ $0 == 0xFF }) ? nil : MACAddress.string(probe.bssid)
            let values: [(any DatabaseValueConvertible)?] = [
                sessionID, mac, ssid, probe.locallyAdministered || MACAddress.isLocallyAdministered(probe.clientMac),
                probe.band.rawValue, Int(probe.channel),
            ]
            try db.cachedStatement(sql: UpsertSQL.probe)
                .execute(arguments: StatementArguments(values + common(probe.rssiLast, probe.rssiMax, max(probe.count, 1))))
            try insertObservation(
                record, kind: .probe, identity: mac, rssi: probe.rssiLast, rssiMax: probe.rssiMax,
                channel: probe.channel, frequency: probe.frequencyMhz, band: probe.band, ssid: ssid,
                bssid: target, sessionID: sessionID, db: db
            )

        case .ble(let ble):
            let address = MACAddress.string(ble.address)
            let name = ble.localName.isEmpty ? nil : ble.localNameText
            let values: [(any DatabaseValueConvertible)?] = [
                sessionID, address, ble.addressType.rawValue, ble.addressType != .public, name,
                ble.hasCompanyID ? Int(ble.companyID) : nil, ble.hasTxPower ? Int(ble.txPower) : nil,
                ble.advType.rawValue, ble.advData,
            ]
            try db.cachedStatement(sql: UpsertSQL.bleDevice)
                .execute(arguments: StatementArguments(values + common(ble.rssiLast, ble.rssiMax, max(ble.count, 1))))
            try insertObservation(
                record, kind: .ble, identity: address, rssi: ble.rssiLast, rssiMax: ble.rssiMax, channel: ble.channel,
                frequency: 0, band: .unspecified, ssid: nil, bssid: nil, sessionID: sessionID, db: db
            )

        case .gps:
            break
        }
    }

    private static func insertObservation(
        _ record: StoredRecord, kind: ObservationKind, identity: String, rssi: Int32, rssiMax: Int32,
        channel: UInt32, frequency: UInt32, band: NSBBand, ssid: String?, bssid: String?, sessionID: String,
        db: Database
    ) throws {
        guard record.keepObservation else { return }
        try db.cachedStatement(sql: UpsertSQL.observation).execute(arguments: [
            sessionID, kind.rawValue, identity, record.boardID, record.time, Int(rssi), Int(rssiMax), Int(channel),
            Int(frequency), band.rawValue, ssid, bssid, record.location?.latitude, record.location?.longitude,
            record.location?.horizontalAccuracy,
        ])
    }

    private static func joined(_ values: [UInt32]) -> String {
        values.map(String.init).joined(separator: ",")
    }
}

extension SurveyStore {
    /// The record number sequences saved with the session's last flush, to
    /// continue them on resume (DeviceStatus included).
    public func recordNumbers(sessionID: String) async throws -> RecordNumbers {
        try await read { db in
            let json = try String.fetchOne(db, sql: "SELECT recordNumbers FROM session WHERE id = ?", arguments: [sessionID])
            return RecordNumbers(json: json) ?? RecordNumbers()
        }
    }
}
