import BoardKit
import BoardProtocol
import CoreBluetooth
import Destinations
import Foundation
import NSMessaging
import SurveyCore
import Testing
@testable import NetworkSurvey

@MainActor
@Suite("App wiring", .serialized)
struct AppModelTests {
    private func makeModel(store: SurveyStore) -> AppModel {
        var options = LaunchOptions()
        options.uiTesting = true
        return AppModel(options: options, sharedStore: store)
    }

    private func connectDemo(_ model: AppModel) async throws {
        let board = try #require(model.demoTransport.profiles.first?.id)
        #expect(await model.connect(board) == nil)
    }

    private func waitUntil(_ condition: () -> Bool) async {
        for _ in 0..<100 where !condition() {
            try? await Task.sleep(for: .milliseconds(50))
        }
    }

    @Test("A survey with the demo board never sends to NS Analytics")
    func demoSkipsNSAnalytics() async throws {
        let model = makeModel(store: try .inMemory())
        model.nsAnalyticsCredentials.save(NSAnalyticsRegistration(
            deviceToken: "test-token", deviceID: model.identity.deviceSerialNumber, workspaceID: "w1",
            workspaceName: "Test workspace", apiURL: try #require(URL(string: "https://example.com/api"))
        ))
        model.settings[Settings.destinationNSAnalytics] = true
        try await connectDemo(model)
        await model.startSurvey()
        await waitUntil { model.survey.isRunning }
        #expect(model.survey.isRunning)
        #expect(model.survey.missionId?.hasPrefix("NS DEMO ") == true)
        await model.survey.refresh()
        let kinds = Set(model.survey.destinations.map(\.name))
        #expect(kinds.contains(DestinationKind.nsCSV.rawValue))
        #expect(!kinds.contains(DestinationKind.nsAnalytics.rawValue))
        await model.stopSurvey()
    }

    @Test("Demo records are dropped before NS Analytics")
    func realBoardsOnly() async {
        actor Collector: Destination {
            nonisolated let kind = DestinationKind.nsAnalytics
            var boards: [String] = []
            func start(_ session: SessionInfo) async throws {}
            func accept(_ records: [SurveyRecord]) async { boards += records.map(\.boardID) }
            func stop() async {}
            func snapshot() async -> DestinationSnapshot { DestinationSnapshot(status: .running) }
        }
        let collector = Collector()
        let filter = RealBoardsOnly(collector, demoBoards: ["DEMO"])
        let context = RecordContext(deviceSerialNumber: "s", missionId: "m", recordNumber: 1, deviceTime: Date(), location: nil)
        let record = BluetoothRecord(ble: NSBBleObservation(), context: context)
        await filter.accept([
            SurveyRecord(boardID: "DEMO", kind: .ble(record, NSBBleObservation())),
            SurveyRecord(boardID: "REAL", kind: .ble(record, NSBBleObservation())),
        ])
        await filter.accept([SurveyRecord(boardID: "DEMO", kind: .ble(record, NSBBleObservation()))])
        #expect(await collector.boards == ["REAL"])
        #expect(filter.kind == .nsAnalytics)
    }

    @Test("Starting a new survey ends one a previous launch left open")
    func newSurveyClosesInterrupted() async throws {
        let store = try SurveyStore.inMemory()
        let earlier = makeModel(store: store)
        try await connectDemo(earlier)
        await earlier.startSurvey()
        await waitUntil { earlier.survey.isRunning }
        let oldID = try #require(earlier.survey.session?.id)

        // A second launch finds the first session without a stop time.
        let model = makeModel(store: store)
        await model.reconcileInterruptedSession(autoResume: false)
        #expect(model.interruptedSession?.id == oldID)
        try await connectDemo(model)
        await model.startSurvey()
        await waitUntil { model.survey.isRunning }
        #expect(model.interruptedSession == nil)
        #expect(model.survey.session?.id != oldID)
        // The old session now has a stop time, so nothing is left unfinished.
        #expect(try await model.controller.unfinishedSession() == nil)
        await model.stopSurvey()
        await earlier.survey.controller.stop()
    }

