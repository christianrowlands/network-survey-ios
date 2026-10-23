import BoardProtocol
import Foundation
import Testing
@testable import BoardKit

/// Board IDs are stable across phones and reinstalls (they go into files and
/// become the NS Messaging sensor ID); CoreBluetooth identifiers stay internal.
@Suite("Stable board IDs", .timeLimit(.minutes(1)))
@MainActor
struct BoardIDTests {
    static let address = Data([0x02, 0x00, 0x5E, 0x00, 0xAB, 0xCD])

    @Test("The stable ID is NS- plus the BLE address in uppercase hex")
    func format() throws {
        let id = try #require(BoardID(btAddress: Self.address))
        #expect(id.rawValue == "NS-02005E00ABCD" && id.description == "NS-02005E00ABCD" && id.isStable)
        #expect(BoardID(btAddress: Data([1, 2, 3])) == nil)
        #expect(BoardID(info: NSBBoardInfo()) == nil)  // A board that sends no address.
        #expect(BoardID(info: .with { $0.btAddress = Self.address }) == id)
        let provisional = BoardID(UUID())
        #expect(!provisional.isStable && provisional.peripheralUUID != nil)
    }

    @Test("IDs encode as a plain string and still decode the old form")
    func coding() throws {
        let id = try #require(BoardID(btAddress: Self.address))
        #expect(String(decoding: try JSONEncoder().encode(id), as: UTF8.self) == "\"NS-02005E00ABCD\"")
        #expect(try JSONDecoder().decode(BoardID.self, from: JSONEncoder().encode(id)) == id)
        let uuid = UUID()
        let legacy = Data("{\"uuid\":\"\(uuid.uuidString)\"}".utf8)
        #expect(try JSONDecoder().decode(BoardID.self, from: legacy) == BoardID(uuid))
    }

    @Test("Connecting a scanned board returns its stable ID; state, records and the store use it")
    func connectResolves() async throws {
        let central = SimulatedBLECentral(boardCount: 1, seed: 3)
        let store = InMemoryKnownBoardStore()
        let rig = BLERig(central: central, store: store)
        let manager = BoardManager(transport: rig.transport, appVersion: "test")
        let records = Collector(manager.records())
        let events = Collector(rig.transport.events())
        let provisional = central.peripheralIDs[0]
        let stable = try await manager.connect(provisional)
        #expect(stable == central.boardIDs[0] && stable.isStable)
        #expect(manager.boards[stable]?.isReady == true)
        try await manager.startSurvey(SurveyCapture())
        await rig.advance(byMs: 2_000)
        #expect(await eventually { !records.values.isEmpty })
        #expect(records.values.allSatisfy { $0.boardID == stable })
        // Lagging events for the provisional ID must not leave a second entry behind.
        try await Task.sleep(for: .milliseconds(100))
        #expect(manager.boards[provisional] == nil)
        #expect(events.values.contains { if case .connectionState(stable, .connected) = $0 { true } else { false } })
        let known = try #require(store.load().first)
        #expect(known.id == stable && known.peripheralID == central.profiles[0].peripheralID)
        #expect(try await manager.connect(provisional) == stable)  // Already connected: same answer.
    }

    @Test("Known boards are listed and reconnected under their stable ID")
    func knownBoardsStable() async throws {
        let central = SimulatedBLECentral(boardCount: 2, seed: 3, pairedWithPhone: [0])
        let profile = central.profiles[0]
        let rig = BLERig(central: central, store: InMemoryKnownBoardStore([profile.knownBoard]))
        let lists = Collector(rig.transport.discoveries())
        await rig.transport.startScanning()
        #expect(await eventually { lists.values.last?.count == 2 })
        let ids = Set(lists.values.last?.map(\.id) ?? [])
        #expect(ids == [profile.id, central.peripheralIDs[1]])  // The unpaired board is still provisional.
        let manager = BoardManager(transport: rig.transport, appVersion: "test")
        await manager.reconnectKnownBoards()
        #expect(await eventually { manager.boards[profile.id]?.isReady == true })
    }

    @Test("Reading Info teaches the stable ID, so the scan shows it")
    func readInfoTeaches() async throws {
        let central = SimulatedBLECentral(boardCount: 1, seed: 3)
        let rig = BLERig(central: central, store: InMemoryKnownBoardStore())
        let lists = Collector(rig.transport.discoveries())
        await rig.transport.startScanning()
        #expect(await eventually { lists.values.last?.first?.id == central.peripheralIDs[0] })
        _ = try await rig.transport.readInfo(central.peripheralIDs[0])
        rig.central.advance(byMs: 1_000)  // Next advertisement.
        #expect(await eventually { lists.values.last?.first?.id == central.boardIDs[0] })
    }

    @Test("An entry stored with an old provisional ID is upgraded on the next connect")
    func legacyStoreEntry() async throws {
        let central = SimulatedBLECentral(boardCount: 1, seed: 3, pairedWithPhone: [0])
        let profile = central.profiles[0]
        let legacy = KnownBoard(id: BoardID(profile.peripheralID), info: profile.boardInfo, at: Date())
        let store = InMemoryKnownBoardStore([legacy])
        let rig = BLERig(central: central, store: store)
        let manager = BoardManager(transport: rig.transport, appVersion: "test")
        await manager.reconnectKnownBoards()
        #expect(await eventually { store.load().map(\.id) == [profile.id] })
        #expect(store.load().first?.peripheralID == profile.peripheralID)
        #expect(await eventually { manager.boards[profile.id]?.isReady == true })
    }

    @Test("The same board gets the same ID on two phones")
    func samePhysicalBoard() async throws {
        var ids: [BoardID] = []
        for _ in 0..<2 {
            // Each phone has its own CoreBluetooth identifier for the board.
            var profile = SimulatedBoardProfile.standard(count: 1, seed: 3)[0]
            profile.peripheralID = UUID()
            let central = SimulatedBLECentral(profiles: [profile], seed: 3)
            let manager = BoardManager(transport: BLERig(central: central, store: InMemoryKnownBoardStore()).transport, appVersion: "test")
            ids.append(try await manager.connect(BoardID(profile.peripheralID)))
            central.shutdown()
        }
        #expect(ids[0] == ids[1] && ids[0].isStable)
    }
}
