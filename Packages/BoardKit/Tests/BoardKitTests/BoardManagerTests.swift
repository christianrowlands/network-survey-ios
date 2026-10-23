import BoardProtocol
import Foundation
import Testing
@testable import BoardKit

/// The same manager behaviour on the simulated transport and on the BLE
/// transport over the simulated central.
@Suite("Board manager", .timeLimit(.minutes(1)))
@MainActor
struct BoardManagerTests {
    static let fastReconnect = ReconnectPolicy(initialDelay: .milliseconds(10), multiplier: 2, maxDelay: .milliseconds(80))

    func makeManager(_ rig: any TransportRig) -> BoardManager {
        BoardManager(transport: rig.transport, appVersion: "test", reconnectPolicy: Self.fastReconnect, resplitGrace: .milliseconds(50))
    }

    @Test("Connect says Hello, syncs the clock and records flow with counters", arguments: RigKind.allCases)
    func connectAndStream(kind: RigKind) async throws {
        let rig = kind.make()
        let manager = makeManager(rig)
        let id = rig.boardIDs[0]
        let envelopes = Collector(manager.records())
        try await manager.connect(rig.key(id))
        #expect(manager.boards[id]?.isReady == true)
        #expect(manager.boards[id]?.compatibility == .compatible(firmwareVersion: "1.0.0"))
        let plan = try await manager.startSurvey(SurveyCapture())
        #expect(plan[id]?.channels == WifiChannels.band24 + WifiChannels.band5)
        await rig.advance(byMs: 3_000)
        #expect(await eventually { manager.counters(for: id).records > 50 && envelopes.values.count == manager.counters(for: id).records })
        #expect(await eventually {
            manager.counters(for: id).recordsByKind[.ap, default: 0] > 0 && manager.counters(for: id).recordsByKind[.ble, default: 0] > 0
        })
        #expect(envelopes.values.allSatisfy { $0.boardID == id && $0.boardTimeMs != nil })
        // SetTime made board time epoch based.
        let now = UInt64(Date().timeIntervalSince1970 * 1000)
        #expect(envelopes.values.allSatisfy { $0.boardTimeMs! > now - 60_000 && $0.boardTimeMs! < now + 60_000 })
        #expect(await eventually { manager.boards[id]?.status?.state == .surveying })
        await manager.stopSurvey()
        #expect(manager.capture == nil)
        await rig.shutdown()
    }

    @Test("Raw frames: beacons within the rate limit, only when asked for", arguments: RigKind.allCases)
    func rawFrames(kind: RigKind) async throws {
        let rig = kind.make()
        let manager = makeManager(rig)
        let id = rig.boardIDs[0]
        let raw = Collector(manager.rawFrames())
        try await manager.connect(rig.key(id))
        try await manager.startSurvey(SurveyCapture())
        await rig.advance(byMs: 2_000)
        try await Task.sleep(for: .milliseconds(100))
        #expect(raw.values.isEmpty)
        await manager.stopSurvey()
        var capture = SurveyCapture()
        capture.rawFrames = true
        try await manager.startSurvey(capture)
        await rig.advance(byMs: 3_000)
        #expect(await eventually { raw.values.count >= 20 })
        // At most 20 per second (the default limit), plus one second of slack.
        #expect(raw.values.count <= 80)
        let frame = try #require(raw.values.first?.frame)
        #expect(frame.data.prefix(2) == Data([0x80, 0x00]))
        #expect(frame.data.count == Int(frame.origLen) && frame.channel > 0 && frame.rssi < 0)
        #expect(raw.values.allSatisfy { $0.boardID == id })
        await rig.shutdown()
    }

    @Test("Sequence gaps are counted per board", arguments: RigKind.allCases)
    func gaps(kind: RigKind) async throws {
        let rig = kind.make(boards: 2)
        let manager = makeManager(rig)
        for id in rig.boardIDs { try await manager.connect(rig.key(id)) }
        try await manager.startSurvey(SurveyCapture())
        await rig.advance(byMs: 2_000)
        await rig.injectLostNotifications(4, on: rig.boardIDs[1])
        await rig.advance(byMs: 3_000)
        #expect(await eventually { manager.counters(for: rig.boardIDs[1]).missedNotifications == 4 })
        #expect(manager.counters(for: rig.boardIDs[0]).missedNotifications == 0)
        #expect(await eventually { manager.boards[rig.boardIDs[1]]?.missedNotifications == 4 })  // Copied on status.
        await rig.shutdown()
    }

    @Test("Up to four boards share the work; a fifth is refused", arguments: RigKind.allCases)
    func fourBoardSplit(kind: RigKind) async throws {
        let rig = kind.make(boards: 5)
        let manager = makeManager(rig)
        for id in rig.boardIDs.prefix(4) { try await manager.connect(rig.key(id)) }
        await #expect(throws: BoardManagerError.tooManyBoards) { try await manager.connect(rig.key(rig.boardIDs[4])) }
        let plan = try await manager.startSurvey(SurveyCapture())
        // Standard profiles: C5, XIAO C5, C6 (2.4 only), C5. The C6 becomes the BLE sniffer.
        let c6 = rig.boardIDs[2]
        #expect(plan[c6]?.role == .bleSniffer)
        let wifi = rig.boardIDs.prefix(4).filter { $0 != c6 }
        let sets = wifi.compactMap { manager.boards[$0]?.configured?.channels }
        #expect(sets.count == 3)
        #expect(Set(sets.flatMap { $0 }) == Set(WifiChannels.band24 + WifiChannels.band5))
        #expect(sets.map(\.count).reduce(0, +) == 38)
        #expect(manager.boards[c6]?.configured?.role == .bleSniffer)
        await rig.advance(byMs: 2_000)
        #expect(await eventually { manager.counters(for: c6).records > 0 })
        #expect(manager.counters(for: c6).recordsByKind.keys.allSatisfy { $0 == .ble })
        await rig.shutdown()
    }

    @Test("A dropped board reconnects, gets its role back and the gap is reported", arguments: RigKind.allCases)
    func reconnect(kind: RigKind) async throws {
        let rig = kind.make(boards: 2)
        let manager = makeManager(rig)
        let events = Collector(manager.events())
        for id in rig.boardIDs { try await manager.connect(rig.key(id)) }
        let plan = try await manager.startSurvey(SurveyCapture())
        let id = rig.boardIDs[0]
        await rig.advance(byMs: 1_000)
        await rig.injectLinkLoss(id)
        #expect(await eventually {
            events.values.contains { if case .linkGapEnded(id, _, resumed: true) = $0 { true } else { false } }
        })
        #expect(events.values.contains { if case .linkGapStarted(id, _) = $0 { true } else { false } })
        #expect(manager.boards[id]?.isReady == true)
        #expect(manager.boards[id]?.assignment == plan[id], "\(String(describing: manager.boards[id]?.assignment)), issue \(String(describing: manager.boards[id]?.issue))")
        #expect(manager.counters(for: id).linkGaps == 1)
        let before = manager.counters(for: id).records
        await rig.advance(byMs: 2_000)
        #expect(await eventually { manager.counters(for: id).records > before })
        await rig.shutdown()
    }

    @Test("When a board leaves, the others take over its channels", arguments: RigKind.allCases)
    func resplitOnLeave(kind: RigKind) async throws {
        let rig = kind.make(boards: 2)
        let manager = makeManager(rig)
        for id in rig.boardIDs { try await manager.connect(rig.key(id)) }
        var capture = SurveyCapture()
        capture.ble = false
        try await manager.startSurvey(capture)
        let remaining = rig.boardIDs[1]
        #expect(manager.boards[remaining]?.configured?.channels.count == 19)
        await manager.disconnect(rig.boardIDs[0])
        #expect(await eventually { manager.boards[remaining]?.configured?.channels.count == 38 })
        await rig.shutdown()
    }

    @Test("An incompatible board is blocked with a reason and stays connected for an update", arguments: RigKind.allCases)
    func incompatible(kind: RigKind) async throws {
        var profiles = SimulatedBoardProfile.standard(count: 1, seed: 7)
        profiles[0].protocolMajor = 2
        let rig = kind.make(profiles: profiles)
        let manager = makeManager(rig)
        let id = rig.boardIDs[0]
        await #expect(throws: BoardManagerError.self) { try await manager.connect(rig.key(id)) }
        guard case .incompatible(let reason)? = manager.boards[id]?.compatibility else {
            Issue.record("not marked incompatible")
            return
        }
        #expect(reason.contains("protocol 2") && reason.contains("Update the app"))
        #expect(manager.boards[id]?.isReady == false)
        #expect(await eventually { manager.boards[id]?.connection.isConnected == true })
        await #expect(throws: BoardManagerError.notReady) { try await manager.startSurvey(SurveyCapture()) }
        await rig.shutdown()
    }

    @Test("Board drops reported in status are accounted, including during a disconnect", arguments: RigKind.allCases)
    func dropAccounting(kind: RigKind) async throws {
        let rig = kind.make()
        let manager = makeManager(rig)
        let events = Collector(manager.events())
        let id = rig.boardIDs[0]
        try await manager.connect(rig.key(id))
        try await manager.startSurvey(SurveyCapture())
        await rig.advance(byMs: 1_500)
        #expect(await eventually { manager.boards[id]?.status != nil })
        await manager.disconnect(id)
        await rig.advance(byMs: 90_000)  // The board keeps surveying; its ring overflows.
        try await manager.connect(rig.key(id))
        await rig.advance(byMs: 2_000)
        #expect(await eventually { manager.counters(for: id).droppedRecords > 0 })
        #expect(await eventually { events.values.contains { if case .drops(id, let drops) = $0 { drops.records > 0 } else { false } } })
        await rig.shutdown()
    }

    // MARK: - BLE only

    func bleRig(boards: Int = 1, store: InMemoryKnownBoardStore = InMemoryKnownBoardStore(), paired: Set<Int> = []) -> BLERig {
        BLERig(central: SimulatedBLECentral(boardCount: boards, seed: 3, pairedWithPhone: paired), store: store)
    }

    @Test("Reconnect backs off between failed attempts")
    func backoff() async throws {
        let rig = bleRig()
        let manager = makeManager(rig)
        let events = Collector(manager.events())
        let id = rig.boardIDs[0]
        try await manager.connect(rig.key(id))
        rig.central.failNextConnects(3, on: id)
        let started = ContinuousClock.now
        rig.central.injectLinkLoss(id)
        #expect(await eventually {
            events.values.contains { if case .linkGapEnded(id, _, resumed: true) = $0 { true } else { false } }
        })
        #expect(manager.boards[id]?.isReady == true)
        let failures = events.values.compactMap { if case .reconnectAttemptFailed(_, let attempt, _) = $0 { attempt } else { nil } }
        #expect(failures == [1, 2, 3])
        #expect(ContinuousClock.now - started >= .milliseconds(10 + 20 + 40))
    }

    @Test("A wiped bond stops reconnecting and asks the user to forget the board in Settings")
    func bondMissingStopsReconnect() async throws {
        let rig = bleRig()
        let manager = makeManager(rig)
        let events = Collector(manager.events())
        let id = rig.boardIDs[0]
        try await manager.connect(rig.key(id))
        rig.central.wipeBondsOnBoard(id)
        rig.central.injectLinkLoss(id)
        #expect(await eventually { manager.boards[id]?.issue == .bondMissing })
        #expect(await eventually { events.values.contains(.bondMissing(id)) })
        #expect(events.values.filter { $0 == .bondMissing(id) }.count == 1)
        #expect(await eventually { events.values.contains { if case .linkGapEnded(id, _, resumed: false) = $0 { true } else { false } } })
        try await Task.sleep(for: .milliseconds(200))
        #expect(manager.boards[id]?.reconnect == nil)
        #expect(manager.boards[id]?.connection == .disconnected(.bondMissing))
    }

    @Test("Forget tells the board, which leaves the phone with a stale bond until Settings > Forget")
    func forget() async throws {
        let rig = bleRig()
        let manager = makeManager(rig)
        let id = rig.boardIDs[0]
        try await manager.connect(rig.key(id))
        #expect(await manager.forget(id))
        #expect(rig.store.load().isEmpty)
        #expect(manager.boards[id] == nil)
        await #expect(throws: BoardTransportError.bondMissing) { try await manager.connect(rig.key(id)) }
        #expect(manager.boards[id]?.issue == .bondMissing)
        rig.central.forgetOnPhone(id)
        try await manager.connect(rig.key(id))
        #expect(manager.boards[id]?.isReady == true)
    }

    @Test("Silent reconnect only touches known boards and waits for one out of range")
    func reconnectKnown() async throws {
        let central = SimulatedBLECentral(boardCount: 2, seed: 3, pairedWithPhone: [0, 1])
        let known = central.profiles[0]
        let store = InMemoryKnownBoardStore([known.knownBoard])
        let rig = BLERig(central: central, store: store)
        central.setInRange(false, known.id)
        let manager = makeManager(rig)
        await manager.reconnectKnownBoards()
        try await Task.sleep(for: .milliseconds(100))
        #expect(manager.boards[known.id]?.connection == .connecting)  // A pending connect.
        central.setInRange(true, known.id)
        #expect(await eventually { manager.boards[known.id]?.isReady == true })
        #expect(manager.boards[central.boardIDs[1]] == nil)
    }

    @Test("A board restored by the system is adopted and resumes the survey")
    func restoredBoard() async throws {
        let central = SimulatedBLECentral(boardCount: 1, seed: 3, pairedWithPhone: [0])
        let profile = central.profiles[0]
        let store = InMemoryKnownBoardStore([profile.knownBoard])
        central.simulateRestoration(connected: [profile.id])
        let manager = makeManager(BLERig(central: central, store: store))
        #expect(await eventually { manager.boards[profile.id]?.isReady == true })
        try await manager.startSurvey(SurveyCapture())
        #expect(manager.boards[profile.id]?.assignment != nil)
    }

    @Test("A firmware update owns the board until it is handed back")
    func firmwareUpdateHook() async throws {
        let rig = bleRig()
        let manager = makeManager(rig)
        let events = Collector(manager.events())
        let id = rig.boardIDs[0]
        try await manager.connect(rig.key(id))
        #expect(manager.boards[id]?.hello?.firmwareVersion == "1.0.0")
        try await manager.startSurvey(SurveyCapture())
        #expect(throws: BoardManagerError.surveyRunning) { try manager.beginFirmwareUpdate(id) }
        await manager.stopSurvey()
        try manager.beginFirmwareUpdate(id)
        #expect(manager.boards[id]?.isUpdating == true && manager.boards[id]?.isReady == false)
        await #expect(throws: BoardManagerError.busy) { try await manager.connect(rig.key(id)) }
        // The board reboots into new firmware: the manager neither reconnects nor adopts it.
        rig.central.injectLinkLoss(id)
        try await Task.sleep(for: .milliseconds(200))
        #expect(manager.boards[id]?.reconnect == nil)
        try await rig.ble.connect(id)  // The update flow reconnects by itself.
        try await Task.sleep(for: .milliseconds(100))
        #expect(manager.boards[id]?.isReady == false)
        #expect(!events.values.contains { if case .linkGapStarted = $0 { true } else { false } })
        manager.endFirmwareUpdate(id)
        #expect(await eventually { manager.boards[id]?.isReady == true })
        #expect(manager.boards[id]?.isUpdating == false)
        #expect(manager.boards[id]?.hello != nil)
    }

    @Test("Handing back a board that is still rebooting waits for it with a pending connect")
    func firmwareUpdateEndWhileAway() async throws {
        let rig = bleRig()
        let manager = makeManager(rig)
        let id = rig.boardIDs[0]
        try await manager.connect(rig.key(id))
        try manager.beginFirmwareUpdate(id)
        rig.central.injectLinkLoss(id, outOfRange: true)
        try await Task.sleep(for: .milliseconds(50))
        manager.endFirmwareUpdate(id)
        try await Task.sleep(for: .milliseconds(100))
        #expect(manager.boards[id]?.isReady == false)
        rig.central.setInRange(true, id)
        #expect(await eventually { manager.boards[id]?.isReady == true })
    }
}
