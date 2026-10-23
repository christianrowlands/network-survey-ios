import BoardProtocol
import CryptoKit
import Foundation
import Testing
@testable import BoardKit

/// BLEBoardTransport against SimulatedBLECentral: the CoreBluetooth-facing logic
/// without hardware.
@Suite("BLE transport", .timeLimit(.minutes(1)))
struct BLETransportTests {
    let central: SimulatedBLECentral
    let store = InMemoryKnownBoardStore()
    let transport: BLEBoardTransport

    init() {
        central = SimulatedBLECentral(boardCount: 3, seed: 11)
        transport = BLEBoardTransport(central: central, store: store, timing: .fast)
    }

    /// Provisional IDs: these boards have never been paired, so a scan is all we know.
    var ids: [BoardID] { central.peripheralIDs }

    func hello(_ id: BoardID) async throws {
        let response = try await transport.send(request(1, .hello(.current(appVersion: "test"))), to: id)
        #expect(response.result == .ok)
    }

    // MARK: - Discovery and pairing

    @Test("Scanning lists boards with their advertised flags")
    func discovery() async throws {
        let lists = Collector(transport.discoveries())
        await transport.startScanning()
        #expect(await eventually { lists.values.last?.count == 3 })
        let boards = try #require(lists.values.last)
        let c5 = try #require(boards.first { $0.id == ids[0] })
        #expect(c5.name == central.profiles[0].name && c5.shortID == central.profiles[0].shortID)
        #expect(c5.pairingMode && !c5.hasBond && c5.supports5GHz && !c5.hasGPS && !c5.isKnown)
        #expect(c5.model == .esp32C5Devkitc1 && c5.protocolMajor == 1)
        #expect(boards.first { $0.id == ids[2] }?.supports5GHz == false)  // The C6 profile.
        await transport.stopScanning()
    }

    @Test("Connect reads Info, pairs on the Control subscription and remembers the board")
    func connectPairs() async throws {
        let events = Collector(transport.events())
        #expect(!central.isBonded(ids[0]))
        try await transport.connect(ids[0])
        #expect(central.isBonded(ids[0]))
        let known = try #require(store.load().first)
        #expect(known.id == central.boardIDs[0] && known.id.isStable && known.shortID == central.profiles[0].shortID && known.model == .esp32C5Devkitc1)
        #expect(await transport.knownBoards().map(\.id) == [central.boardIDs[0]])
        #expect(await transport.maximumOTAWriteLength(for: ids[0]) == 244)
        let states = { events.values.compactMap { if case .connectionState(_, let state) = $0 { state } else { nil } } }
        #expect(await eventually { states().last?.isConnected == true })
        #expect(states().first == .connecting)
    }

    @Test("Info is readable without pairing")
    func infoWithoutPairing() async throws {
        let info = try await transport.readInfo(ids[1])
        #expect(info.shortID == central.profiles[1].shortID)
        #expect(info.boardModel == .xiaoEsp32C5)
        #expect(!central.isBonded(ids[1]))
        #expect(store.load().isEmpty)
    }

    @Test("A board bonded to another phone rejects pairing")
    func pairingRejected() async throws {
        central.bondToAnotherPhone(ids[0])
        let events = Collector(transport.events())
        await #expect(throws: BoardTransportError.pairingRejected) { try await transport.connect(ids[0]) }
        #expect(await eventually { events.values.contains { if case .connectionState(_, .disconnected(.pairingRejected)) = $0 { true } else { false } } })
        #expect(store.load().isEmpty)
    }

    @Test("Declining the pairing prompt is reported as rejected")
    func pairingDeclined() async throws {
        central.setUserAcceptsPairing(false, on: ids[0])
        await #expect(throws: BoardTransportError.pairingRejected) { try await transport.connect(ids[0]) }
    }

    @Test("A wiped bond gives the distinct bond-missing state (CBError 14) until the user forgets the board in Settings")
    func staleBond() async throws {
        try await transport.connect(ids[0])
        central.wipeBondsOnBoard(ids[0])
        await transport.disconnect(ids[0])
        let events = Collector(transport.events())
        await #expect(throws: BoardTransportError.bondMissing) { try await transport.connect(ids[0]) }
        #expect(await eventually { events.values.contains { if case .connectionState(_, .disconnected(.bondMissing)) = $0 { true } else { false } } })
        central.forgetOnPhone(ids[0])
        try await transport.connect(ids[0])
        #expect(central.isBonded(ids[0]))
    }

