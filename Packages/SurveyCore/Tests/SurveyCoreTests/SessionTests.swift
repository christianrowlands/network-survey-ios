import BoardKit
import BoardProtocol
import Foundation
import GRDB
import Testing
@testable import SurveyCore

@Suite("Survey session end to end", .serialized)
@MainActor
struct SessionTests {
    struct Rig {
        let transport: SimulatedBoardTransport
        let manager: BoardManager
        let location: SimulatedLocationProvider
        let store: SurveyStore
        let settings: SettingsStore
        let sink: RecordingSink
        let controller: SurveySessionController
        var ids: [BoardID] { transport.profiles.map(\.id) }

        /// Moves boards and phone forward together, one second at a time.
        func walk(seconds: Int) async {
            for _ in 0..<seconds {
                await transport.advance(byMs: 1000)
                location.advance(bySeconds: 1)
            }
        }
    }

    func makeRig(
        boards: Int = 2, connect: Bool = true, sinkDelay: Duration = .zero, stuck: Bool = false,
        freeBytes: Int64? = nil, demo: Bool = false
    ) async throws -> Rig {
        let start = Date()
        let transport = SimulatedBoardTransport(boardCount: boards, seed: 5, timeSource: .manual, startDate: start)
        let manager = BoardManager(
            transport: transport, appVersion: "0.1.0",
            reconnectPolicy: ReconnectPolicy(initialDelay: .milliseconds(20), maxDelay: .milliseconds(100))
        )
        let location = SimulatedLocationProvider(startDate: start, timeSource: .manual)
        let store = try SurveyStore.inMemory()
        let settings = SettingsStore.inMemory()
        settings[Settings.surveyBLE] = true
        let sink = RecordingSink(startDelay: sinkDelay, stuck: stuck)
        let env = SessionEnvironment(
            boards: BoardManagerSource(manager: manager), location: location, store: store, settings: settings,
            identity: DeviceIdentity(installID: Fixtures.installID, deviceName: "TestPhone"),
            app: Fixtures.app, filesRoot: FileManager.default.temporaryDirectory, battery: FixedBattery(level: 0.8),
            makeSinks: { _ in [sink] },
            flushInterval: .milliseconds(20), deviceStatusInterval: .milliseconds(100), stopGrace: .milliseconds(50),
            sinkTimeout: .milliseconds(500), freeSpace: { freeBytes ?? Int64.max }, isDemoSession: { demo }
        )
        let rig = Rig(
            transport: transport, manager: manager, location: location, store: store, settings: settings, sink: sink,
            controller: SurveySessionController(environment: env)
        )
        if connect {
            for id in rig.ids { try await manager.connect(id) }
            let ready = await waitUntil { manager.readyBoards.count == rig.ids.count }
            #expect(ready)
        }
        return rig
    }

    @Test("Start needs a connected board and leaves nothing behind when refused")
    func startNeedsBoard() async throws {
        let rig = try await makeRig(connect: false)
        await #expect(throws: SessionError.noBoardConnected) { try await rig.controller.start() }
        let snapshot = await rig.controller.snapshot
        #expect(snapshot.state == .idle)
        #expect(snapshot.lastError == .noBoardConnected)
        #expect(try await rig.store.read { try StoreQueries.sessions($0) }.isEmpty)
        #expect(rig.sink.state.withLock { $0.started.isEmpty })
        await rig.transport.shutdown()
    }

    @Test("Nothing to survey is refused")
    func nothingToSurvey() async throws {
        let rig = try await makeRig(boards: 1)
        rig.settings[Settings.surveyWifiAP] = false
        rig.settings[Settings.surveyWifiClient] = false
        rig.settings[Settings.surveyBLE] = false
        await #expect(throws: SessionError.nothingToSurvey) { try await rig.controller.start() }
        await rig.transport.shutdown()
    }