    @Test("After a Bluetooth relaunch the survey resumes with the same mission ID")
    func autoResume() async throws {
        let store = try SurveyStore.inMemory()
        let earlier = makeModel(store: store)
        try await connectDemo(earlier)
        await earlier.startSurvey()
        await waitUntil { earlier.survey.isRunning }
        let missionId = try #require(earlier.survey.missionId)
        // The first launch is gone; its controller stops without closing the row.
        let model = makeModel(store: store)
        await model.reconcileInterruptedSession(autoResume: true)
        await waitUntil { model.survey.isRunning }
        #expect(model.interruptedSession == nil)
        #expect(model.survey.missionId == missionId)
        await model.stopSurvey()
    }

    @Test("Bluetooth access from authorization and power")
    func bluetoothAccess() {
        #expect(AccessModel.bluetoothAccess(authorization: .notDetermined, power: nil) == .notDetermined)
        #expect(AccessModel.bluetoothAccess(authorization: .denied, power: .poweredOn) == .denied)
        #expect(AccessModel.bluetoothAccess(authorization: .restricted, power: nil) == .restricted)
        #expect(AccessModel.bluetoothAccess(authorization: .allowedAlways, power: .poweredOff) == .off)
        #expect(AccessModel.bluetoothAccess(authorization: .allowedAlways, power: .unsupported) == .unsupported)
        #expect(AccessModel.bluetoothAccess(authorization: .allowedAlways, power: .poweredOn) == .ready)
        #expect(AccessModel.bluetoothAccess(authorization: .allowedAlways, power: nil) == .ready)
        #expect(BluetoothAccess.off.blocksBoards && BluetoothAccess.denied.blocksBoards && !BluetoothAccess.ready.blocksBoards)
    }

    @Test("Board page firmware status against the latest release")
    func firmwareReleaseStatus() {
        #expect(FirmwareUpdateModel.releaseStatus(.newer, latest: "1.3.0") == "Update available (1.3.0)")
        #expect(FirmwareUpdateModel.releaseStatus(.same, latest: "1.3.0") == "Up to date")
        #expect(FirmwareUpdateModel.releaseStatus(.older, latest: "1.3.0") == "Newer than the latest release")
        #expect(FirmwareUpdateModel.releaseStatus(.unknown, latest: "1.3.0") == nil)
    }

    @Test("Live Activity updates: 10 s for counts, 2 s for problems, 60 s refresh")
    func liveActivityThrottle() {
        var throttle = LiveActivityThrottle()
        let start = Date(timeIntervalSince1970: 1_000_000)
        let base = SurveyActivityAttributes.ContentState(recordCount: 10, boardsConnected: 2, boardsInSurvey: 2)
        throttle.reset(sent: base, at: start)
        var more = base
        more.recordCount = 20
        #expect(send(&throttle, more, at: 5) == false)
        #expect(send(&throttle, more, at: 10) == true)
        var dropped = more
        dropped.boardsConnected = 1
        #expect(send(&throttle, dropped, at: 11) == false)
        #expect(send(&throttle, dropped, at: 12) == true)
        #expect(dropped.problem == "1 Scout disconnected")
        // Nothing changes for a minute: the content is sent again to move its stale date.
        #expect(send(&throttle, dropped, at: 50) == false)
        #expect(send(&throttle, dropped, at: 72) == true)
    }

    private func send(
        _ throttle: inout LiveActivityThrottle, _ state: SurveyActivityAttributes.ContentState, at seconds: TimeInterval
    ) -> Bool {
        throttle.shouldSend(state, now: Date(timeIntervalSince1970: 1_000_000 + seconds))
    }

    @Test("Live Activity problem headlines, worst first")
    func problemText() {
        var state = SurveyActivityAttributes.ContentState(boardsConnected: 2, boardsInSurvey: 2)
        #expect(state.problem == nil)
        state.boardProblem = true
        #expect(state.problem == "Scout needs attention")
        state.losingRecords = true
        #expect(state.problem == "Scout losing records")
        state.lowestBatteryPercent = 9
        #expect(state.problem == "Scout battery low")
        state.boardsConnected = 0
        #expect(state.problem == "2 Scouts disconnected")
        state.stoppedAt = Date()
        #expect(state.problem == nil)
    }

    @Test("Elapsed time matches the system timer text")
    func elapsedFormat() {
        #expect(ElapsedFormat.string(8) == "0:08")
        #expect(ElapsedFormat.string(42 * 60 + 19) == "42:19")
        #expect(ElapsedFormat.string(3600 + 2 * 60 + 3) == "1:02:03")
        #expect(ElapsedFormat.string(-5) == "0:00")
    }
}
