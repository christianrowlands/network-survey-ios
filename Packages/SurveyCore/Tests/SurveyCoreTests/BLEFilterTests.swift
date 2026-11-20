import BoardProtocol
import Foundation
import Testing
@testable import SurveyCore

@Suite("BLE list filters")
struct BLEFilterTests {
    let t0 = Fixtures.base

    /// A BLE observation whose advertisement carries Apple manufacturer data.
    private func ble(_ address: String, name: String = "", apple payload: [UInt8]?) -> StoredRecord {
        var kind = Fixtures.ble(address, name: name)
        if case .ble(var observation) = kind {
            var adv: [UInt8] = [0x02, 0x01, 0x06]
            if let payload { adv += [UInt8(3 + payload.count), 0xFF, 0x4C, 0x00] + payload }
            observation.advData = Data(adv)
            kind = .ble(observation)
        }
        return StoredRecord(boardID: "B1", time: t0, location: nil, kind: kind)
    }

    private var records: [StoredRecord] {
        [
            ble("C0:00:5E:00:53:01", apple: [0x12, 0x19, 0x10, 0xAA]),  // AirTag
            ble("C0:00:5E:00:53:02", name: "Tag", apple: [0x12, 0x02, 0x24, 0x01]),  // Find My accessory
            ble("C0:00:5E:00:53:03", name: "Phone", apple: [0x12, 0x02, 0x00, 0x01]),  // iPhone: Find My, not a tracker
            ble("C0:00:5E:00:53:04", apple: [0x12, 0x02, 0x30, 0x01]),  // AirPods
            ble("C0:00:5E:00:53:05", name: "Buds", apple: [0x07, 0x19, 0x10, 0xAA]),  // Proximity Pairing
            ble("C0:00:5E:00:53:06", name: "  ", apple: nil),  // a blank name
        ]
    }

    private func addresses(_ store: SurveyStore, _ query: ListQuery) async throws -> [String] {
        try await store.read { try StoreQueries.bleDevices($0, sessionID: "S1", query: query) }.map(\.address).sorted()
    }

    @Test("Named only hides devices without a name")
    func namedOnly() async throws {
        let store = try SurveyStore.inMemory()
        try await store.insertSession(Fixtures.sessionRow())
        try await store.write(sessionID: "S1", records: records, trackPoints: [])
        #expect(try await addresses(store, ListQuery()).count == 6)
        #expect(try await addresses(store, ListQuery(namedOnly: true))
            == ["C0:00:5E:00:53:02", "C0:00:5E:00:53:03", "C0:00:5E:00:53:05"])
    }

    @Test("Find My trackers shows AirTags and Find My accessories only")
    func trackers() async throws {
        let store = try SurveyStore.inMemory()
        try await store.insertSession(Fixtures.sessionRow())
        try await store.write(sessionID: "S1", records: records, trackPoints: [])
        #expect(try await addresses(store, ListQuery(findMyTrackersOnly: true)) == ["C0:00:5E:00:53:01", "C0:00:5E:00:53:02"])
        #expect(try await addresses(store, ListQuery(namedOnly: true, findMyTrackersOnly: true)) == ["C0:00:5E:00:53:02"])
        // The filter applies before the row limit, so a long list cannot hide a tracker.
        #expect(try await addresses(store, ListQuery(sort: .name, findMyTrackersOnly: true, limit: 1)).count == 1)
    }

    @Test("A database file's read connections have the Find My function")
    func fileDatabase() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("SurveyCoreTests-\(UUID().uuidString)/survey.sqlite")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = try SurveyStore(url: url)
        try await store.insertSession(Fixtures.sessionRow())
        try await store.write(sessionID: "S1", records: records, trackPoints: [])
        let reopened = try SurveyStore(url: url)
        #expect(try await addresses(reopened, ListQuery(findMyTrackersOnly: true)).count == 2)
    }
}
