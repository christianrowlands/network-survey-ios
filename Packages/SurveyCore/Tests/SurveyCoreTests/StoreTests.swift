import BoardProtocol
import Foundation
import GRDB
import Testing
@testable import SurveyCore

@Suite("Record store")
struct StoreTests {
    let t0 = Fixtures.base

    func makeStore() async throws -> SurveyStore {
        let store = try SurveyStore.inMemory()
        try await store.insertSession(Fixtures.sessionRow())
        return store
    }

    func record(_ kind: NSBRecord.OneOf_Kind, board: String = "B1", at offset: TimeInterval = 0, lat: Double? = nil) -> StoredRecord {
        let location = lat.map { Fixtures.phoneFix(latitude: $0, longitude: -77, time: t0 + offset) }
        return StoredRecord(boardID: board, time: t0 + offset, location: location, kind: kind)
    }

    @Test("Counts are unique by identity across boards")
    func uniqueCounts() async throws {
        let store = try await makeStore()
        try await store.write(sessionID: "S1", records: [
            record(Fixtures.ap("02:00:5E:00:00:01", rssi: -70), board: "B1"),
            record(Fixtures.ap("02:00:5E:00:00:01", rssi: -60), board: "B2", at: 1),
            record(Fixtures.ap("02:00:5E:00:00:02"), board: "B2"),
            record(Fixtures.client("0A:00:00:00:00:01"), board: "B1"),
            record(Fixtures.client("0A:00:00:00:00:01"), board: "B2"),
            record(Fixtures.probe("0A:00:00:00:00:01", ssid: "HomeNet")),
            record(Fixtures.probe("0A:00:00:00:00:01", ssid: "HomeNet"), at: 2),
            record(Fixtures.probe("0A:00:00:00:00:01", ssid: "")),
            record(Fixtures.ble("0A:00:00:00:00:B1")),
        ], trackPoints: [], filteredCount: 3)
        let counts = try await store.read { try StoreQueries.counts($0, sessionID: "S1") }
        #expect(counts.accessPoints == 2)
        #expect(counts.clients == 1)
        #expect(counts.probes == 2)
        #expect(counts.bleDevices == 1)
        #expect(counts.observations == 9)
        let session = try await store.read { try StoreQueries.sessions($0).first }
        #expect(session?.filteredCount == 3)
        // Both boards' observations are kept.
        let boards = try await store.read {
            try String.fetchAll($0, sql: "SELECT DISTINCT boardId FROM observation WHERE identity = '02:00:5E:00:00:01'")
        }
        #expect(Set(boards) == ["B1", "B2"])
        // Numbers are saved with the flush that used them.
        var numbers = RecordNumbers()
        for _ in 0..<3 { _ = numbers.take(.wifiBeacon) }
        _ = numbers.take(.deviceStatus)
        try await store.write(sessionID: "S1", records: [], trackPoints: [], recordNumbers: numbers)
        let saved = try await store.recordNumbers(sessionID: "S1")
        #expect(saved.peek(.wifiBeacon) == 4 && saved.peek(.deviceStatus) == 2 && saved.peek(.bluetooth) == 1)
    }

