import BoardProtocol
import Foundation
import Testing
@testable import BoardKit

@Suite("Simulated board transport")
struct SimulatedBoardTransportTests {
    @Test("Same seed and commands give byte-identical output")
    func determinism() async throws {
        func run(seed: UInt64) async throws -> [Data] {
            var harness = SimHarness(boards: 2, seed: seed)
            for id in harness.boardIDs { try await harness.startSurvey(id) }
            await harness.transport.advance(byMs: 20_000)
            return try await harness.finish().batches.map { try $0.batch.serializedData() }
        }
        let first = try await run(seed: 7)
        let second = try await run(seed: 7)
        let other = try await run(seed: 8)
        #expect(first.count > 50)
        #expect(first == second)
        #expect(first != other)
    }

    @Test("World generation is seeded")
    func worldDeterminism() {
        let a = SimulatedWorld(seed: 3)
        let b = SimulatedWorld(seed: 3)
        let c = SimulatedWorld(seed: 4)
        #expect(a.accessPoints.map(\.bssid) == b.accessPoints.map(\.bssid))
        #expect(a.accessPoints.map(\.ssid) == b.accessPoints.map(\.ssid))
        #expect(a.clients.map(\.mac) == b.clients.map(\.mac))
        #expect(a.bleDevices.map(\.address) == b.bleDevices.map(\.address))
        #expect(a.accessPoints.map(\.ssid) != c.accessPoints.map(\.ssid))
    }

    @Test("Every address is fake: documentation block, locally administered or BLE random")
    func addressesAreSynthetic() {
        let world = SimulatedWorld(seed: 11)
        let documentation: [UInt8] = [0x00, 0x00, 0x5E, 0x00, 0x53]
        func isFake(_ mac: [UInt8]) -> Bool {
            Array(mac.prefix(5)) == documentation || mac[0] & 0x02 != 0
        }
        #expect(world.accessPoints.allSatisfy { isFake($0.bssid) })
        #expect(world.clients.allSatisfy { isFake($0.mac) && ($0.randomized == ($0.mac[0] & 0x02 != 0)) })
        for device in world.bleDevices {
            if device.addressType == .public {
                #expect(Array(device.address.prefix(5)) == documentation)
            } else {
                #expect(device.address[0] & 0xC0 == 0xC0 || device.address[0] & 0xC0 == 0x40)
            }
        }
        let bssids = world.accessPoints.map { Data($0.bssid) }
        #expect(Set(bssids).count == bssids.count)
    }

    @Test("Output is varied: both bands, hidden SSIDs, wildcard and directed probes, security types")
    func variety() async throws {
        var harness = SimHarness(seed: 5)
        let id = harness.boardIDs[0]
        try await harness.startSurvey(id)
        await harness.transport.advance(byMs: 60_000)
        let records = await harness.finish().records
        let aps = records.compactMap { if case .ap(let ap) = $0.kind { ap } else { nil } }
        let probes = records.compactMap { if case .probe(let probe) = $0.kind { probe } else { nil } }
        let clients = records.compactMap { if case .client(let client) = $0.kind { client } else { nil } }
        let ble = records.compactMap { if case .ble(let ble) = $0.kind { ble } else { nil } }
        #expect(Set(aps.map(\.band)) == [.ghz24, .ghz5])
        #expect(aps.contains { $0.ssidHidden && $0.ssid.isEmpty })
        #expect(Set(aps.map(\.security)).count >= 4)
        #expect(probes.contains { $0.ssid.isEmpty })
        #expect(probes.contains { !$0.ssid.isEmpty })
        #expect(clients.contains { !$0.associatedBssid.isEmpty })
        #expect(clients.contains { $0.locallyAdministered })
        #expect(ble.contains { $0.hasCompanyID })
        #expect(ble.contains { !$0.localNameText.isEmpty })
        #expect(ble.allSatisfy { !$0.advData.isEmpty && $0.advData.count <= 31 })
    }

    @Test("RSSI follows the walk")
    func rssiVariesWithWalk() async throws {
        var harness = SimHarness(seed: 9)
        let id = harness.boardIDs[0]
        try await harness.startSurvey(id, role: .fixedChannel, channels: [6], ble: false)
        await harness.transport.advance(byMs: 360_000)
        let aps = await harness.finish().records.compactMap { if case .ap(let ap) = $0.kind { ap } else { nil } }
        let byBSSID = Dictionary(grouping: aps, by: \.bssid)
        let spread = byBSSID.values.map { group in
            (group.map(\.rssiLast).max() ?? 0) - (group.map(\.rssiLast).min() ?? 0)
        }
        #expect(spread.max() ?? 0 >= 20)
    }

