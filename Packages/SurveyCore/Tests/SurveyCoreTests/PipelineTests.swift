import BoardKit
import BoardProtocol
import Foundation
import GRDB
import Testing
@testable import SurveyCore

@Suite("Record pipeline")
struct PipelineTests {
    let t0 = Fixtures.base
    let boardA = BoardID(UUID(uuidString: "00000000-0000-4000-8000-00000000000A")!)
    let boardB = BoardID(UUID(uuidString: "00000000-0000-4000-8000-00000000000B")!)

    func makePipeline(
        plan: SurveyPlan = SurveyPlan(ble: true, rawFrames: true), privacy: PrivacyFilter = PrivacyFilter(),
        policy: LocationSourcePolicy = LocationSourcePolicy(), maxPending: Int = 200
    ) async throws -> (RecordPipeline, SurveyStore, RecordingSink) {
        let store = try SurveyStore.inMemory()
        try await store.insertSession(Fixtures.sessionRow())
        let sink = RecordingSink()
        let pipeline = RecordPipeline(
            session: Fixtures.context(plan: plan), store: store, sinks: [sink], privacy: privacy, policy: policy,
            battery: FixedBattery(level: 0.42), maxPending: maxPending
        )
        return (pipeline, store, sink)
    }

    @Test("Record numbers per type from 1, in order, across flushes and boards")
    func recordNumbers() async throws {
        let (pipeline, store, sink) = try await makePipeline(maxPending: 3)
        await pipeline.ingest(Fixtures.batch([
            Fixtures.ap("02:00:5E:00:00:01"), Fixtures.ble("0A:00:00:00:00:B1"), Fixtures.ap("02:00:5E:00:00:02"),
        ]), from: boardA)
        await pipeline.ingest(Fixtures.batch([
            Fixtures.ap("02:00:5E:00:00:01"), Fixtures.probe("0A:00:00:00:00:01"), Fixtures.client("0A:00:00:00:00:01"),
        ]), from: boardB)
        await pipeline.emitDeviceStatus(connectedBoards: 2, at: t0)
        await pipeline.ingest(Fixtures.batch([Fixtures.ap("02:00:5E:00:00:03")]), from: boardA)
        await pipeline.flush()
        #expect(sink.numbers(.wifiBeacon) == [1, 2, 3, 4])
        #expect(sink.numbers(.bluetooth) == [1])
        #expect(sink.numbers(.wifiProbeRequest) == [1])
        #expect(sink.numbers(.wifiStation) == [1])
        #expect(sink.numbers(.deviceStatus) == [1])
        let outputs = sink.outputs
        #expect(outputs.allSatisfy { $0.context.missionId == Fixtures.context().missionId })
        #expect(outputs.allSatisfy { $0.context.deviceSerialNumber == Fixtures.installID.uuidString })
        #expect(outputs.first?.context.boardID == boardA.description)
        #expect(outputs.first?.context.deviceTime == t0)
        let counters = await pipeline.counters
        #expect(counters.received[.wifiBeacon] == 4)
        #expect(counters.delivered[.deviceStatus] == 1)
        #expect(counters.perBoard[boardB.description] == 3)
        let stored = try await store.read { try StoreQueries.counts($0, sessionID: "S1") }
        #expect(stored.observations == 7)
        #expect(stored.accessPoints == 3)
    }

    @Test("Records outside the plan are dropped")
    func plan() async throws {
        let (pipeline, _, sink) = try await makePipeline(plan: SurveyPlan(wifiAP: true, wifiClient: false, ble: false))
        await pipeline.ingest(Fixtures.batch([
            Fixtures.ap("02:00:5E:00:00:01"), Fixtures.ble("0A:00:00:00:00:B1"), Fixtures.probe("0A:00:00:00:00:01"),
        ]), from: boardA)
        await pipeline.flush()
        #expect(sink.outputs.map(\.type) == [.wifiBeacon])
    }

    @Test("Location tagging: phone first, board GPS fallback")
    func locationTagging() async throws {
        let (pipeline, _, sink) = try await makePipeline()
        await pipeline.ingestPhoneLocation(Fixtures.phoneFix(latitude: 10, time: t0))
        await pipeline.ingest(Fixtures.batch([Fixtures.ap("02:00:5E:00:00:01", time: t0 + 2)]), from: boardA)
        // Phone goes quiet; the board's GPS takes over.
        await pipeline.ingest(Fixtures.batch([
            Fixtures.gps(latitude: 20, longitude: 20, time: t0 + 30),
            Fixtures.ap("02:00:5E:00:00:02", time: t0 + 31),
        ]), from: boardB)
        // Nothing fresh at all.
        await pipeline.ingest(Fixtures.batch([Fixtures.ap("02:00:5E:00:00:03", time: t0 + 100)]), from: boardA)
        await pipeline.flush()
        let locations = sink.outputs.map(\.context.location)
        #expect(locations[0]?.latitude == 10 && locations[0]?.source == .phone)
        #expect(locations[1]?.latitude == 20 && locations[1]?.source == .boardGPS)
        #expect(locations[2] == nil)
    }