    @Test("Merging keeps the strongest position, latest RSSI and sums frames")
    func merging() async throws {
        let store = try await makeStore()
        try await store.write(sessionID: "S1", records: [
            record(Fixtures.ap("02:00:5E:00:00:01", rssi: -70), at: 0, lat: 38.1),
            record(Fixtures.ap("02:00:5E:00:00:01", rssi: -50), at: 1, lat: 38.2),
            record(Fixtures.ap("02:00:5E:00:00:01", rssi: -80, channel: 11), at: 2, lat: 38.3),
            record(Fixtures.ap("02:00:5E:00:00:01", rssi: -40), at: -5),  // late arrival, no location
        ], trackPoints: [])
        let ap = try #require(try await store.read {
            try StoreQueries.accessPoints($0, sessionID: "S1").first
        })
        #expect(ap.bestRssi == -50)
        #expect(ap.bestLatitude == 38.2)
        #expect(ap.rssiLast == -80)
        #expect(ap.rssiMax == -40)
        #expect(ap.frameCount == 12)
        #expect(ap.observationCount == 4)
        #expect(ap.firstSeen == t0 - 5)
        #expect(ap.lastSeen == t0 + 2)
        #expect(ap.ssid == "ExampleNet")
        #expect(ap.security == NSBSecurityType.wpa2.rawValue)
    }

    @Test("Lists search, sort and filter")
    func lists() async throws {
        let store = try await makeStore()
        try await store.write(sessionID: "S1", records: [
            record(Fixtures.ap("00:00:5E:00:53:01", ssid: "Cafe-Guest", rssi: -50, security: .open)),
            record(Fixtures.ap("00:00:5E:00:53:02", ssid: "ExampleNet", rssi: -70, channel: 36, band: .ghz5)),
            record(Fixtures.ap("02:00:5E:00:00:03", ssid: "Library_Public", rssi: -60, security: .wpa3), at: 5),
            record(Fixtures.ap("02:00:5E:00:00:04", ssid: "", rssi: -90)),
        ], trackPoints: [])
        func ssids(_ query: ListQuery) async throws -> [String?] {
            try await store.read { try StoreQueries.accessPoints($0, sessionID: "S1", query: query) }.map(\.ssid)
        }
        #expect(try await ssids(ListQuery()) == ["Cafe-Guest", "Library_Public", "ExampleNet", nil])
        #expect(try await ssids(ListQuery(sort: .lastSeen)).first == "Library_Public")
        #expect(try await ssids(ListQuery(sort: .name)) == ["Cafe-Guest", "ExampleNet", "Library_Public", nil])
        #expect(try await ssids(ListQuery(search: "cafe")) == ["Cafe-Guest"])
        #expect(try await ssids(ListQuery(search: "00:53:02")) == ["ExampleNet"])
        // "_" is literal, not a wildcard.
        #expect(try await ssids(ListQuery(search: "y_P")) == ["Library_Public"])
        #expect(try await ssids(ListQuery(search: "e_G")) == [])
        #expect(try await ssids(ListQuery(bands: [.ghz5])) == ["ExampleNet"])
        #expect(try await ssids(ListQuery(securities: [.open, .wpa3])) == ["Cafe-Guest", "Library_Public"])
        #expect(try await ssids(ListQuery(hideRandomized: true)) == ["Cafe-Guest", "ExampleNet"])
        #expect(try await ssids(ListQuery(limit: 1)) == ["Cafe-Guest"])
    }

    @Test("Client list joins the associated SSID and hides randomized MACs")
    func clientList() async throws {
        let store = try await makeStore()
        try await store.write(sessionID: "S1", records: [
            record(Fixtures.ap("00:00:5E:00:53:01", ssid: "Cafe-Guest")),
            record(Fixtures.client("00:00:5E:00:53:A1", associated: "00:00:5E:00:53:01", rssi: -40)),
            record(Fixtures.client("0A:00:00:00:00:02", rssi: -60)),
        ], trackPoints: [])
        let all = try await store.read { try StoreQueries.clients($0, sessionID: "S1") }
        #expect(all.map(\.client.mac) == ["00:00:5E:00:53:A1", "0A:00:00:00:00:02"])
        #expect(all.first?.associatedSSID == "Cafe-Guest")
        #expect(all.last?.client.randomized == true)
        let visible = try await store.read {
            try StoreQueries.clients($0, sessionID: "S1", query: ListQuery(search: "cafe", hideRandomized: true))
        }
        #expect(visible.count == 1)
        let ble = try await store.read { try StoreQueries.bleDevices($0, sessionID: "S1") }
        #expect(ble.isEmpty)
    }

    @Test("Details: RSSI history, channels, associated clients, PNL")
    func details() async throws {
        let store = try await makeStore()
        try await store.write(sessionID: "S1", records: [
            record(Fixtures.ap("00:00:5E:00:53:01", rssi: -70, channel: 1), at: 0),
            record(Fixtures.ap("00:00:5E:00:53:01", rssi: -65, channel: 6), board: "B2", at: 1),
            record(Fixtures.client("0A:00:00:00:00:01", associated: "00:00:5E:00:53:01"), at: 2),
            record(Fixtures.probe("0A:00:00:00:00:01", ssid: "HomeNet"), at: 3),
            record(Fixtures.probe("0A:00:00:00:00:01", ssid: ""), at: 4),
            record(Fixtures.probe("0A:00:00:00:00:01", ssid: "Cafe-Guest"), at: 5),
            record(Fixtures.ble("0A:00:00:00:00:B1", name: "Sensor"), at: 6),
        ], trackPoints: [])
        let ap = try #require(try await store.read {
            try StoreQueries.accessPointDetail($0, sessionID: "S1", bssid: "00:00:5E:00:53:01")
        })
        #expect(ap.rssiHistory.map(\.rssi) == [-70, -65])
        #expect(ap.rssiHistory.map(\.boardId) == ["B1", "B2"])
        #expect(ap.channels == [1, 6])
        #expect(ap.associatedClients.map(\.mac) == ["0A:00:00:00:00:01"])

        let client = try #require(try await store.read {
            try StoreQueries.clientDetail($0, sessionID: "S1", mac: "0A:00:00:00:00:01")
        })
        #expect(client.probes.map(\.ssid) == ["Cafe-Guest", "HomeNet", ""])
        #expect(client.associatedAPs == [AssociatedAP(bssid: "00:00:5E:00:53:01", ssid: "ExampleNet")])

        let ble = try #require(try await store.read {
            try StoreQueries.bleDeviceDetail($0, sessionID: "S1", address: "0A:00:00:00:00:B1")
        })
        #expect(ble.device.name == "Sensor")
        #expect(ble.device.companyId == 0x004C)
        #expect(ble.rssiHistory.count == 1)
        #expect(try await store.read { try StoreQueries.accessPointDetail($0, sessionID: "S1", bssid: "x") } == nil)
    }

    @Test("Map points use the strongest-observed position")
    func mapPoints() async throws {
        let store = try await makeStore()
        try await store.write(sessionID: "S1", records: [
            record(Fixtures.ap("00:00:5E:00:53:01", rssi: -70), lat: 38.1),
            record(Fixtures.ap("00:00:5E:00:53:01", rssi: -45), lat: 38.2),
            record(Fixtures.ap("00:00:5E:00:53:02", channel: 36, band: .ghz5), lat: 38.3),
            record(Fixtures.ap("00:00:5E:00:53:03")),  // never located
            record(Fixtures.client("0A:00:00:00:00:01"), lat: 38.4),
            record(Fixtures.ble("0A:00:00:00:00:B1"), lat: 38.5),
        ], trackPoints: [Fixtures.phoneFix(time: t0), Fixtures.phoneFix(time: t0 + 1)])
        let all = try await store.read { try StoreQueries.mapPoints($0, sessionID: "S1") }
        #expect(all.count == 4)
        let ap = try #require(all.first { $0.identity == "00:00:5E:00:53:01" })
        #expect(ap.latitude == 38.2 && ap.rssi == -45 && ap.label == "ExampleNet")
        let fiveGHz = try await store.read {
            try StoreQueries.mapPoints($0, sessionID: "S1", kinds: [.ap], bands: [.ghz5])
        }
        #expect(fiveGHz.map(\.identity) == ["00:00:5E:00:53:02"])
        let track = try await store.read { try StoreQueries.trackPoints($0, sessionID: "S1") }
        #expect(track.count == 2)
    }

    @Test("Gap events, finishing and deleting a session")
    func sessionLifecycle() async throws {
        let store = try await makeStore()
        let gap = try await store.openGap(sessionID: "S1", boardID: "B1", at: t0, reason: "linkLost")
        try await store.closeGap(gap, at: t0 + 10)
        try await store.openGap(sessionID: "S1", boardID: "B2", at: t0 + 20, reason: "linkLost")
        try await store.recordLoss(sessionID: "S1", boardID: "B1", count: 3, reason: "notificationsLost", at: t0 + 30)
        try await store.write(sessionID: "S1", records: [record(Fixtures.ap("00:00:5E:00:53:01"))], trackPoints: [])
        try await store.finishSession("S1", stoppedAt: t0 + 60)
        let gaps = try await store.read { try StoreQueries.gapEvents($0, sessionID: "S1") }
        #expect(gaps.map(\.endedAt) == [t0 + 10, t0 + 60, t0 + 30])
        #expect(gaps.last?.missedNotifications == 3)
        #expect(try await store.read { try StoreQueries.sessions($0).first?.stoppedAt } == t0 + 60)

        try await store.deleteSession("S1")
        let remaining = try await store.read { db in
            try Int.fetchOne(db, sql: "SELECT (SELECT COUNT(*) FROM observation) + (SELECT COUNT(*) FROM accessPoint) + (SELECT COUNT(*) FROM gapEvent)")
        }
        #expect(remaining == 0)
    }

    @Test("Thinned records update entities without observation rows; WPS is sticky")
    func thinnedRecords() async throws {
        let store = try await makeStore()
        guard case .ap(var ap) = Fixtures.ap("02:00:5E:00:00:01") else { return }
        ap.wps = true
        var trimmed = ap
        trimmed.wps = false
        try await store.write(sessionID: "S1", records: [
            StoredRecord(boardID: "B1", time: t0, location: nil, kind: .ap(ap)),
            StoredRecord(boardID: "B1", time: t0 + 1, location: nil, kind: .ap(trimmed), keepObservation: false),
        ], trackPoints: [])
        let row = try #require(try await store.read { try StoreQueries.accessPoints($0, sessionID: "S1").first })
        #expect(row.observationCount == 2 && row.lastSeen == t0 + 1 && row.wps)
        let history = try await store.read {
            try StoreQueries.rssiHistory($0, sessionID: "S1", kind: .ap, identity: "02:00:5E:00:00:01")
        }
        #expect(history.count == 1)
    }

    @Test("Relaunch closes open gaps and records the downtime")
    func relaunchGap() async throws {
        let store = try await makeStore()
        try await store.write(sessionID: "S1", records: [record(Fixtures.ap("02:00:5E:00:00:01"), at: 30)], trackPoints: [])
        try await store.openGap(sessionID: "S1", boardID: "B1", at: t0 + 20, reason: "linkLost")
        let start = try await store.noteRelaunch(sessionID: "S1", at: t0 + 600)
        #expect(start == t0 + 30)
        let gaps = try await store.read { try StoreQueries.gapEvents($0, sessionID: "S1") }
        #expect(gaps.allSatisfy { $0.endedAt != nil })
        #expect(gaps.last?.reason == "appRelaunch" && gaps.last?.endedAt == t0 + 600)
    }

    @Test("Opens a database file and migrates it")
    func fileDatabase() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("SurveyCoreTests-\(UUID().uuidString)/survey.sqlite")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = try SurveyStore(url: url)
        try await store.insertSession(Fixtures.sessionRow())
        let reopened = try SurveyStore(url: url)
        #expect(try await reopened.read { try StoreQueries.sessions($0).count } == 1)
        // 2 = incremental, so deleted sessions can give space back.
        #expect(try await reopened.read { try Int.fetchOne($0, sql: "PRAGMA auto_vacuum") } == 2)
        try await reopened.deleteSession("S1")
        #expect(try await reopened.read { try StoreQueries.sessions($0).count } == 0)
    }
}
