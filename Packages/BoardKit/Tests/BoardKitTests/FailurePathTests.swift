import BoardProtocol
import CryptoKit
import Foundation
import Synchronization
import Testing
@testable import BoardKit

/// Failure paths found in review, driven by fault injection in the simulated central.
@Suite("Failure paths", .timeLimit(.minutes(1)))
@MainActor
struct FailurePathTests {
    static let fastReconnect = ReconnectPolicy(initialDelay: .milliseconds(10), multiplier: 2, maxDelay: .milliseconds(80))

    func makeManager(_ rig: any TransportRig, policy: ReconnectPolicy = fastReconnect) -> BoardManager {
        BoardManager(transport: rig.transport, appVersion: "test", reconnectPolicy: policy, resplitGrace: .milliseconds(50))
    }

    /// Advances simulated time continuously so delayed control responses arrive.
    func runClock(_ central: SimulatedBLECentral) -> Task<Void, Never> {
        Task.detached {
            while !Task.isCancelled {
                central.advance(byMs: 10)
                try? await Task.sleep(for: .milliseconds(2))
            }
        }
    }

    func readyCount(_ events: Collector<BoardManagerEvent>, _ id: BoardID) -> Int {
        events.values.filter { $0 == .ready(id) }.count
    }

    // MARK: - Init race

    @Test("A board connected right after the manager is created is picked up", arguments: RigKind.allCases)
    func connectRightAfterInit(kind: RigKind) async throws {
        let rig = kind.make()
        let id = rig.boardIDs[0]
        let manager = makeManager(rig)
        // Same synchronous turn as init: the connect can finish before any manager task runs.
        let connecting = Task { [transport = rig.transport, key = rig.key(id)] in try await transport.connect(key) }
        try await connecting.value
        #expect(await eventually { manager.boards[id]?.isReady == true })
        await rig.shutdown()
    }

    @Test("A board connected before the manager exists is picked up", arguments: RigKind.allCases)
    func connectBeforeInit(kind: RigKind) async throws {
        let rig = kind.make()
        let id = rig.boardIDs[0]
        try await rig.transport.connect(rig.key(id))
        let manager = makeManager(rig)
        #expect(await eventually { manager.boards[id]?.isReady == true })
        await rig.shutdown()
    }

    // MARK: - M1: link loss while busy

    @Test("A link loss during the first re-plan after connect is reconnected")
    func dropDuringConnectReplan() async throws {
        let rig = BLERig(central: SimulatedBLECentral(boardCount: 2, seed: 3), store: InMemoryKnownBoardStore())
        let manager = makeManager(rig)
        let events = Collector(manager.events())
        let (a, b) = (rig.boardIDs[0], rig.boardIDs[1])
        let clock = runClock(rig.central)
        defer { clock.cancel() }
        try await manager.connect(rig.key(a))
        try await manager.startSurvey(SurveyCapture())
        rig.central.setControlLatency(ms: 300, on: b)
        let connecting = Task { try await manager.connect(rig.key(b)) }
        #expect(await eventually { readyCount(events, b) == 1 })
        rig.central.injectLinkLoss(b)  // Configure for b is in flight.
        rig.central.setControlLatency(ms: 0, on: b)
        _ = try await connecting.value
        #expect(await eventually { readyCount(events, b) == 2 && manager.boards[b]?.assignment != nil })
        #expect(events.values.contains { if case .linkGapStarted(b, _) = $0 { true } else { false } })
        #expect(await eventually { events.values.contains { if case .linkGapEnded(b, _, resumed: true) = $0 { true } else { false } } })
    }