    @Test("A connect the system completes by itself is kept only for known boards")
    func restoration() async throws {
        let central = SimulatedBLECentral(boardCount: 2, seed: 5, pairedWithPhone: [0, 1])
        let known = central.profiles[0]
        let store = InMemoryKnownBoardStore([known.knownBoard])
        central.simulateRestoration(connected: central.boardIDs)
        let transport = BLEBoardTransport(central: central, store: store, timing: .fast)
        let events = Collector(transport.events())
        #expect(await eventually {
            events.values.contains { if case .connectionState(known.id, .connected) = $0 { true } else { false } }
        })
        let unknownIDs = [central.boardIDs[1], central.peripheralIDs[1]]
        #expect(!events.values.contains { if case .connectionState(let id, _) = $0 { unknownIDs.contains(id) } else { false } })
        let response = try await transport.send(request(3, ping(9)), to: known.id)
        #expect(response.requestID == 3)
        await #expect(throws: BoardTransportError.notConnected) { try await transport.send(request(4, ping(1)), to: central.boardIDs[1]) }
    }

    @Test("Bluetooth turning off drops the links and blocks connects")
    func poweredOff() async throws {
        try await transport.connect(ids[0])
        let events = Collector(transport.events())
        central.setPowerState(.poweredOff)
        #expect(await eventually { events.values.contains { if case .connectionState(_, .disconnected(.linkLost)) = $0 { true } else { false } } })
        await #expect(throws: BoardTransportError.bluetoothUnavailable("poweredOff")) { try await transport.connect(ids[1]) }
    }

    // MARK: - Control channel

    @Test("Responses are matched by request ID")
    func correlation() async throws {
        try await transport.connect(ids[0])
        let response = try await transport.send(request(42, ping(7)), to: ids[0])
        #expect(response.requestID == 42)
        guard case .ping(let result)? = response.payload else { Issue.record("no ping result"); return }
        #expect(result.nonce == 7)
    }

    @Test("A lost response times out and the next request still works")
    func timeout() async throws {
        try await transport.connect(ids[0])
        central.dropControlResponses(1, on: ids[0])
        await #expect(throws: BoardTransportError.timeout) {
            try await transport.send(request(1, ping(1)), to: ids[0], timeout: .milliseconds(100))
        }
        #expect(try await transport.send(request(2, ping(2)), to: ids[0]).requestID == 2)
    }

    @Test("A late response to a timed-out request is ignored")
    func lateResponse() async throws {
        try await transport.connect(ids[0])
        central.setControlLatency(ms: 1_000, on: ids[0])
        await #expect(throws: BoardTransportError.timeout) {
            try await transport.send(request(1, ping(1)), to: ids[0], timeout: .milliseconds(100))
        }
        central.setControlLatency(ms: 0, on: ids[0])
        central.advance(byMs: 1_000)  // The old answer arrives now.
        let response = try await transport.send(request(2, ping(2)), to: ids[0])
        #expect(response.requestID == 2)
        guard case .ping(let result)? = response.payload else { Issue.record("no ping result"); return }
        #expect(result.nonce == 2)
    }

    @Test("A request the board cannot decode is answered with ID 0 and still matched")
    func requestIDZero() async throws {
        try await transport.connect(ids[0])
        central.corruptControlWrites(1, on: ids[0])
        let response = try await transport.send(request(77, ping(1)), to: ids[0])
        #expect(response.requestID == 0)
        #expect(response.result == .invalidArgument)
    }

    @Test("Concurrent requests go out one at a time and each gets its own answer")
    func serialized() async throws {
        try await transport.connect(ids[0])
        central.setControlLatency(ms: 30, on: ids[0])
        let clock = Task {
            while !Task.isCancelled {
                central.advance(byMs: 10)
                try? await Task.sleep(for: .milliseconds(2))
            }
        }
        defer { clock.cancel() }
        let results = try await withThrowingTaskGroup(of: (UInt32, NSBControlResponse).self) { group in
            for id in UInt32(1)...6 {
                group.addTask { (id, try await transport.send(request(id, ping(id * 10)), to: ids[0])) }
            }
            return try await group.reduce(into: []) { $0.append($1) }
        }
        #expect(results.count == 6)
        for (id, response) in results {
            #expect(response.requestID == id)
            if case .ping(let result)? = response.payload { #expect(result.nonce == id * 10) }
        }
        #expect(central.maxOutstandingControl(ids[0]) == 1)
    }

    @Test("A link loss fails the pending request")
    func linkLossDuringRequest() async throws {
        try await transport.connect(ids[0])
        central.setControlLatency(ms: 5_000, on: ids[0])
        let pending = Task { [transport, ids] in try await transport.send(request(1, ping(1)), to: ids[0]) }
        try await Task.sleep(for: .milliseconds(50))
        central.injectLinkLoss(ids[0])
        await #expect(throws: BoardTransportError.notConnected) { try await pending.value }
        await #expect(throws: BoardTransportError.notConnected) { try await transport.send(request(2, ping(2)), to: ids[0]) }
    }

    @Test("Oversized control requests are refused before writing")
    func oversized() async throws {
        try await transport.connect(ids[0])
        let configure = NSBConfigure.with { $0.channels = Array(repeating: 1_000_000, count: 200) }
        await #expect(throws: BoardTransportError.self) {
            try await transport.send(request(1, .configure(configure)), to: ids[0])
        }
    }

    // MARK: - Framing

    @Test("Records, status and sequence gaps flow through the BLE framing")
    func framing() async throws {
        let events = Collector(transport.events())
        try await transport.connect(ids[0])
        try await hello(ids[0])
        _ = try await transport.send(request(2, .start(NSBStart())), to: ids[0])
        central.advance(byMs: 2_000)
        central.injectLostNotifications(3, on: ids[0])
        central.advance(byMs: 2_000)
        #expect(await eventually {
            events.values.reduce(0) { if case .records(_, let batch) = $1 { $0 + batch.missedNotifications } else { $0 } } == 3
        })
        let batches = events.values.compactMap { if case .records(_, let batch) = $0 { batch } else { nil } }
        #expect(batches.count > 10)
        #expect(batches.allSatisfy { $0.batch.timeSynced == false })  // No SetTime sent.
        #expect(events.values.contains { if case .status(_, let status) = $0 { status.state == .surveying } else { false } })
    }

    // MARK: - OTA

    func beginOTA(_ image: Data, on id: BoardID) async throws -> NSBOtaBeginResult {
        let begin = NSBOtaBegin.with {
            $0.imageSize = UInt32(image.count)
            $0.sha256 = Data(SHA256.hash(data: image))
        }
        let response = try await transport.send(request(9, .otaBegin(begin)), to: id)
        guard case .otaBegin(let result)? = response.payload else { throw BoardTransportError.malformedResponse }
        return result
    }

    static func image(_ size: Int) -> Data {
        Data((0..<size).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ 7) })
    }

    @Test("OTA: windowed transfer with write-without-response flow control installs the image")
    func otaTransfer() async throws {
        try await transport.connect(ids[0])
        let image = Self.image(40_000)
        let parameters = try await beginOTA(image, on: ids[0])
        #expect(parameters.maxChunkSize == 240 && parameters.windowBytes == 4096 && parameters.startOffset == 0)
        let progress = Recorder<Int>()
        try await OtaChunkSender(transport: transport, board: ids[0], image: image, parameters: parameters)
            .run { progress.append($0) }
        #expect(progress.values.first == 0 && progress.values.last == image.count)
        #expect(progress.values == progress.values.sorted())
        #expect(central.maxOTABytesAheadOfAck(ids[0]) <= 4096)
        #expect(central.receivedOTABytes(ids[0]) == image)
        let end = try await transport.send(request(10, .otaEnd(NSBOtaEnd())), to: ids[0])
        #expect(end.result == .ok)
        #expect(central.installedImage(ids[0]) == image)
    }

    @Test("OTA: lost chunks are recovered through OUT_OF_ORDER")
    func otaLostChunks() async throws {
        try await transport.connect(ids[0])
        central.dropOTAChunks([3, 20, 21, 40], on: ids[0])
        let image = Self.image(20_000)
        let parameters = try await beginOTA(image, on: ids[0])
        try await OtaChunkSender(transport: transport, board: ids[0], image: image, parameters: parameters).run()
        #expect(central.receivedOTABytes(ids[0]) == image)
    }

    @Test("OTA: a silent board stalls the transfer")
    func otaStalled() async throws {
        try await transport.connect(ids[0])
        central.dropOTAChunks(Set(1...10_000), on: ids[0])
        let image = Self.image(5_000)
        var sender = OtaChunkSender(transport: transport, board: ids[0], image: image, parameters: try await beginOTA(image, on: ids[0]))
        sender.ackTimeout = .milliseconds(50)
        sender.maxSilentResends = 2
        await #expect(throws: OtaTransferError.stalled(acknowledged: 0)) { try await sender.run() }
    }

    @Test("OTA: a chunk without OtaBegin is refused by the board")
    func otaNotActive() async throws {
        try await transport.connect(ids[0])
        let image = Self.image(1_000)
        let sender = OtaChunkSender(
            transport: transport, board: ids[0], image: image,
            parameters: .with { $0.maxChunkSize = 240; $0.windowBytes = 4096 }
        )
        await #expect(throws: OtaTransferError.boardAborted(.notActive)) { try await sender.run() }
    }

    @Test("OTA chunks carry a little-endian offset")
    func chunkFormat() {
        let chunk = OtaChunkSender.chunk(Data([1, 2, 3, 4, 5, 6]), from: 2, to: 5)
        #expect(chunk == Data([2, 0, 0, 0, 3, 4, 5]))
        #expect(OtaChunkSender.chunk(Data(count: 70_000), from: 0x1_0203, to: 0x1_0204).prefix(4) == Data([0x03, 0x02, 0x01, 0x00]))
    }
}
