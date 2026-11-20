import BoardProtocol
import Foundation
import Testing
@testable import SurveyCore

@Suite("Access points grouped by SSID")
struct AccessPointGroupTests {
    let t0 = Fixtures.base

    /// ExampleNet on two bands, Cafe-Guest on one, and two hidden networks.
    func makeStore() async throws -> SurveyStore {
        let store = try SurveyStore.inMemory()
        try await store.insertSession(Fixtures.sessionRow())
        func record(_ kind: NSBRecord.OneOf_Kind, at offset: TimeInterval = 0) -> StoredRecord {
            StoredRecord(boardID: "B1", time: t0 + offset, location: nil, kind: kind)
        }
        try await store.write(sessionID: "S1", records: [
            record(Fixtures.ap("00:00:5E:00:53:01", ssid: "ExampleNet", rssi: -70)),
            record(Fixtures.ap("02:00:5E:00:53:11", ssid: "ExampleNet", rssi: -55, channel: 36, band: .ghz5, security: .wpa3)),
            record(Fixtures.ap("00:00:5E:00:53:02", ssid: "Cafe-Guest", rssi: -60, security: .open), at: 9),
            record(Fixtures.ap("02:00:5E:00:00:03", ssid: "", rssi: -80)),
            record(Fixtures.ap("02:00:5E:00:00:04", ssid: "", rssi: -50)),
        ], trackPoints: [])
        return store
    }

    func groups(_ store: SurveyStore, _ query: ListQuery = ListQuery(), expanded: Set<String> = []) async throws -> [AccessPointGroup] {
        try await store.read { try StoreQueries.accessPointGroups($0, sessionID: "S1", query: query, expanded: expanded) }
    }

    @Test("Groups by SSID and keeps each hidden network on its own")
    func grouping() async throws {
        let store = try await makeStore()
        let all = try await groups(store)
        #expect(all.map(\.key) == ["bssid:02:00:5E:00:00:04", "ssid:ExampleNet", "ssid:Cafe-Guest", "bssid:02:00:5E:00:00:03"])

        let example = try #require(all.first { $0.ssid == "ExampleNet" })
        #expect(example.accessPointCount == 2)
        #expect(example.rssiLast == -55)
        #expect(example.bssid == "00:00:5E:00:53:01")
        #expect(example.bands == [NSBBand.ghz24.rawValue, NSBBand.ghz5.rawValue])
        #expect(example.securities == [NSBSecurityType.wpa2.rawValue, NSBSecurityType.wpa3.rawValue].sorted())
        #expect(example.frameCount == 6)
        #expect(!example.hidden && example.members.isEmpty)

        let hidden = try #require(all.first)
        #expect(hidden.ssid == nil && hidden.hidden && hidden.accessPointCount == 1)
        #expect(hidden.bssid == "02:00:5E:00:00:04")
        #expect(AccessPointGroup.key(ssid: nil, bssid: hidden.bssid) == hidden.key)
        #expect(AccessPointGroup.key(ssid: "ExampleNet", bssid: "x") == example.key)
    }

    @Test("Groups sort by signal, last seen, frames or name; members by the sort or signal")
    func sorting() async throws {
        let store = try await makeStore()
        #expect(try await groups(store, ListQuery(sort: .lastSeen)).first?.ssid == "Cafe-Guest")
        #expect(try await groups(store, ListQuery(sort: .count)).first?.ssid == "ExampleNet")
        let byName = try await groups(store, ListQuery(sort: .name))
        #expect(byName.map(\.ssid) == ["Cafe-Guest", "ExampleNet", nil, nil])

        let open = try await groups(store, ListQuery(sort: .name), expanded: ["ssid:ExampleNet", "ssid:Nowhere"])
        let example = try #require(open.first { $0.ssid == "ExampleNet" })
        #expect(example.members.map(\.bssid) == ["02:00:5E:00:53:11", "00:00:5E:00:53:01"])
        #expect(open.filter { $0.ssid != "ExampleNet" }.allSatisfy { $0.members.isEmpty })
    }

    @Test("Search and filters apply to the access points before grouping; the limit counts groups")
    func filtering() async throws {
        let store = try await makeStore()
        let fiveGHz = try await groups(store, ListQuery(bands: [.ghz5]), expanded: ["ssid:ExampleNet"])
        #expect(fiveGHz.count == 1)
        #expect(fiveGHz.first?.accessPointCount == 1 && fiveGHz.first?.members.count == 1)
        #expect(fiveGHz.first?.bands == [NSBBand.ghz5.rawValue])

        #expect(try await groups(store, ListQuery(search: "53:01")).map(\.accessPointCount) == [1])
        #expect(try await groups(store, ListQuery(securities: [.open])).map(\.ssid) == ["Cafe-Guest"])
        #expect(try await groups(store, ListQuery(hideRandomized: true)).map(\.ssid) == ["Cafe-Guest", "ExampleNet"])
        #expect(try await groups(store, ListQuery(limit: 2)).count == 2)
    }
}