    @Test("Simulated boards to store and destination, with a board drop and resume", .timeLimit(.minutes(1)))
    func endToEnd() async throws {
        let rig = try await makeRig()
        // A rename in Settings applies to the next survey without a relaunch.
        rig.settings[Settings.deviceName] = "Van 2"
        let row = try await rig.controller.start()
        #expect(row.missionId.hasPrefix("NS \(Fixtures.installID.uuidString) "))
        #expect(row.deviceName == "Van 2")
        #expect(rig.sink.state.withLock { $0.started.map(\.deviceName) } == ["Van 2"])
        #expect(await rig.controller.snapshot.state == .running)
        await #expect(throws: SessionError.notIdle) { try await rig.controller.start() }
        #expect(rig.sink.state.withLock { $0.started.map(\.missionId) } == [row.missionId])

        await rig.walk(seconds: 10)
        #expect(await waitUntil { (await rig.controller.counters?.delivered[.wifiBeacon] ?? 0) > 50 })
        // An ignore entry added mid-survey applies to records from then on.
        rig.settings[Settings.ignoreList] = [IgnoreEntry(kind: .macPrefix, value: "0")]
        #expect(await waitUntil {
            await rig.walk(seconds: 1)
            return (await rig.controller.counters?.filtered ?? 0) > 0
        })
        rig.settings[Settings.ignoreList] = []

        // Board B drops, keeps surveying into its buffer, and BoardManager
        // reconnects it and puts it back into the survey.
        let dropped = rig.ids[1]
        await rig.transport.injectDisconnect(dropped)
        #expect(await waitUntil {
            (try? await rig.store.read { try StoreQueries.gapEvents($0, sessionID: row.id) }.count) == 1
        })
        await rig.walk(seconds: 5)
        #expect(await waitUntil { rig.manager.readyBoards.count == 2 })
        await rig.walk(seconds: 5)
        #expect(await waitUntil {
            (try? await rig.store.read { try StoreQueries.gapEvents($0, sessionID: row.id) }.first?.endedAt) != nil
        })
        // Let the last records and a device status through.
        try await Task.sleep(for: .milliseconds(250))
        await rig.controller.stop()
        #expect(await rig.controller.snapshot.state == .idle)

        let sink = rig.sink
        #expect(sink.state.withLock { $0.stopped } == 1)
        let outputs = sink.outputs
        for type in [MessageType.wifiBeacon, .wifiStation, .wifiProbeRequest, .bluetooth, .deviceStatus] {
            let numbers = sink.numbers(type)
            #expect(!numbers.isEmpty, "no \(type) records")
            #expect(numbers == Array(1...max(numbers.count, 1)), "\(type) numbers not contiguous")
        }
        #expect(outputs.allSatisfy { $0.context.missionId == row.missionId })
        #expect(Set(outputs.compactMap(\.context.boardID)) == Set(rig.ids.map(\.description)))
        let located = outputs.filter { $0.context.location?.source == .phone }.count
        #expect(Double(located) > Double(outputs.count) * 0.8)
        let status = try #require(outputs.first { $0.type == .deviceStatus })
        if case .deviceStatus(let info) = status.payload {
            #expect(info.batteryLevelPercent == 80)
            #expect(info.connectedBoards == 2)
        }

        let stored = try await rig.store.read { try StoreQueries.counts($0, sessionID: row.id) }
        let recordOutputs = outputs.filter { $0.type != .deviceStatus }.count
        #expect(stored.observations == recordOutputs)
        #expect(stored.accessPoints > 5 && stored.accessPoints < stored.observations)
        #expect(stored.bleDevices > 0 && stored.clients > 0 && stored.probes > 0)
        let session = try #require(try await rig.store.read { try StoreQueries.sessions($0).first })
        #expect(session.stoppedAt != nil)
        let track = try await rig.store.read { try StoreQueries.trackPoints($0, sessionID: row.id) }
        #expect(track.count >= 15)
        let map = try await rig.store.read { try StoreQueries.mapPoints($0, sessionID: row.id) }
        #expect(!map.isEmpty)

        // A second session gets a fresh session and numbering.
        await rig.walk(seconds: 1)
        let second = try await rig.controller.start()
        #expect(second.id != row.id)
        await rig.controller.stop()
        await rig.transport.shutdown()
    }

    @Test("Resume waits for boards and continues the mission and every number sequence", .timeLimit(.minutes(1)))
    func resume() async throws {
        let rig = try await makeRig(boards: 1)
        let row = try await rig.controller.start()
        await rig.walk(seconds: 3)
        #expect(await waitUntil {
            let delivered = await rig.controller.counters?.delivered ?? [:]
            return delivered[.wifiBeacon, default: 0] > 10 && delivered[.deviceStatus, default: 0] > 0
        })
        let relaunchedSink = RecordingSink()
        let env = SessionEnvironment(
            boards: BoardManagerSource(manager: rig.manager), location: rig.location, store: rig.store,
            settings: rig.settings, identity: DeviceIdentity(installID: Fixtures.installID, deviceName: "TestPhone"),
            app: Fixtures.app, filesRoot: FileManager.default.temporaryDirectory, makeSinks: { _ in [relaunchedSink] },
            flushInterval: .milliseconds(20), deviceStatusInterval: .milliseconds(100), stopGrace: .milliseconds(50)
        )
        let relaunched = SurveySessionController(environment: env)
        let unfinished = try #require(try await relaunched.unfinishedSession())
        #expect(unfinished.id == row.id)
        // Simulate termination: stop the first controller, reopen the row, and
        // drop the board so nothing is ready when the app comes back.
        await rig.controller.stop()
        try await rig.store.writer.write { try $0.execute(sql: "UPDATE session SET stoppedAt = NULL") }
        let saved = try await rig.store.recordNumbers(sessionID: row.id)
        #expect(saved.peek(.wifiBeacon) > 10)
        #expect(saved.peek(.deviceStatus) > 1)
        await rig.manager.disconnect(rig.ids[0])
        #expect(await waitUntil { rig.manager.readyBoards.isEmpty })

        try await relaunched.resume(unfinished)
        #expect(await relaunched.snapshot.state == .running)
        try await rig.manager.connect(rig.ids[0])
        #expect(await waitUntil {
            await rig.walk(seconds: 1)
            return !relaunchedSink.numbers(.wifiBeacon).isEmpty && !relaunchedSink.numbers(.deviceStatus).isEmpty
        })
        await relaunched.stop()
        #expect(relaunchedSink.state.withLock { $0.started.first?.missionId } == row.missionId)
        #expect(relaunchedSink.numbers(.wifiBeacon).first == saved.peek(.wifiBeacon))
        #expect(relaunchedSink.numbers(.deviceStatus).first == saved.peek(.deviceStatus))
        let gaps = try await rig.store.read { try StoreQueries.gapEvents($0, sessionID: row.id) }
        #expect(gaps.contains { $0.reason == "appRelaunch" && $0.endedAt != nil })
        #expect(try await relaunched.unfinishedSession() == nil)
        await rig.transport.shutdown()
    }

    @Test("Stop while starting stops once started; a second start is refused")
    func stopWhileStarting() async throws {
        let rig = try await makeRig(boards: 1, sinkDelay: .milliseconds(200))
        async let first = try? rig.controller.start()
        try await Task.sleep(for: .milliseconds(50))
        #expect(await rig.controller.snapshot.state == .starting)
        await #expect(throws: SessionError.notIdle) { try await rig.controller.start() }
        await rig.controller.stop()
        #expect(await rig.controller.snapshot.state == .idle)
        let row = await first
        let stored = try await rig.store.read { try StoreQueries.sessions($0) }
        #expect(stored.count == 1 && stored.first?.id == row?.id && stored.first?.stoppedAt != nil)
        await rig.transport.shutdown()
    }

    @Test("Stop does not hang on a stuck destination")
    func stuckSink() async throws {
        let rig = try await makeRig(boards: 1, stuck: true)
        try await rig.controller.start()
        await rig.walk(seconds: 2)
        let started = ContinuousClock.now
        await rig.controller.stop()
        #expect(ContinuousClock.now - started < .seconds(5))
        #expect(await rig.controller.snapshot.state == .idle)
        #expect(try await rig.store.read { try StoreQueries.sessions($0).first?.stoppedAt } != nil)
        await rig.transport.shutdown()
    }

    @Test("Low disk space stops the survey")
    func lowDisk() async throws {
        let rig = try await makeRig(boards: 1, freeBytes: 1_000)
        try await rig.controller.start()
        #expect(await waitUntil { await rig.controller.snapshot.state == .idle })
        #expect(await rig.controller.snapshot.stopReason == .lowDiskSpace)
        await rig.transport.shutdown()
    }

    @Test("A Demo board session gets an NS DEMO mission ID")
    func demoMissionID() async throws {
        let rig = try await makeRig(boards: 1, demo: true)
        let row = try await rig.controller.start()
        #expect(row.missionId == MissionID.makeDemo(startedAt: row.startedAt))
        #expect(row.missionId.hasPrefix("NS DEMO "))
        #expect(row.deviceSerialNumber == Fixtures.installID.uuidString)
        await rig.controller.stop()
        await rig.transport.shutdown()
    }

    @Test("Back-to-back sessions get different mission IDs")
    func distinctMissionIDs() async throws {
        let rig = try await makeRig(boards: 1)
        let first = try await rig.controller.start()
        await rig.controller.stop()
        let second = try await rig.controller.start()
        await rig.controller.stop()
        #expect(first.missionId != second.missionId)
        await rig.transport.shutdown()
    }

    @Test("SurveyModel mirrors the session")
    func facade() async throws {
        let rig = try await makeRig(boards: 1)
        let model = SurveyModel(
            controller: rig.controller, store: rig.store, boardManager: rig.manager, refreshInterval: .milliseconds(20)
        )
        #expect(await waitUntil { model.canStart })
        #expect(!model.isLocked)
        await model.start()
        #expect(await waitUntil { model.isRunning })
        #expect(model.isLocked)
        #expect(model.missionId?.hasPrefix("NS ") == true)
        await rig.walk(seconds: 3)
        #expect(await waitUntil { model.uniqueCounts.accessPoints > 0 && model.counters.delivered[.wifiBeacon, default: 0] > 0 })
        #expect(model.boards.first?.isConnected == true)
        #expect(await waitUntil { model.destinations.map(\.name) == ["recording"] })
        #expect(await waitUntil { model.location != nil })
        // A model that refreshes only at Stop still ends with the totals after the final flush.
        let slow = SurveyModel(
            controller: rig.controller, store: rig.store, boardManager: rig.manager, refreshInterval: .seconds(600)
        )
        #expect(await waitUntil { slow.session != nil })
        await rig.walk(seconds: 1)
        await slow.stop()
        #expect(slow.counters.delivered[.wifiBeacon] == rig.sink.numbers(.wifiBeacon).count)
        #expect(slow.uniqueCounts.accessPoints > 0)
        #expect(await waitUntil { model.state == .idle })
        await rig.transport.shutdown()
    }
}
