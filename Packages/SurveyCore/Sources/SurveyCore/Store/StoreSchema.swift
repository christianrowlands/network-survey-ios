import GRDB

/// Database migrations. Never edit a shipped migration; add a new one.
///
/// Entity tables (accessPoint, client, probe, bleDevice) hold one row per
/// session and identity, merged across boards, so UI counts are unique by
/// identity. `observation` keeps every record with its board, time and
/// location for history and maps.
enum StoreSchema {
    static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1") { db in
            try db.create(table: "session") { t in
                t.primaryKey("id", .text)
                t.column("missionId", .text).notNull()
                t.column("startedAt", .datetime).notNull()
                t.column("stoppedAt", .datetime)
                t.column("deviceSerialNumber", .text).notNull()
                t.column("deviceName", .text).notNull()
                t.column("wifiAP", .boolean).notNull()
                t.column("wifiClient", .boolean).notNull()
                t.column("ble", .boolean).notNull()
                t.column("rawFrames", .boolean).notNull()
                t.column("recordCount", .integer).notNull().defaults(to: 0)
                t.column("filteredCount", .integer).notNull().defaults(to: 0)
                // Next record number per message type (JSON), saved with each flush.
                t.column("recordNumbers", .text)
            }

            try db.create(table: "accessPoint") { t in
                t.column("sessionId", .text).notNull().references("session", onDelete: .cascade)
                t.column("bssid", .text).notNull()
                t.column("ssid", .text)
                t.column("ssidHidden", .boolean).notNull()
                t.column("band", .integer).notNull()
                t.column("channel", .integer).notNull()
                t.column("frequencyMhz", .integer).notNull()
                t.column("security", .integer).notNull()
                t.column("groupCipher", .integer).notNull()
                t.column("pairwiseCiphers", .text).notNull()
                t.column("akmSuites", .text).notNull()
                t.column("channelWidth", .integer).notNull()
                t.column("phyFlags", .integer).notNull()
                t.column("wps", .boolean).notNull()
                t.column("passpoint", .boolean).notNull()
                t.column("beaconIntervalTu", .integer)
                t.column("stationCount", .integer)
                t.column("channelUtilization", .integer)
                t.column("randomized", .boolean).notNull()
                entityColumns(t)
                t.primaryKey(["sessionId", "bssid"])
            }

            try db.create(table: "client") { t in
                t.column("sessionId", .text).notNull().references("session", onDelete: .cascade)
                t.column("mac", .text).notNull()
                t.column("randomized", .boolean).notNull()
                t.column("associatedBssid", .text)
                t.column("sourceFlags", .integer).notNull()
                t.column("band", .integer).notNull()
                t.column("channel", .integer).notNull()
                entityColumns(t)
                t.primaryKey(["sessionId", "mac"])
            }
            try db.create(index: "client_on_associatedBssid", on: "client", columns: ["sessionId", "associatedBssid"])

            try db.create(table: "probe") { t in
                t.column("sessionId", .text).notNull().references("session", onDelete: .cascade)
                t.column("clientMac", .text).notNull()
                // Empty for a wildcard probe.
                t.column("ssid", .text).notNull()
                t.column("randomized", .boolean).notNull()
                t.column("band", .integer).notNull()
                t.column("channel", .integer).notNull()
                entityColumns(t)
                t.primaryKey(["sessionId", "clientMac", "ssid"])
            }

            try db.create(table: "bleDevice") { t in
                t.column("sessionId", .text).notNull().references("session", onDelete: .cascade)
                t.column("address", .text).notNull()
                t.column("addressType", .integer).notNull()
                t.column("randomized", .boolean).notNull()
                t.column("name", .text)
                t.column("companyId", .integer)
                t.column("txPower", .integer)
                t.column("advType", .integer).notNull()
                t.column("advData", .blob).notNull()
                entityColumns(t)
                t.primaryKey(["sessionId", "address"])
            }

            try db.create(table: "observation") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("sessionId", .text).notNull().references("session", onDelete: .cascade)
                t.column("kind", .text).notNull()
                t.column("identity", .text).notNull()
                t.column("boardId", .text).notNull()
                t.column("time", .datetime).notNull()
                t.column("rssi", .integer).notNull()
                t.column("rssiMax", .integer).notNull()
                t.column("channel", .integer).notNull()
                t.column("frequencyMhz", .integer).notNull()
                t.column("band", .integer).notNull()
                // The SSID of a beacon or probe.
                t.column("ssid", .text)
                // A client's associated BSSID or a probe's target BSSID.
                t.column("bssid", .text)
                t.column("latitude", .double)
                t.column("longitude", .double)
                t.column("accuracy", .double)
            }
            try db.create(
                index: "observation_on_identity", on: "observation",
                columns: ["sessionId", "kind", "identity", "time"]
            )

            try db.create(table: "gapEvent") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("sessionId", .text).notNull().references("session", onDelete: .cascade).indexed()
                t.column("boardId", .text).notNull()
                t.column("startedAt", .datetime).notNull()
                t.column("endedAt", .datetime)
                t.column("reason", .text).notNull()
                t.column("missedNotifications", .integer).notNull().defaults(to: 0)
            }

            try db.create(table: "trackPoint") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("sessionId", .text).notNull().references("session", onDelete: .cascade).indexed()
                t.column("time", .datetime).notNull()
                t.column("latitude", .double).notNull()
                t.column("longitude", .double).notNull()
                t.column("altitude", .double)
                t.column("accuracy", .double)
                t.column("speed", .double)
                t.column("source", .text).notNull()
            }
        }
        return migrator
    }

    /// Columns shared by every entity table.
    private static func entityColumns(_ t: TableDefinition) {
        t.column("firstSeen", .datetime).notNull()
        t.column("lastSeen", .datetime).notNull()
        t.column("observationCount", .integer).notNull()
        t.column("frameCount", .integer).notNull()
        t.column("rssiLast", .integer).notNull()
        t.column("rssiMax", .integer).notNull()
        t.column("lastBoardId", .text).notNull()
        // Position where the strongest signal was observed.
        t.column("bestRssi", .integer)
        t.column("bestLatitude", .double)
        t.column("bestLongitude", .double)
    }
}