    @Test("Late records get the fix from when they were observed")
    func lateRecords() async throws {
        let (pipeline, _, sink) = try await makePipeline()
        for second in 0...60 {
            await pipeline.ingestPhoneLocation(Fixtures.phoneFix(latitude: Double(second), time: t0 + TimeInterval(second)))
        }
        await pipeline.ingest(Fixtures.batch([Fixtures.ap("02:00:5E:00:00:01", time: t0 + 12)], receivedAt: t0 + 60), from: boardA)
        await pipeline.flush()
        #expect(sink.outputs.first?.context.location?.latitude == 12)
    }

    @Test("Privacy zones and the ignore list drop records, track points and raw frames")
    func privacy() async throws {
        let zoneCenter = GeoPoint(latitude: 10, longitude: -77.03)
        let filter = PrivacyFilter(
            zones: [PrivacyZone(center: zoneCenter, radiusMeters: 200)],
            ignoreList: [IgnoreEntry(kind: .ssid, value: "HomeNet")]
        )
        let (pipeline, store, sink) = try await makePipeline(privacy: filter)
        await pipeline.ingestPhoneLocation(Fixtures.phoneFix(latitude: 10, longitude: -77.03, time: t0))
        await pipeline.ingest(Fixtures.batch([Fixtures.ap("02:00:5E:00:00:01", time: t0)]), from: boardA)
        var frame = NSBRawFrame()
        frame.boardTimeUs = Fixtures.ms(t0) * 1000
        frame.timeSynced = true
        frame.data = Data([0x80, 0, 0, 0] + [UInt8](repeating: 0xFF, count: 20))
        await pipeline.ingestRaw(frame, from: boardA, receivedAt: t0)
        await pipeline.emitDeviceStatus(connectedBoards: 1, at: t0)
        // Leave the zone.
        await pipeline.ingestPhoneLocation(Fixtures.phoneFix(latitude: 11, longitude: -77.03, time: t0 + 1))
        await pipeline.ingest(Fixtures.batch([
            Fixtures.ap("02:00:5E:00:00:02", ssid: "HomeNet", time: t0 + 1),
            Fixtures.ap("02:00:5E:00:00:03", ssid: "Cafe-Guest", time: t0 + 1),
        ]), from: boardA)
        frame.boardTimeUs += 1_000_000
        await pipeline.ingestRaw(frame, from: boardA, receivedAt: t0 + 1)
        await pipeline.flush()

        let beacons = sink.outputs.filter { $0.type == .wifiBeacon }
        #expect(beacons.count == 1)
        #expect(beacons.first?.context.recordNumber == 1)
        let status = try #require(sink.outputs.first { $0.type == .deviceStatus })
        #expect(status.context.location == nil)
        if case .deviceStatus(let info) = status.payload { #expect(info.batteryLevelPercent == 42) }
        #expect(sink.state.withLock { $0.raw.count } == 1)
        #expect(await pipeline.counters.filtered == 3)
        let track = try await store.read { try StoreQueries.trackPoints($0, sessionID: "S1") }
        #expect(track.map(\.latitude) == [11])
        let session = try await store.read { try StoreQueries.sessions($0).first }
        #expect(session?.recordCount == 1)
        #expect(session?.filteredCount == 2)
    }

    @Test("Unsynced board time is mapped through the status offset")
    func unsyncedTime() async throws {
        let (pipeline, _, sink) = try await makePipeline()
        var status = NSBBoardStatus()
        status.boardTimeMs = 50_000
        await pipeline.ingestStatus(status, from: boardA, receivedAt: t0 + 50)
        var batch = Fixtures.batch([], receivedAt: t0 + 51)
        batch.batch.timeSynced = false
        var record = NSBRecord()
        var ap = NSBApObservation()
        ap.bssid = Fixtures.mac("02:00:5E:00:00:01")
        ap.boardTimeMs = 49_000
        record.kind = .ap(ap)
        batch.batch.records = [record]
        await pipeline.ingest(batch, from: boardA)
        await pipeline.flush()
        #expect(sink.outputs.first?.context.deviceTime == t0 + 49)
    }

    @Test("Lost notifications are counted")
    func lostNotifications() async throws {
        let (pipeline, _, _) = try await makePipeline()
        await pipeline.ingest(Fixtures.batch([Fixtures.ap("02:00:5E:00:00:01")], missed: 4), from: boardA)
        #expect(await pipeline.counters.lostNotifications == 4)
    }

    @Test("A privacy change applies from then on")
    func privacyChange() async throws {
        let (pipeline, _, sink) = try await makePipeline()
        await pipeline.ingest(Fixtures.batch([Fixtures.ap("02:00:5E:00:00:01", ssid: "HomeNet")]), from: boardA)
        await pipeline.setPrivacy(PrivacyFilter(ignoreList: [IgnoreEntry(kind: .ssid, value: "HomeNet")]))
        await pipeline.ingest(Fixtures.batch([Fixtures.ap("02:00:5E:00:00:01", ssid: "HomeNet", time: t0 + 1)]), from: boardA)
        await pipeline.flush()
        #expect(sink.outputs.count == 1)
        #expect(await pipeline.counters.filtered == 1)
    }

    @Test("Zones fail closed: coarse fixes near the edge and the last known fix")
    func zoneFailsClosed() async throws {
        let center = GeoPoint(latitude: 10, longitude: -77.03)
        let filter = PrivacyFilter(zones: [PrivacyZone(center: center, radiusMeters: 50)])
        let (pipeline, store, sink) = try await makePipeline(privacy: filter)
        // About 111 m north of the center: outside by its point, inside within its 80 m accuracy.
        await pipeline.ingestPhoneLocation(Fixtures.phoneFix(latitude: 10.001, longitude: -77.03, accuracy: 80, time: t0))
        await pipeline.ingest(Fixtures.batch([Fixtures.ap("02:00:5E:00:00:01", time: t0)]), from: boardA)
        // No fix within 10 s, but the last one (2 minutes old) was inside: still dropped.
        await pipeline.ingest(Fixtures.batch([Fixtures.ap("02:00:5E:00:00:02", time: t0 + 120)]), from: boardA)
        // Older than 5 minutes: the record cannot be placed and is kept.
        await pipeline.ingest(Fixtures.batch([Fixtures.ap("02:00:5E:00:00:03", time: t0 + 400)]), from: boardA)
        // A precise fix at the same spot is outside.
        await pipeline.ingestPhoneLocation(Fixtures.phoneFix(latitude: 10.001, longitude: -77.03, accuracy: 5, time: t0 + 500))
        await pipeline.ingest(Fixtures.batch([Fixtures.ap("02:00:5E:00:00:04", time: t0 + 500)]), from: boardA)
        await pipeline.flush()
        #expect(sink.outputs.count == 2)
        #expect(await pipeline.counters.filtered == 2)
        let track = try await store.read { try StoreQueries.trackPoints($0, sessionID: "S1") }
        #expect(track.count == 1)
    }

    @Test("Stale phone fixes are ignored")
    func staleFix() async throws {
        let store = try SurveyStore.inMemory()
        try await store.insertSession(Fixtures.sessionRow())
        let sink = RecordingSink()
        let now = t0 + 600
        let pipeline = RecordPipeline(
            session: Fixtures.context(), store: store, sinks: [sink], privacy: PrivacyFilter(),
            policy: LocationSourcePolicy(), now: { now }
        )
        await pipeline.ingestPhoneLocation(Fixtures.phoneFix(latitude: 1, time: now - 300))  // cached
        await pipeline.ingestPhoneLocation(Fixtures.phoneFix(latitude: 2, time: now - 1))
        await pipeline.ingest(Fixtures.batch([Fixtures.ap("02:00:5E:00:00:01", time: now - 299)]), from: boardA)
        await pipeline.flush()
        #expect(sink.outputs.first?.context.location == nil)
        let track = try await store.read { try StoreQueries.trackPoints($0, sessionID: "S1") }
        #expect(track.map(\.latitude) == [2])
    }

    @Test("Observations are thinned; every record still counts")
    func thinning() async throws {
        let (pipeline, store, sink) = try await makePipeline()
        var records: [NSBRecord.OneOf_Kind] = []
        for second in 0..<30 {
            records.append(Fixtures.ap("02:00:5E:00:00:01", rssi: -60 - Int32(second % 2), time: t0 + TimeInterval(second)))
        }
        records.append(Fixtures.ap("02:00:5E:00:00:01", rssi: -40, time: t0 + 30))  // new best
        await pipeline.ingest(Fixtures.batch(records), from: boardA)
        await pipeline.flush()
        #expect(sink.outputs.count == 31)
        let history = try await store.read {
            try StoreQueries.rssiHistory($0, sessionID: "S1", kind: .ap, identity: "02:00:5E:00:00:01")
        }
        #expect(history.map(\.time) == [t0, t0 + 10, t0 + 20, t0 + 30])
        let ap = try #require(try await store.read { try StoreQueries.accessPoints($0, sessionID: "S1").first })
        #expect(ap.observationCount == 31)
    }
}
