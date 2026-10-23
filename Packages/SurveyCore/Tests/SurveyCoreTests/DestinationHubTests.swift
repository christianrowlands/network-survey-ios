import BoardKit
import BoardProtocol
import Destinations
import Foundation
import NSMessaging
import Testing
@testable import SurveyCore

@Suite("Destination hub")
struct DestinationHubTests {
    let t0 = Fixtures.base
    let board = BoardID(UUID(uuidString: "00000000-0000-4000-8000-00000000000A")!)

    @Test("Outputs convert to NS Messaging records with context and location")
    func conversion() throws {
        let context = OutputContext(
            deviceSerialNumber: Fixtures.installID.uuidString, deviceName: "TestPhone",
            missionId: Fixtures.context().missionId, recordNumber: 7, deviceTime: t0,
            location: Fixtures.phoneFix(latitude: 38.5, time: t0), boardID: board.description
        )
        guard case .ap(let ap) = Fixtures.ap("02:00:5E:00:00:01") else { return }
        let record = SurveyOutput(type: .wifiBeacon, payload: .accessPoint(ap), context: context).surveyRecord()
        #expect(record.boardID == board.description)
        guard case .ap(let beacon, let observation) = record.kind else {
            Issue.record("expected a beacon")
            return
        }
        #expect(observation == ap)
        #expect(beacon.data.recordNumber == 7)
        #expect(beacon.data.missionId == Fixtures.context().missionId)
        let json = beacon.jsonString()
        #expect(json.contains(Fixtures.installID.uuidString))
        #expect(json.contains("38.5"))

        let status = SurveyOutput(
            type: .deviceStatus,
            payload: .deviceStatus(DeviceStatusInfo(
                batteryLevelPercent: 64, connectedBoards: 1,
                boardGPS: LocationSample(latitude: 1, longitude: 2, timestamp: t0, source: .boardGPS),
                deviceModel: "iPhone17,3", appVersion: "0.1.0"
            )),
            context: OutputContext(
                deviceSerialNumber: "x", deviceName: "TestPhone", missionId: "m", recordNumber: 1, deviceTime: t0,
                location: nil, boardID: nil
            )
        ).surveyRecord()
        guard case .deviceStatus(let deviceStatus) = status.kind else {
            Issue.record("expected a device status")
            return
        }
        #expect(deviceStatus.data.batteryLevelPercent == 64)
        #expect(deviceStatus.data.gnssLatitude == 1)
        #expect(status.boardID == "")
    }

    @Test("Pipeline to NS CSV files in the session folder")
    func csvFiles() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("SurveyCoreHub-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        var context = Fixtures.context()
        context.directory = SessionFiles.directory(root: root, startedAt: t0)
        let hub = DestinationHub([NSCSVDestination()])
        let store = try SurveyStore.inMemory()
        try await store.insertSession(Fixtures.sessionRow())
        let pipeline = RecordPipeline(
            session: context, store: store, sinks: [hub], privacy: PrivacyFilter(), policy: LocationSourcePolicy()
        )
        try await hub.start(context)
        await pipeline.ingestPhoneLocation(Fixtures.phoneFix(time: t0))
        await pipeline.ingest(Fixtures.batch([
            Fixtures.ap("02:00:5E:00:00:01"), Fixtures.ap("02:00:5E:00:00:02"),
            Fixtures.ble("0A:00:00:00:00:B1"), Fixtures.probe("0A:00:00:00:00:01", ssid: "Cafe-Guest"),
            Fixtures.client("0A:00:00:00:00:01", associated: "02:00:5E:00:00:01"),
        ]), from: board)
        await pipeline.flush()
        await hub.stop()

        let snapshot = try #require(await hub.snapshots()[DestinationKind.nsCSV.rawValue])
        #expect(snapshot.recordsAccepted >= 5)
        #expect(snapshot.files.count >= 4)
        #expect(snapshot.files.allSatisfy { $0.url.path.hasPrefix(context.directory.path) })
        let wifi = try #require(snapshot.files.first { $0.url.lastPathComponent.hasPrefix("craxiom-wifi-2") })
        let text = try String(contentsOf: wifi.url, encoding: .utf8)
        #expect(text.contains(context.missionId))
        #expect(text.contains("ExampleNet"))
        #expect(context.directory.lastPathComponent == MissionID.timestamp(t0))
    }

    @Test("Raw frame envelopes reach pcapng only")
    func rawFrames() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("SurveyCoreHub-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        var context = Fixtures.context()
        context.directory = SessionFiles.directory(root: root, startedAt: t0)
        let hub = DestinationHub([PcapDestination(), NSCSVDestination()])
        let store = try SurveyStore.inMemory()
        try await store.insertSession(Fixtures.sessionRow())
        let pipeline = RecordPipeline(
            session: context, store: store, sinks: [hub], privacy: PrivacyFilter(), policy: LocationSourcePolicy()
        )
        try await hub.start(context)
        var frame = NSBRawFrame()
        frame.boardTimeUs = Fixtures.ms(t0) * 1000
        frame.timeSynced = true
        frame.channel = 6
        frame.frequencyMhz = 2437
        frame.band = .ghz24
        frame.rssi = -55
        frame.phy = .legacy
        frame.rate500Kbps = 2
        frame.data = Data([0x80, 0, 0, 0] + [UInt8](repeating: 0xFF, count: 6) + [0x02, 0, 0x5E, 0, 0, 1]
            + [0x02, 0, 0x5E, 0, 0, 1] + [0, 0] + [UInt8](repeating: 0, count: 12) + [0, 4] + Array("Test".utf8))
        frame.origLen = UInt32(frame.data.count)
        for offset in 0..<3 {
            var copy = frame
            copy.boardTimeUs += UInt64(offset) * 1000
            await pipeline.ingestRaw(BoardRawFrameEnvelope(boardID: board, receivedAt: t0, boardTimeUs: copy.boardTimeUs, frame: copy))
        }
        await pipeline.flush()
        await hub.stop()
        let snapshots = await hub.snapshots()
        let pcap = try #require(snapshots[DestinationKind.pcap.rawValue])
        #expect(pcap.recordsAccepted == 3)
        let file = try #require(pcap.files.first)
        #expect(file.url.pathExtension == "pcapng")
        #expect(file.bytes > 100)
        #expect(snapshots[DestinationKind.nsCSV.rawValue]?.recordsAccepted == 0)
        #expect(await pipeline.counters.rawFrames == 3)
    }
}