    @Test("A second link loss during the reconnect's re-plan is retried")
    func dropDuringReconnectReplan() async throws {
        let rig = BLERig(central: SimulatedBLECentral(boardCount: 1, seed: 3), store: InMemoryKnownBoardStore())
        let manager = makeManager(rig)
        let events = Collector(manager.events())
        let id = rig.boardIDs[0]
        let clock = runClock(rig.central)
        defer { clock.cancel() }
        try await manager.connect(rig.key(id))
        try await manager.startSurvey(SurveyCapture())
        rig.central.setControlLatency(ms: 300, on: id)
        rig.central.injectLinkLoss(id)
        #expect(await eventually { readyCount(events, id) == 2 })  // Hello done, Configure in flight.
        rig.central.injectLinkLoss(id)
        rig.central.setControlLatency(ms: 0, on: id)
        // Whether the drop hit the re-plan or just missed it (under load), the
        // board must end up surveying again with every gap closed.
        #expect(await eventually {
            readyCount(events, id) >= 3 && manager.boards[id]?.isReady == true && manager.boards[id]?.assignment != nil
                && manager.boards[id]?.reconnect == nil
        })
        let gaps = {
            events.values.compactMap { event -> Bool? in
                switch event {
                case .linkGapStarted(id, _): true
                case .linkGapEnded(id, _, resumed: true): false
                default: nil
                }
            }
        }
        #expect(await eventually { gaps().first == true && gaps().last == false }, "\(gaps())")
    }

    @Test("A restored board whose Hello fails is retried, not dropped")
    func adoptRetries() async throws {
        let central = SimulatedBLECentral(boardCount: 1, seed: 3, pairedWithPhone: [0])
        let profile = central.profiles[0]
        let store = InMemoryKnownBoardStore([profile.knownBoard])
        central.corruptControlWrites(1, on: profile.id)
        central.simulateRestoration(connected: [profile.id])
        let manager = makeManager(BLERig(central: central, store: store))
        let events = Collector(manager.events())
        #expect(await eventually { manager.boards[profile.id]?.isReady == true })
        #expect(events.values.contains { if case .reconnectAttemptFailed(profile.id, 1, _) = $0 { true } else { false } })
    }

    // MARK: - S1

    @Test("A failed handshake disconnects the board so it advertises again")
    func failedHandshakeDisconnects() async throws {
        let rig = BLERig(central: SimulatedBLECentral(boardCount: 1, seed: 3), store: InMemoryKnownBoardStore())
        let manager = makeManager(rig)
        let transportEvents = Collector(rig.transport.events())
        let managerEvents = Collector(manager.events())
        let id = rig.boardIDs[0]
        rig.central.corruptControlWrites(1, on: id)
        await #expect(throws: BoardManagerError.self) { try await manager.connect(rig.key(id)) }
        #expect(await eventually { !rig.central.isConnected(id) }, "\(transportEvents.values.filter { if case .connectionState = $0 { true } else { false } }) \(managerEvents.values.filter { if case .status = $0 { false } else { true } })")
        try await Task.sleep(for: .milliseconds(100))
        #expect(manager.boards[id]?.reconnect == nil && !rig.central.isConnected(id))
        try await manager.connect(rig.key(id))  // The user can try again.
        #expect(manager.boards[id]?.isReady == true)
    }

    // MARK: - S3

    @Test("stopSurvey during a re-plan leaves no board surveying")
    func stopDuringReplan() async throws {
        let rig = BLERig(central: SimulatedBLECentral(boardCount: 2, seed: 3), store: InMemoryKnownBoardStore())
        let manager = makeManager(rig)
        let events = Collector(manager.events())
        let (a, b) = (rig.boardIDs[0], rig.boardIDs[1])
        let clock = runClock(rig.central)
        defer { clock.cancel() }
        try await manager.connect(rig.key(a))
        try await manager.startSurvey(SurveyCapture())
        rig.central.setControlLatency(ms: 200, on: b)
        let connecting = Task { try await manager.connect(rig.key(b)) }
        #expect(await eventually { readyCount(events, b) == 1 })
        await manager.stopSurvey()
        _ = try await connecting.value
        #expect(manager.capture == nil)
        #expect(await eventually(timeout: .seconds(10)) {
            manager.boards[a]?.status?.state == .idle && manager.boards[b]?.status?.state == .idle
        })
        try await Task.sleep(for: .milliseconds(300))
        #expect(manager.boards[b]?.status?.state == .idle)
        #expect(manager.boards[a]?.assignment == nil && manager.boards[b]?.assignment == nil)
    }

    // MARK: - S6

    @Test("Restoration before Bluetooth is on waits for it, then adopts known boards and drops unknown ones")
    func restorationBeforePowerOn() async throws {
        let central = SimulatedBLECentral(boardCount: 2, seed: 5, pairedWithPhone: [0, 1])
        let (known, unknown) = (central.profiles[0], central.profiles[1])
        let store = InMemoryKnownBoardStore([known.knownBoard])
        central.simulateRestoration(connected: [known.id, unknown.id], poweredOn: false)
        let manager = makeManager(BLERig(central: central, store: store))
        try await Task.sleep(for: .milliseconds(100))
        #expect(manager.boards[known.id]?.isReady != true)
        #expect(central.isConnected(unknown.id))  // A cancel while off does nothing.
        central.setPowerState(.poweredOn)
        #expect(await eventually { manager.boards[known.id]?.isReady == true })
        #expect(await eventually { !central.isConnected(unknown.id) })
        #expect(manager.boards[unknown.id]?.isReady != true)
    }

    // MARK: - S8

    @Test("Reconnect resumes as soon as Bluetooth is back, not after the backoff")
    func bluetoothBack() async throws {
        let rig = BLERig(central: SimulatedBLECentral(boardCount: 1, seed: 3), store: InMemoryKnownBoardStore())
        let policy = ReconnectPolicy(initialDelay: .seconds(3), multiplier: 2, maxDelay: .seconds(10))
        let manager = makeManager(rig, policy: policy)
        let id = rig.boardIDs[0]
        try await manager.connect(rig.key(id))
        rig.central.setPowerState(.poweredOff)
        #expect(await eventually { manager.bluetoothState == .poweredOff && manager.boards[id]?.reconnect != nil })
        try await Task.sleep(for: .milliseconds(300))
        let back = ContinuousClock.now
        rig.central.setPowerState(.poweredOn)
        #expect(await eventually { manager.boards[id]?.isReady == true })
        #expect(ContinuousClock.now - back < .seconds(2))
        #expect(manager.bluetoothState == .poweredOn)
    }

    // MARK: - S7

    @Test("A new survey starts counters and channel activity from zero")
    func perSurveyCounters() async throws {
        let rig = RigKind.simulatedTransport.make()
        let manager = makeManager(rig)
        let id = rig.boardIDs[0]
        try await manager.connect(rig.key(id))
        try await manager.startSurvey(SurveyCapture())
        await rig.advance(byMs: 3_000)
        #expect(await eventually { manager.counters(for: id).records > 0 })
        #expect(!manager.router.channelWeights().isEmpty)
        await manager.stopSurvey()
        try await Task.sleep(for: .milliseconds(50))
        try await manager.startSurvey(SurveyCapture())
        #expect(manager.counters(for: id).records == 0)
        #expect(manager.boards[id]?.counters.records == 0)
        #expect(manager.router.channelWeights().isEmpty)
        await rig.shutdown()
    }

    @Test("Channel activity is capped per channel")
    func weightCap() {
        let router = BoardRecordRouter()
        let records = (0..<600).map { index in
            NSBRecord.with {
                $0.ap = .with {
                    $0.channel = 6
                    $0.bssid = Data([0x02, 0x00, 0x5E, 0x00, UInt8(index >> 8), UInt8(index & 0xFF)])
                }
            }
        }
        for chunk in stride(from: 0, to: records.count, by: 12) {
            router.route(
                ChannelPlannerTests.id(1),
                ReceivedRecordBatch(sequence: 0, missedNotifications: 0, batch: .with { $0.records = Array(records[chunk..<min(chunk + 12, records.count)]) }, receivedAt: Date())
            )
        }
        #expect(router.channelWeights()[6] == 1 + Double(BoardRecordRouter.maxBSSIDsPerChannel))
    }

    // MARK: - N7

    @Test("A manual BLE sniffer with BLE off falls back to AUTO")
    func snifferWithBLEOff() {
        let board = ChannelPlannerTests.board(1, ChannelPlannerTests.only24, .bleSniffer)
        let plan = ChannelPlanner.plan([board], options: .init(ble: false))
        #expect(plan[board.id] == BoardAssignment(role: .auto, channels: WifiChannels.band24, ble: false))
    }
}