    @Test("Batches fit one notification at the board MTU and hold at most 12 records")
    func batchesFitMTU() async throws {
        var harness = SimHarness(seed: 1)
        let id = harness.boardIDs[0]
        try await harness.startSurvey(id)
        await harness.transport.advance(byMs: 10_000)
        let limit = BoardFraming.maxMessageSize(maxPayload: 247 - 3)
        let batches = await harness.finish().batches
        let sizes = try batches.map { try $0.batch.serializedData().count }
        #expect(!sizes.isEmpty)
        #expect(sizes.allSatisfy { $0 <= limit })
        #expect(batches.allSatisfy { $0.batch.records.count <= 12 })
    }

    @Test("Status arrives at 1 Hz with the board's state")
    func statusRate() async throws {
        var harness = SimHarness(seed: 2)
        let id = harness.boardIDs[0]
        try await harness.startSurvey(id)
        await harness.transport.advance(byMs: 10_000)
        let statuses = await harness.finish().statuses
        #expect(statuses.count == 10)
        #expect(statuses.allSatisfy { $0.state == .surveying && $0.timeSynced && $0.mtu == 247 })
        #expect(statuses.last?.boardTimeMs == 1_800_000_000_000 + 10_000)
        #expect(statuses.contains { $0.recordsPerSec > 0 })
    }

    @Test("Commands other than Hello are refused before Hello")
    func helloRequired() async throws {
        var harness = SimHarness()
        let id = harness.boardIDs[0]
        try await harness.transport.connect(id)
        let response = try await harness.send(.configure(.make(role: .auto)), to: id)
        #expect(response.result == .invalidState)
        var hello = NSBHello()
        hello.protocolMajor = 99
        let incompatible = try await harness.send(.hello(hello), to: id)
        #expect(incompatible.result == .incompatible)
        _ = await harness.finish()
    }

    @Test("Sending to a disconnected board fails")
    func notConnected() async throws {
        let harness = SimHarness()
        let transport = harness.transport
        let id = harness.boardIDs[0]
        await #expect(throws: BoardTransportError.notConnected) {
            try await transport.send(NSBControlRequest(), to: id)
        }
        _ = await harness.finish()
    }
}

@Suite("Simulator helpers")
struct SimulatorHelperTests {
    @Test("Realtime clock delivers records without manual advancing", .timeLimit(.minutes(1)))
    func realtime() async throws {
        let transport = SimulatedBoardTransport(boardCount: 1, seed: 1, timeSource: .realtime(speed: 20))
        let id = transport.profiles[0].id
        let events = transport.events()
        try await transport.connect(id)
        var request = NSBControlRequest()
        request.command = .hello(.with { $0.protocolMajor = 1 })
        _ = try await transport.send(request, to: id)
        request.command = .start(NSBStart())
        _ = try await transport.send(request, to: id)
        for await event in events {
            if case .records = event { break }
        }
        await transport.shutdown()
    }

    @Test("Advertising data carries the name, services and manufacturer data")
    func advertisingData() {
        let data = AdvertisingData.build(name: "Fitness-Band-1", serviceUUIDs: [0x180D], txPower: nil, manufacturer: (0x0059, [1, 2]))
        #expect(data.count <= AdvertisingData.maxLegacyLength)
        #expect(Array(data.prefix(3)) == [0x02, 0x01, 0x06])
        #expect(AdvertisingData.localName(in: data) == "Fitness-Band-1")
        let long = AdvertisingData.build(name: String(repeating: "N", count: 40), serviceUUIDs: [], txPower: nil, manufacturer: nil)
        #expect(long.count == AdvertisingData.maxLegacyLength)
        #expect(long[4] == 0x08)  // Shortened local name.
    }

    @Test("Channel helpers")
    func channels() {
        #expect(WifiChannels.frequencyMHz(of: 1) == 2412)
        #expect(WifiChannels.frequencyMHz(of: 14) == 2484)
        #expect(WifiChannels.frequencyMHz(of: 36) == 5180)
        #expect(WifiChannels.band(of: 165) == .ghz5)
        #expect(WifiChannels.supported(bands: [.ghz24]) == WifiChannels.band24)
    }
}