/// OTA failure paths on the BLE transport.
@Suite("OTA failure paths", .timeLimit(.minutes(1)))
struct OtaFailurePathTests {
    let central = SimulatedBLECentral(boardCount: 1, seed: 11)
    let transport: BLEBoardTransport

    init() {
        transport = BLEBoardTransport(central: central, timing: .fast)
    }

    var id: BoardID { central.peripheralIDs[0] }

    func begin(_ image: Data) async throws -> NSBOtaBeginResult {
        let response = try await transport.send(request(9, .otaBegin(.with {
            $0.imageSize = UInt32(image.count)
            $0.sha256 = Data(SHA256.hash(data: image))
        })), to: id)
        guard case .otaBegin(let result)? = response.payload else { throw BoardTransportError.malformedResponse }
        return result
    }

    @Test("Window is a whole number of chunks; a window smaller than a chunk shrinks the chunk")
    func layout() {
        #expect(OtaChunkSender.layout(maxChunkSize: 240, windowBytes: 4096, writeLimit: 244) == (240, 4080))
        #expect(OtaChunkSender.layout(maxChunkSize: 240, windowBytes: 100, writeLimit: 244) == (100, 100))
        #expect(OtaChunkSender.layout(maxChunkSize: 500, windowBytes: 4096, writeLimit: 184) == (180, 3960))
        #expect(OtaChunkSender.layout(maxChunkSize: 240, windowBytes: 0, writeLimit: 244) == (240, 240))
    }

    @Test("Lost acks, including the final one, are recovered from the board's duplicate ack")
    func lostFinalAck() async throws {
        try await transport.connect(id)
        let image = BLETransportTests.image(20_000)
        central.dropOTAAck(atOffset: 20_000, on: id)
        central.dropOTAAck(atOffset: 2_160, on: id)
        var sender = OtaChunkSender(transport: transport, board: id, image: image, parameters: try await begin(image))
        sender.ackTimeout = .milliseconds(100)
        try await sender.run()
        #expect(central.receivedOTABytes(id) == image)
        #expect(try await transport.send(request(10, .otaEnd(NSBOtaEnd())), to: id).result == .ok)
    }

    @Test("Cancelling the task stops the transfer promptly")
    func cancel() async throws {
        try await transport.connect(id)
        central.dropOTAChunks(Set(1...100_000), on: id)
        let image = BLETransportTests.image(50_000)
        let sender = OtaChunkSender(transport: transport, board: id, image: image, parameters: try await begin(image))
        let run = Task { () -> OtaTransferError? in
            do throws(OtaTransferError) {
                try await sender.run()
                return nil
            } catch {
                return error
            }
        }
        try await Task.sleep(for: .milliseconds(100))
        let cancelled = ContinuousClock.now
        run.cancel()
        #expect(await run.value == .transport(.cancelled))
        #expect(ContinuousClock.now - cancelled < .seconds(1))
    }
}
